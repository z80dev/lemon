defmodule CodingAgent.Tools.Task.FastPath do
  @moduledoc false

  alias CodingAgent.Tools.Task.Workspace

  @direct_provider_engines MapSet.new(["codex", "claude"])
  @internal_bash_command_regex ~r/\bRun\s+`([^`\n]+)`/i
  @internal_bash_exact_command_regex ~r/\bRun(?:\s+this\s+exact\s+command)?(?:\s+and\s+return\s+the\s+output)?\s*(?::|-)\s*([^\n]+?)\s*(?:and\s+return\b|then\s+return\b|return\s+only\b|with\s+no\s+extra\b|$)/i
  @tool_requirement_regex ~r/\b(use|via|with)\s+(the\s+)?(bash|read|grep|glob|search|shell|tools?)\b|\btools?\s+only\b|\buse\s+\w+(?:\/\w+)+\s+tools?\b/i
  @repo_or_workspace_regex ~r/\b(repo|repository|codebase|workspace|cwd|directory|folder|path|file|files|source(?:\s+tree)?)\b|(?:^|[\s`'"])(?:[A-Za-z0-9_.-]+\/)+[A-Za-z0-9_.-]+|(?:^|[\s`'"])[A-Za-z0-9_.-]+\.[A-Za-z0-9_-]+(?:[\s`'".,!?)]|$)/i
  @inspection_regex ~r/\b(count|list|find|check|inspect|open|read|search|grep|exists?|enumerate|scan|look\s+for)\b/i
  @creative_text_regex ~r/\b(write|draft|compose|brainstorm|invent|create|tell|summarize|explain|rewrite|rephrase|translate)\b/i
  @default_model_specs %{
    "codex" => "openai-codex:gpt-5.4",
    "claude" => "anthropic:claude-sonnet-4-20250514"
  }
  @default_system_prompts %{
    "codex" =>
      "You are a focused coding subagent. Follow the user's instructions exactly and return only the requested result.",
    "claude" =>
      "You are a focused writing subagent. Follow the user's instructions exactly and return only the requested result."
  }

  @spec use_direct_provider?(map()) :: boolean()
  def use_direct_provider?(validated) when is_map(validated) do
    not is_nil(direct_model_spec(validated)) and Workspace.use_scratch_workspace?(validated) and
      not requires_explicit_tools?(validated) and creative_text_only?(validated)
  end

  def use_direct_provider?(_), do: false

  @spec use_internal_bash_fast_path?(map()) :: boolean()
  def use_internal_bash_fast_path?(validated) when is_map(validated) do
    is_nil(validated[:engine]) and bash_only_policy?(validated[:tool_policy]) and
      is_binary(extract_internal_bash_command(validated))
  end

  def use_internal_bash_fast_path?(_), do: false

  @spec extract_internal_bash_command(map()) :: String.t() | nil
  def extract_internal_bash_command(validated) when is_map(validated) do
    [validated[:prompt], validated[:description]]
    |> Enum.find_value(fn
      text when is_binary(text) ->
        extract_command_from_text(text)

      _ ->
        nil
    end)
  end

  def extract_internal_bash_command(_), do: nil

  @spec default_model_spec(String.t() | nil) :: String.t() | nil
  def default_model_spec(engine) when is_binary(engine), do: Map.get(@default_model_specs, engine)
  def default_model_spec(_), do: nil

  @spec default_system_prompt(String.t() | nil) :: String.t() | nil
  def default_system_prompt(engine) when is_binary(engine),
    do: Map.get(@default_system_prompts, engine)

  def default_system_prompt(_), do: nil

  @spec direct_model_spec(map()) :: String.t() | nil
  def direct_model_spec(validated) when is_map(validated) do
    engine = validated[:engine]
    model = normalize_optional_string(validated[:model])

    cond do
      not MapSet.member?(@direct_provider_engines, engine) ->
        nil

      is_nil(model) ->
        default_model_spec(engine)

      true ->
        normalize_direct_model_spec(engine, model)
    end
  end

  def direct_model_spec(_), do: nil

  @spec requires_explicit_tools?(map()) :: boolean()
  def requires_explicit_tools?(validated) when is_map(validated) do
    [validated[:description], validated[:prompt]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n")
    |> case do
      "" -> false
      text -> Regex.match?(@tool_requirement_regex, text)
    end
  end

  def requires_explicit_tools?(_), do: false

  @spec creative_text_only?(map()) :: boolean()
  def creative_text_only?(validated) when is_map(validated) do
    text =
      [validated[:description], validated[:prompt]]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n")

    text != "" and Regex.match?(@creative_text_regex, text) and
      not Regex.match?(@repo_or_workspace_regex, text) and
      not Regex.match?(@inspection_regex, text)
  end

  def creative_text_only?(_), do: false

  defp normalize_direct_model_spec("claude", "haiku"),
    do: "anthropic:claude-haiku-4-5"

  defp normalize_direct_model_spec("claude", "sonnet"),
    do: "anthropic:claude-sonnet-4-20250514"

  defp normalize_direct_model_spec("claude", <<"anthropic:", _::binary>> = model), do: model
  defp normalize_direct_model_spec("claude", <<"anthropic/", _::binary>> = model), do: model

  defp normalize_direct_model_spec("claude", <<"claude", _::binary>> = model),
    do: "anthropic:#{model}"

  defp normalize_direct_model_spec("codex", "mini"),
    do: "openai-codex:gpt-5-mini"

  defp normalize_direct_model_spec("codex", "spark"),
    do: "openai-codex:gpt-5.3-codex-spark"

  defp normalize_direct_model_spec("codex", <<"openai-codex:", _::binary>> = model), do: model
  defp normalize_direct_model_spec("codex", <<"openai-codex/", _::binary>> = model), do: model

  defp normalize_direct_model_spec("codex", <<"gpt-", _::binary>> = model),
    do: "openai-codex:#{model}"

  defp normalize_direct_model_spec("codex", <<"codex-", _::binary>> = model),
    do: "openai-codex:#{model}"

  defp normalize_direct_model_spec(_engine, _model), do: nil

  defp bash_only_policy?(%{allow: ["bash"]}), do: true
  defp bash_only_policy?(%{"allow" => ["bash"]}), do: true
  defp bash_only_policy?(_), do: false

  defp extract_command_from_text(text) when is_binary(text) do
    case Regex.run(@internal_bash_command_regex, text, capture: :all_but_first) do
      [command] ->
        normalize_command(command)

      _ ->
        case Regex.run(@internal_bash_exact_command_regex, text, capture: :all_but_first) do
          [command] -> normalize_command(command)
          _ -> nil
        end
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.trim_trailing(".")
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value), do: value
end
