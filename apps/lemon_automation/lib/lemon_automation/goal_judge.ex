defmodule LemonAutomation.GoalJudge do
  @moduledoc false

  @actions ~w(continue done blocked needs_input)

  @spec judge(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def judge(goal, opts \\ []) when is_map(goal) do
    case Keyword.get(opts, :verdict) do
      nil ->
        judge_with_runner(goal, opts)

      verdict ->
        normalize(verdict)
    end
  end

  def normalize(action) when is_atom(action) or is_binary(action),
    do: normalize(%{action: action})

  def normalize(%{} = verdict) do
    action = verdict |> field(:action) |> normalize_action()

    cond do
      action not in @actions ->
        {:error, :invalid_verdict}

      true ->
        {:ok,
         %{
           action: String.to_existing_atom(action),
           reason: string_field(verdict, :reason) || "",
           source: string_field(verdict, :source) || "manual"
         }}
    end
  rescue
    ArgumentError -> {:error, :invalid_verdict}
  end

  def normalize(_), do: {:error, :invalid_verdict}

  defp judge_with_runner(goal, opts) do
    case judge_runner(opts) do
      nil ->
        {:ok,
         %{
           action: :continue,
           reason: "preview judge defaults active goals to one more continuation",
           source: "preview"
         }}

      runner ->
        goal
        |> runner.judge(judge_context(opts))
        |> normalize_runner_result(opts)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp judge_runner(opts) do
    Keyword.get(opts, :judge_runner) ||
      Application.get_env(:lemon_automation, :goal_judge_runner)
  end

  defp judge_context(opts) do
    %{
      model:
        Keyword.get(opts, :judge_model) ||
          Application.get_env(:lemon_automation, :goal_judge_model) ||
          Keyword.get(opts, :model),
      max_output_chars: Keyword.get(opts, :judge_max_output_chars, 1_000),
      run_id: Keyword.get(opts, :judge_run_id),
      router_mod: Keyword.get(opts, :judge_router_mod, LemonRouter),
      waiter_mod: Keyword.get(opts, :judge_waiter_mod, LemonAutomation.RunCompletionWaiter),
      wait_timeout_ms: Keyword.get(opts, :judge_wait_timeout_ms, 60_000),
      wait_opts: Keyword.get(opts, :judge_wait_opts, [])
    }
  end

  defp normalize_runner_result({:ok, verdict}, opts), do: normalize_with_source(verdict, opts)
  defp normalize_runner_result({:error, reason}, _opts), do: {:error, reason}
  defp normalize_runner_result(verdict, opts), do: normalize_with_source(verdict, opts)

  defp normalize_with_source(verdict, opts) do
    case normalize(verdict) do
      {:ok, normalized} ->
        source = normalized.source || ""

        if source == "" or source == "manual" do
          {:ok, %{normalized | source: judge_source(opts)}}
        else
          {:ok, normalized}
        end

      error ->
        error
    end
  end

  defp judge_source(opts) do
    case judge_context(opts).model do
      model when is_binary(model) and model != "" -> "judge:#{model}"
      model when is_atom(model) -> "judge:#{model}"
      _ -> "judge"
    end
  end

  defp normalize_action(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_action(value) when is_binary(value), do: String.trim(value)
  defp normalize_action(_), do: ""

  defp string_field(map, key) do
    case field(map, key) do
      nil -> nil
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
