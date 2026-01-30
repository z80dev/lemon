defmodule CodingAgent.Mentions do
  @moduledoc """
  @ mention parsing for subagent invocation.

  Allows users to mention subagents in prompts like:
  - `@explore find all API endpoints`
  - `@debug investigate this error`
  - `@review check these changes`

  ## Parsing

  Mentions are extracted from user input and matched against available subagents.
  The mention format is `@agent_name` followed by the prompt for that agent.

  ## Examples

      input = "@explore find the auth module"
      {:ok, %{agent: "explore", prompt: "find the auth module"}} = Mentions.parse(input, cwd)

      input = "Please help me @debug this issue"
      {:ok, %{agent: "debug", prompt: "this issue", prefix: "Please help me"}} = Mentions.parse(input, cwd)
  """

  alias CodingAgent.Subagents

  @type mention :: %{
          agent: String.t(),
          prompt: String.t(),
          prefix: String.t() | nil,
          original: String.t()
        }

  @doc """
  Parse a user input for @ mentions.

  Returns the first valid mention found, or nil if no mention matches a known subagent.

  ## Parameters

    * `input` - The user input string
    * `cwd` - Current working directory (for loading subagents)

  ## Returns

    * `{:ok, mention}` - If a valid mention is found
    * `:no_mention` - If no @ mention is found
    * `{:error, :unknown_agent, agent_name}` - If mention doesn't match a known agent
  """
  @spec parse(String.t(), String.t()) ::
          {:ok, mention()} | :no_mention | {:error, :unknown_agent, String.t()}
  def parse(input, cwd) when is_binary(input) do
    case extract_mention(input) do
      nil ->
        :no_mention

      {agent_name, prompt, prefix} ->
        if agent_exists?(agent_name, cwd) do
          {:ok,
           %{
             agent: agent_name,
             prompt: String.trim(prompt),
             prefix: if(prefix == "", do: nil, else: String.trim(prefix)),
             original: input
           }}
        else
          {:error, :unknown_agent, agent_name}
        end
    end
  end

  @doc """
  Extract all mentions from input.

  Returns a list of all @ mentions found, whether or not they match known agents.
  Useful for autocomplete or validation.

  ## Parameters

    * `input` - The user input string

  ## Returns

  A list of `{agent_name, rest_of_text}` tuples.
  """
  @spec extract_all(String.t()) :: [{String.t(), String.t()}]
  def extract_all(input) when is_binary(input) do
    # Match @word patterns
    regex = ~r/@([a-zA-Z][a-zA-Z0-9_-]*)/

    Regex.scan(regex, input)
    |> Enum.map(fn [_full, name] ->
      # Get everything after the mention
      case String.split(input, "@#{name}", parts: 2) do
        [_before, rest] -> {name, String.trim(rest)}
        _ -> {name, ""}
      end
    end)
  end

  @doc """
  List available agents for autocomplete.

  Returns agent names that start with the given prefix.

  ## Parameters

    * `prefix` - The partial agent name typed by user
    * `cwd` - Current working directory

  ## Returns

  A list of matching agent names.
  """
  @spec autocomplete(String.t(), String.t()) :: [String.t()]
  def autocomplete(prefix, cwd) when is_binary(prefix) do
    prefix_lower = String.downcase(prefix)

    Subagents.list(cwd)
    |> Enum.map(& &1.id)
    |> Enum.filter(fn id ->
      String.starts_with?(String.downcase(id), prefix_lower)
    end)
    |> Enum.sort()
  end

  @doc """
  Check if input starts with an @ mention.

  ## Parameters

    * `input` - The user input string

  ## Returns

  `true` if input starts with @, `false` otherwise.
  """
  @spec starts_with_mention?(String.t()) :: boolean()
  def starts_with_mention?(input) when is_binary(input) do
    String.trim(input) |> String.starts_with?("@")
  end

  @doc """
  Format a mention for display in help/error messages.

  ## Parameters

    * `cwd` - Current working directory

  ## Returns

  Formatted string showing available mentions.
  """
  @spec format_available(String.t()) :: String.t()
  def format_available(cwd) do
    agents = Subagents.list(cwd)

    if agents == [] do
      "No agents available for @mention"
    else
      header = "Available @mentions:\n"

      body =
        agents
        |> Enum.map(fn agent ->
          "  @#{agent.id} - #{agent.description}"
        end)
        |> Enum.join("\n")

      header <> body
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp extract_mention(input) do
    trimmed = String.trim(input)

    # Match @word at start or after whitespace
    regex = ~r/^(.*?)@([a-zA-Z][a-zA-Z0-9_-]*)\s*(.*)/s

    case Regex.run(regex, trimmed) do
      [_full, prefix, agent_name, rest] ->
        {agent_name, rest, prefix}

      nil ->
        nil
    end
  end

  defp agent_exists?(name, cwd) do
    Subagents.get(cwd, name) != nil
  end
end
