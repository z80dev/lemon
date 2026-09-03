defmodule LemonBrowser.CloudSession do
  @moduledoc """
  Exact-session-scoped hosted browser lifecycle and CDP driver owner.

  One process owns one provider session and one attach-only driver. Sessions
  never silently cross Lemon conversation identities and are released after a
  bounded idle period or process termination.
  """

  use GenServer

  alias LemonBrowser.LocalServer

  @registry LemonBrowser.CloudSessionRegistry
  @supervisor LemonBrowser.CloudSessionSupervisor
  @default_idle_timeout_ms 300_000
  @max_idle_timeout_ms 3_600_000

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def request(provider, method, args, timeout_ms, opts)
      when is_atom(provider) and is_binary(method) and is_map(args) do
    with {:ok, scope} <- exact_scope(opts),
         {:ok, pid} <- ensure_started(provider, scope, opts) do
      GenServer.call(pid, {:request, method, args, timeout_ms}, timeout_ms + 35_000)
    end
  end

  def status(provider \\ nil) do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {{session_provider, _scope}, pid} ->
      if is_nil(provider) or provider == session_provider do
        try do
          [GenServer.call(pid, :status, 1_000)]
        catch
          :exit, _ -> []
        end
      else
        []
      end
    end)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    idle_timeout_ms =
      opts
      |> Keyword.get(:idle_timeout_ms, @default_idle_timeout_ms)
      |> normalize_idle_timeout()

    {:ok,
     %{
       provider: Keyword.fetch!(opts, :provider),
       scope: Keyword.fetch!(opts, :scope),
       provider_opts: Keyword.get(opts, :provider_opts, []),
       driver: nil,
       session: nil,
       idle_timeout_ms: idle_timeout_ms,
       idle_timer: schedule_idle(idle_timeout_ms),
       request_count: 0,
       last_used_at: nil,
       last_error: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  def handle_call({:request, method, args, timeout_ms}, _from, state) do
    state = reset_idle_timer(state)

    case ensure_driver(state) do
      {:ok, state} ->
        result = LocalServer.request(state.driver, method, args, timeout_ms)

        state = %{
          state
          | request_count: state.request_count + 1,
            last_used_at: now_iso8601(),
            last_error: error_text(result)
        }

        {:reply, result, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, %{state | last_error: safe_reason(reason)}}
    end
  end

  @impl true
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _reason}, %{driver: pid} = state) do
    close_provider_session(state)
    {:noreply, %{state | driver: nil, session: nil, last_error: "browser driver exited"}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.driver), do: LocalServer.stop(state.driver)
    close_provider_session(state)
    :ok
  end

  defp ensure_started(provider, scope, opts) do
    key = {provider, scope}
    name = {:via, Registry, {@registry, key}}

    case Registry.lookup(@registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_opts = [
          key: key,
          name: name,
          provider: provider,
          scope: scope,
          provider_opts: hosted_provider_opts(opts),
          idle_timeout_ms: Keyword.get(opts, :browser_idle_timeout_ms, @default_idle_timeout_ms)
        ]

        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp ensure_driver(%{driver: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_driver(state) do
    with {:ok, provider_module} <- fetch_provider(state.provider),
         {:ok, session} <- provider_module.create_session(scope_id(state.scope), state.provider_opts),
         {:ok, driver} <-
           LocalServer.start_link(
             name: nil,
             cdp_endpoint: session.cdp_endpoint,
             attach_only: true,
             driver_path: Keyword.get(state.provider_opts, :driver_path)
           ) do
      {:ok, %{state | driver: driver, session: session, last_error: nil}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fetch_provider(provider) do
    case LemonBrowser.SessionProviderRegistry.fetch(provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_browser_session_provider, provider}}
    end
  end

  defp close_provider_session(%{session: %{id: id}} = state) do
    case fetch_provider(state.provider) do
      {:ok, module} -> module.close_session(id, state.provider_opts)
      _ -> :ok
    end
  catch
    _, _ -> :ok
  end

  defp close_provider_session(_state), do: :ok

  defp exact_scope(opts) do
    session_id = normalized_opt(opts, :session_id)

    if session_id do
      {:ok,
       %{
         session_id: session_id,
         browser_profile_id: normalized_opt(opts, :browser_profile_id),
         run_id: normalized_opt(opts, :run_id)
       }}
    else
      {:error, {:missing_hosted_browser_binding, :session_id}}
    end
  end

  defp normalized_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _ -> nil
    end
  end

  defp hosted_provider_opts(opts) do
    Keyword.take(opts, [
      :provider_config,
      :http_post,
      :http_patch,
      :http_delete,
      :driver_path
    ])
  end

  defp scope_id(scope) do
    [scope.session_id, scope.browser_profile_id, scope.run_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp public_status(state) do
    %{
      provider: state.provider,
      session_id_hash: hash(state.scope.session_id),
      browser_profile_id_hash: hash(state.scope.browser_profile_id),
      run_id_hash: hash(state.scope.run_id),
      connected: is_pid(state.driver),
      provider_session_active: not is_nil(state.session),
      features: if(state.session, do: Map.get(state.session, :features, %{}), else: %{}),
      expires_at: if(state.session, do: Map.get(state.session, :expires_at), else: nil),
      request_count: state.request_count,
      last_used_at: state.last_used_at,
      last_error: state.last_error,
      idle_timeout_ms: state.idle_timeout_ms
    }
  end

  defp reset_idle_timer(state) do
    _ = Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: schedule_idle(state.idle_timeout_ms)}
  end

  defp schedule_idle(timeout_ms), do: Process.send_after(self(), :idle_timeout, timeout_ms)

  defp normalize_idle_timeout(value) when is_integer(value) and value > 0,
    do: min(value, @max_idle_timeout_ms)

  defp normalize_idle_timeout(_), do: @default_idle_timeout_ms

  defp error_text({:error, reason}), do: safe_reason(reason)
  defp error_text(_), do: nil

  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 300)
  defp safe_reason(reason), do: reason |> inspect(limit: 8, printable_limit: 300) |> String.slice(0, 300)

  defp hash(nil), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
