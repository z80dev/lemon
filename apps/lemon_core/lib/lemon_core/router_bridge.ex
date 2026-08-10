defmodule LemonCore.RouterBridge do
  @moduledoc """
  Optional bridge to `:lemon_router` without compile-time coupling.

  Channel adapters and other producers can forward inbound messages and submit
  runs without depending on `:lemon_router`. `:lemon_router` configures the
  bridge at runtime.

  `submit_run/1` accepts a canonical `%LemonCore.RunRequest{}`.

  ## Failure contract

  Every function here answers rather than raises, because callers are channel
  adapters and webhook handlers for whom a router problem is not their problem
  to crash over. Three failure modes, deliberately distinguished:

    * **Not configured** — no module registered for the role. The documented
      fallback: `{:error, :unavailable}`, or the soft value (`false`, `:none`,
      `[]`) for the query functions.
    * **Reached and raised** — the router ran in the caller's process and threw
      an exception. Answered `{:error, exception}`, which is more useful than
      `:unavailable` because the router *was* available; something else failed.
    * **Configured but not running** — the router module exists, but the process
      behind it does not answer, so `GenServer.call` **exits**. An exit is not
      an exception and `rescue` does not catch it: before this was handled, that
      exit travelled into whatever called the bridge, which for an HTTP handler
      meant an opaque 500 and, for a mail webhook, a silently dropped message.
      Now answered `{:error, :unavailable}` — the same as never having been
      configured, because from the caller's side it is the same situation: the
      router did not take this.

  Exits are collapsed to `:unavailable` rather than reported in detail on
  purpose. A timeout, a dead process and a mid-call crash differ in cause but
  not in consequence — the work was not accepted and the caller's only real
  decision is whether to retry. Reporting them separately invites callers to
  match on `:unavailable` alone and silently mishandle the rest, which is
  exactly the bug this contract exists to prevent. Callers that want the detail
  should log at their own layer, where they know what the failure means.

  Throws are *not* caught: no router throws, and one that did would be a bug
  worth surfacing rather than flattening into "unavailable".
  """

  @bridge_key :router_bridge
  alias LemonCore.RunRequest
  @config_keys [:run_orchestrator, :router]

  @type config :: %{
          optional(:run_orchestrator) => module(),
          optional(:router) => module()
        }

  @type configure_mode :: :replace | :merge | :safe_merge

  @spec configure(keyword()) :: :ok | {:error, term()}
  def configure(opts) when is_list(opts) do
    configure(opts, mode: :replace)
  end

  @doc """
  Configure bridge modules with merge/guard modes.

  Modes:
  - `:replace` - replace configured keys directly
  - `:merge` - merge with existing config, preserving unspecified keys
  - `:safe_merge` - like merge, but rejects conflicting non-nil overrides
  """
  @spec configure(keyword(), keyword()) :: :ok | {:error, term()}
  def configure(opts, config_opts) when is_list(opts) and is_list(config_opts) do
    mode = Keyword.get(config_opts, :mode, :replace)
    incoming = opts |> Enum.into(%{}) |> Map.take(@config_keys)

    with :ok <- validate_config(incoming),
         {:ok, config} <- merge_config(current_config(), incoming, mode) do
      Application.put_env(:lemon_core, @bridge_key, config)
      :ok
    end
  end

  @doc """
  Configure bridge modules with conflict protection.
  """
  @spec configure_guarded(keyword()) :: :ok | {:error, term()}
  def configure_guarded(opts) when is_list(opts) do
    configure(opts, mode: :safe_merge)
  end

  @spec submit_run(RunRequest.t()) ::
          {:ok, binary()} | {:error, :unavailable} | {:error, term()}
  def submit_run(%RunRequest{} = params) do
    do_submit_run(params)
  end

  defp do_submit_run(params) do
    case impl(:run_orchestrator) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :submit, 1) do
          apply(mod, :submit, [params])
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec handle_inbound(term()) :: :ok | {:error, :unavailable} | {:error, term()}
  def handle_inbound(msg) do
    case impl(:router) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :handle_inbound, 1) do
          _ = apply(mod, :handle_inbound, [msg])
          :ok
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec abort_session(binary(), term()) :: :ok | {:error, :unavailable} | {:error, term()}
  def abort_session(session_key, reason \\ :user_requested) when is_binary(session_key) do
    case impl(:router) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :abort, 2) do
          _ = apply(mod, :abort, [session_key, reason])
          :ok
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec abort_run(binary(), term()) :: :ok | {:error, :unavailable} | {:error, term()}
  def abort_run(run_id, reason \\ :user_requested) when is_binary(run_id) do
    case impl(:router) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :abort_run, 2) do
          _ = apply(mod, :abort_run, [run_id, reason])
          :ok
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec keep_run_alive(binary(), :continue | :cancel) ::
          :ok | {:error, :unavailable} | {:error, term()}
  def keep_run_alive(run_id, decision \\ :continue)
      when is_binary(run_id) and decision in [:continue, :cancel] do
    case impl(:router) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :keep_run_alive, 2) do
          _ = apply(mod, :keep_run_alive, [run_id, decision])
          :ok
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec session_busy?(binary()) :: boolean()
  def session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    case impl(:router) do
      nil ->
        false

      mod ->
        Code.ensure_loaded?(mod) and function_exported?(mod, :session_busy?, 1) and
          apply(mod, :session_busy?, [session_key])
    end
  rescue
    _ -> false
  catch
    # "Not busy" is the wrong answer if the router is merely unreachable — a
    # caller may start work it would otherwise have queued. It is still the
    # answer this function has always given for a router it cannot consult, and
    # the boolean return has nowhere to put "don't know". Callers that must not
    # act on a false negative should ask the router directly.
    :exit, _reason -> false
  end

  def session_busy?(_), do: false

  @spec active_run(binary()) :: {:ok, binary()} | :none
  def active_run(session_key) when is_binary(session_key) and session_key != "" do
    case impl(:router) do
      nil ->
        :none

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :active_run, 1) do
          apply(mod, :active_run, [session_key])
        else
          :none
        end
    end
  rescue
    _ -> :none
  catch
    :exit, _reason -> :none
  end

  def active_run(_), do: :none

  @spec list_active_sessions() :: [%{session_key: binary(), run_id: binary()}]
  def list_active_sessions do
    case impl(:router) do
      nil ->
        []

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :list_active_sessions, 0) do
          apply(mod, :list_active_sessions, [])
        else
          []
        end
    end
  rescue
    _ -> []
  catch
    :exit, _reason -> []
  end

  defp impl(key) do
    config = current_config()
    Map.get(config, key)
  end

  defp current_config do
    case Application.get_env(:lemon_core, @bridge_key, %{}) do
      config when is_map(config) -> Map.take(config, @config_keys)
      _ -> %{}
    end
  end

  defp validate_config(config) do
    Enum.reduce_while(config, :ok, fn {key, mod}, :ok ->
      if key in @config_keys and (is_nil(mod) or is_atom(mod)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_module, key, mod}}}
      end
    end)
  end

  defp merge_config(_current, incoming, :replace), do: {:ok, compact_config(incoming)}

  defp merge_config(current, incoming, :merge) do
    {:ok, current |> Map.merge(incoming) |> compact_config()}
  end

  defp merge_config(current, incoming, :safe_merge) do
    conflicts =
      Enum.filter(@config_keys, fn key ->
        current_val = Map.get(current, key)
        incoming_val = Map.get(incoming, key, :__missing__)

        current_val != nil and incoming_val not in [:__missing__, nil, current_val]
      end)

    case conflicts do
      [] ->
        merge_config(current, incoming, :merge)

      [key | _] ->
        {:error,
         {:already_configured, key, Map.get(current, key), Map.get(incoming, key, :__missing__)}}
    end
  end

  defp merge_config(_current, _incoming, mode), do: {:error, {:invalid_mode, mode}}

  defp compact_config(config) when is_map(config) do
    Enum.reduce(config, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
