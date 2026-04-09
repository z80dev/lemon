defmodule CodingAgent.Tools.Task.Workspace do
  @moduledoc false

  require Logger

  @external_engines MapSet.new(["codex", "claude", "kimi", "opencode", "pi"])

  @workspace_signal_regex ~r/\b(file|files|repo|repository|project|workspace|directory|folder|path|module|function|class|test|tests|compile|build|shell|command|grep|debug|bug|stacktrace|refactor|edit|modify|git|mix|npm|pnpm|yarn|cargo|pytest|rspec|source code|codebase|pull request)\b/i

  @spec resolve_effective_cwd(map(), String.t(), keyword()) :: String.t()
  def resolve_effective_cwd(validated, parent_cwd, opts \\ []) when is_map(validated) do
    explicit_cwd = normalize_cwd(validated[:cwd])

    cond do
      is_binary(explicit_cwd) ->
        explicit_cwd

      use_scratch_workspace?(validated) ->
        ref =
          opts[:task_id] || opts[:run_id] || Integer.to_string(System.unique_integer([:positive]))

        case ensure_scratch_cwd(ref) do
          {:ok, cwd} ->
            Logger.info(
              "Task tool using scratch workspace for external text task engine=#{inspect(validated[:engine])} description=#{inspect(validated[:description])} cwd=#{inspect(cwd)}"
            )

            cwd

          {:error, reason} ->
            fallback = normalize_cwd(parent_cwd) || File.cwd!()

            Logger.warning(
              "Task tool failed to prepare scratch workspace; falling back to parent cwd=#{inspect(fallback)} reason=#{inspect(reason)}"
            )

            fallback
        end

      true ->
        normalize_cwd(parent_cwd) || File.cwd!()
    end
  end

  @spec use_scratch_workspace?(map()) :: boolean()
  def use_scratch_workspace?(validated) when is_map(validated) do
    engine = validated[:engine]
    role_id = normalize_optional_string(validated[:role_id])
    prompt = normalize_optional_string(validated[:prompt]) || ""
    description = normalize_optional_string(validated[:description]) || ""

    MapSet.member?(@external_engines, engine) and
      not is_binary(normalize_cwd(validated[:cwd])) and
      is_nil(role_id) and
      text_only_task?(description, prompt)
  end

  def use_scratch_workspace?(_), do: false

  defp text_only_task?(description, prompt) do
    combined =
      [description, prompt]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    combined != "" and not Regex.match?(@workspace_signal_regex, combined)
  end

  defp ensure_scratch_cwd(ref) do
    cwd = Path.join([System.tmp_dir!(), "lemon-task-scratch", to_string(ref)])

    case File.mkdir_p(cwd) do
      :ok -> {:ok, cwd}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd = String.trim(cwd)
    if cwd == "", do: nil, else: Path.expand(cwd)
  end

  defp normalize_cwd(_), do: nil

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value), do: value
end
