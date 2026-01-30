defmodule CodingAgent.Subagents do
  @moduledoc """
  Subagent definitions and loading.

  Subagents are lightweight personas with prompts that can be prepended to
  Task tool prompts. Definitions can be provided via JSON files:

  - Project: .lemon/subagents.json
  - Global: ~/.lemon/agent/subagents.json

  Each entry should be a JSON object with:
    - id (string)
    - description (string)
    - prompt (string)
  """

  alias CodingAgent.Config

  @type subagent :: %{id: String.t(), description: String.t(), prompt: String.t()}

  @default_subagents [
    %{
      id: "research",
      description: "Locate relevant files and summarize findings (no code changes).",
      prompt:
        "You are a research subagent. Focus on finding relevant files, APIs, and context. Do not modify code. Summarize key findings with file paths."
    },
    %{
      id: "implement",
      description: "Make code changes to implement the requested behavior.",
      prompt:
        "You are an implementation subagent. Make the required code changes and explain what you changed. Keep changes minimal and focused."
    },
    %{
      id: "review",
      description: "Review changes for bugs, risks, and missing tests.",
      prompt:
        "You are a review subagent. Identify correctness issues, risks, and missing tests. Be specific about files and likely failure modes."
    },
    %{
      id: "test",
      description: "Run tests or validate behavior and report results.",
      prompt:
        "You are a test subagent. Run or propose the most relevant tests and summarize outcomes. If you cannot run tests, state what you would run."
    }
  ]

  @spec list(String.t()) :: [subagent()]
  def list(cwd) do
    default = @default_subagents
    global = load_file(global_subagents_file())
    project = load_file(project_subagents_file(cwd))

    default
    |> merge_by_id(global)
    |> merge_by_id(project)
  end

  @spec get(String.t(), String.t()) :: subagent() | nil
  def get(cwd, id) when is_binary(id) do
    list(cwd)
    |> Enum.find(fn agent -> agent.id == id end)
  end

  @spec format_for_description(String.t()) :: String.t()
  def format_for_description(cwd) do
    agents = list(cwd)

    if agents == [] do
      ""
    else
      agents
      |> Enum.map(fn agent ->
        "- #{agent.id}: #{agent.description}"
      end)
      |> Enum.join("\n")
    end
  end

  defp merge_by_id(base, overrides) do
    base_map = Map.new(base, fn agent -> {agent.id, agent} end)

    overrides_map =
      Map.new(overrides, fn agent ->
        {agent.id, agent}
      end)

    merged = Map.merge(base_map, overrides_map)
    merged |> Map.values() |> Enum.sort_by(& &1.id)
  end

  defp load_file(nil), do: []

  defp load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        decode_agents(content)

      {:error, _} ->
        []
    end
  end

  defp decode_agents(content) do
    case Jason.decode(content) do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.filter(&is_map/1)
        |> Enum.map(&normalize_agent/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp normalize_agent(%{"id" => id, "prompt" => prompt} = agent)
       when is_binary(id) and is_binary(prompt) do
    %{
      id: id,
      description: agent["description"] || "",
      prompt: prompt
    }
  end

  defp normalize_agent(_), do: nil

  defp global_subagents_file do
    Path.join(Config.agent_dir(), "subagents.json")
  end

  defp project_subagents_file(cwd) do
    Path.join(Config.project_config_dir(cwd), "subagents.json")
  end
end
