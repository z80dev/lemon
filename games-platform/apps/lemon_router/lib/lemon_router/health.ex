defmodule LemonRouter.Health do
  @moduledoc false

  @default_custom_check_name "custom"

  @type check_response :: :ok | true | false | {:ok, term()} | {:error, term()}
  @type check_fun :: (-> check_response())

  @spec status() :: map()
  def status do
    checks = built_in_checks() ++ custom_checks()
    results = Enum.map(checks, &run_check/1)

    %{
      ok: Enum.all?(results, & &1.ok),
      app: "lemon_router",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: results
    }
  end

  defp built_in_checks do
    [
      {"supervisor", fn -> process_alive_check(LemonRouter.Supervisor) end},
      {"run_orchestrator", fn -> process_alive_check(LemonRouter.RunOrchestrator) end},
      {"run_supervisor", fn -> run_supervisor_check() end},
      {"run_counts", fn -> run_counts_check() end}
    ]
  end

  defp custom_checks do
    checks = Application.get_env(:lemon_router, :health_checks, [])

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

  defp run_supervisor_check do
    case Process.whereis(LemonRouter.RunSupervisor) do
      pid when is_pid(pid) ->
        limit = Application.get_env(:lemon_router, :run_process_limit, 500)
        counts = DynamicSupervisor.count_children(LemonRouter.RunSupervisor)
        {:ok, Map.put(counts, :max_children, limit)}

      _ ->
        {:error, :not_running}
    end
  rescue
    error ->
      {:error, error}
  end

  defp run_counts_check do
    {:ok, LemonRouter.RunOrchestrator.counts()}
  rescue
    error ->
      {:error, error}
  end
end
