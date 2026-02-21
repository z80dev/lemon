defmodule LemonGateway.Health do
  @moduledoc false

  @default_custom_check_name "custom"

  @type check_response :: :ok | true | false | {:ok, term()} | {:error, term()}
  @type check_fun :: (-> check_response())
  @type custom_check ::
          check_fun()
          | {atom() | String.t(), check_fun()}
          | {module(), atom(), [term()]}
          | {atom() | String.t(), {module(), atom(), [term()]}}

  @spec status() :: map()
  def status do
    checks = built_in_checks() ++ custom_checks()
    results = Enum.map(checks, &run_check/1)

    %{
      ok: Enum.all?(results, & &1.ok),
      app: "lemon_gateway",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: results
    }
  end

  defp built_in_checks do
    checks = [
      {"supervisor", fn -> process_alive_check(LemonGateway.Supervisor) end},
      {"scheduler", fn -> scheduler_check() end},
      {"run_supervisor", fn -> dynamic_supervisor_check(LemonGateway.RunSupervisor) end},
      {"engine_lock", fn -> process_alive_check(LemonGateway.EngineLock) end}
    ]

    if xmtp_enabled?() do
      checks ++ [{"xmtp_transport", fn -> xmtp_transport_check() end}]
    else
      checks
    end
  end

  defp custom_checks do
    checks = Application.get_env(:lemon_gateway, :health_checks, [])

    checks
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {check, idx} -> normalize_custom_check(check, idx) end)
  end

  defp normalize_custom_check({name, fun}, _idx) when is_function(fun, 0) do
    {name, fun}
  end

  defp normalize_custom_check({name, {module, function, args}}, _idx)
       when is_atom(module) and is_atom(function) and is_list(args) do
    {name, fn -> apply(module, function, args) end}
  end

  defp normalize_custom_check({module, function, args}, idx)
       when is_atom(module) and is_atom(function) and is_list(args) do
    {"#{@default_custom_check_name}_#{idx}", fn -> apply(module, function, args) end}
  end

  defp normalize_custom_check(fun, idx) when is_function(fun, 0) do
    {"#{@default_custom_check_name}_#{idx}", fun}
  end

  defp normalize_custom_check(other, idx) do
    {"#{@default_custom_check_name}_#{idx}", fn -> {:error, {:invalid_check, other}} end}
  end

  defp run_check({name, fun}) do
    started_at_ms = System.monotonic_time(:millisecond)

    result =
      try do
        normalize_check_result(fun.())
      rescue
        exception -> {:error, {:raised, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at_ms

    case result do
      {:ok, detail} ->
        %{name: to_string(name), ok: true, duration_ms: duration_ms, detail: detail}

      {:error, reason} ->
        %{name: to_string(name), ok: false, duration_ms: duration_ms, error: inspect(reason)}
    end
  end

  defp normalize_check_result(:ok), do: {:ok, nil}
  defp normalize_check_result(true), do: {:ok, nil}
  defp normalize_check_result({:ok, detail}), do: {:ok, detail}
  defp normalize_check_result(false), do: {:error, :failed}
  defp normalize_check_result({:error, reason}), do: {:error, reason}
  defp normalize_check_result(other), do: {:error, {:invalid_result, other}}

  defp process_alive_check(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> {:ok, %{pid: inspect(pid)}}
      _ -> {:error, :not_running}
    end
  end

  defp dynamic_supervisor_check(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, DynamicSupervisor.count_children(name)}

      _ ->
        {:error, :not_running}
    end
  rescue
    error ->
      {:error, error}
  end

  defp scheduler_check do
    case Process.whereis(LemonGateway.Scheduler) do
      pid when is_pid(pid) ->
        case :sys.get_state(LemonGateway.Scheduler) do
          %{in_flight: in_flight, waitq: waitq, max: max} ->
            {:ok, %{in_flight: map_size(in_flight), waitq: :queue.len(waitq), max: max}}

          state ->
            {:error, {:unexpected_state, state}}
        end

      _ ->
        {:error, :not_running}
    end
  rescue
    error ->
      {:error, error}
  end

  defp xmtp_transport_check do
    with true <- Code.ensure_loaded?(LemonGateway.Transports.Xmtp),
         {:ok, status} <- LemonGateway.Transports.Xmtp.status(),
         true <- status[:connected?] == true,
         true <- status[:healthy?] == true do
      {:ok,
       %{
         mode: status[:mode],
         require_live: status[:require_live],
         connected: status[:connected?]
       }}
    else
      false ->
        {:error, :xmtp_not_live}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_xmtp_status, other}}
    end
  rescue
    error ->
      {:error, error}
  end

  defp xmtp_enabled? do
    if Code.ensure_loaded?(LemonGateway.Transports.Xmtp) do
      LemonGateway.Transports.Xmtp.enabled?()
    else
      false
    end
  rescue
    _ -> false
  end
end
