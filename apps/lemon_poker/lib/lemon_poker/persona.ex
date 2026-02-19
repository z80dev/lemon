defmodule LemonPoker.Persona do
  @moduledoc """
  Persona and banter management for poker table talk.

  Loads persona definitions from priv/personas/ and banter examples
  from priv/banter/ to inject into agent prompts.
  """

  @persona_dir Path.join(:code.priv_dir(:lemon_poker), "personas")
  @banter_dir Path.join(:code.priv_dir(:lemon_poker), "banter")

  @default_personas [
    "grinder",
    "aggro",
    "friendly",
    "silent",
    "tourist",
    "showman",
    "professor",
    "road_dog",
    "dealer_friend",
    "homegame_legend"
  ]
  @banter_categories ["greetings", "reactions", "idle_chat", "bad_beats", "big_pots", "leaving"]

  @type persona :: %{
          name: String.t(),
          content: String.t()
        }

  @type banter_examples :: %{String.t() => [String.t()]}

  @doc """
  Load a persona by name. Returns nil if not found.
  """
  @spec load(String.t()) :: persona() | nil
  def load(name) when is_binary(name) do
    path = Path.join(@persona_dir, "#{name}.md")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          %{name: name, content: content}

        _ ->
          nil
      end
    else
      nil
    end
  end

  def load(_), do: nil

  @doc """
  List all available persona names.
  """
  @spec list() :: [String.t()]
  def list do
    case File.ls(@persona_dir) do
      {:ok, entries} ->
        discovered =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&String.replace_suffix(&1, ".md", ""))
          |> Enum.uniq()

        ordered_defaults = Enum.filter(@default_personas, &(&1 in discovered))
        extras = discovered |> Enum.reject(&(&1 in ordered_defaults)) |> Enum.sort()
        personas = ordered_defaults ++ extras

        if personas == [], do: @default_personas, else: personas

      _ ->
        @default_personas
    end
  end

  @doc """
  Load all banter examples from the banter directory.
  Returns a map of category -> list of examples.
  """
  @spec load_banter() :: banter_examples()
  def load_banter do
    @banter_categories
    |> Enum.map(fn category ->
      path = Path.join(@banter_dir, "#{category}.txt")
      examples = load_banter_file(path)
      {category, examples}
    end)
    |> Enum.into(%{})
  end

  @doc """
  Sample random banter examples from a category.
  Returns empty list if category doesn't exist.
  """
  @spec sample_banter(banter_examples(), String.t(), pos_integer()) :: [String.t()]
  def sample_banter(banter, category, count \\ 3) do
    case Map.get(banter, category) do
      nil -> []
      examples -> Enum.take_random(examples, min(count, length(examples)))
    end
  end

  @doc """
  Build a persona-enhanced system prompt.
  Combines base poker instructions with persona content.
  """
  @spec build_system_prompt(String.t(), persona() | nil) :: String.t()
  def build_system_prompt(base_prompt, nil), do: base_prompt

  def build_system_prompt(base_prompt, persona) do
    """
    #{base_prompt}

    ---

    Your Persona:

    #{persona.content}

    Persona execution rules:
    - Use the persona as a tone guide, not a script.
    - Keep this voice distinct from other seats; avoid generic neutral phrasing.
    - Put your own spin on each TALK message with fresh wording.
    - Respond to other players when useful, but avoid pile-on echoes.
    - Help conversation flow by mixing replies, pivots, callbacks, and occasional silence.
    - Keep recurring persona motifs occasional; do not spam one trope.
    - Keep TALK concise and conversational.
    - Follow all table-talk safety rules from the task prompt.

    Remember: Your TALK output should reflect this persona while still sounding original and reactive.
    """
  end

  @doc """
  Build a banter examples block for injection into the decision prompt.
  """
  @spec build_banter_prompt(banter_examples(), String.t() | nil) :: String.t()
  def build_banter_prompt(_banter, nil), do: ""

  def build_banter_prompt(banter, context) when is_binary(context) do
    examples =
      case context do
        "greeting" -> sample_banter(banter, "greetings", 5)
        "reaction" -> sample_banter(banter, "reactions", 5)
        "idle" -> sample_banter(banter, "idle_chat", 5)
        "bad_beat" -> sample_banter(banter, "bad_beats", 5)
        "big_pot" -> sample_banter(banter, "big_pots", 5)
        "leaving" -> sample_banter(banter, "leaving", 5)
        _ -> []
      end

    if examples == [] do
      ""
    else
      """
      Examples of table talk in this context (inspiration only - paraphrase, do not copy):
      #{Enum.map_join(examples, "\n", fn ex -> "- \"#{ex}\"" end)}
      """
    end
  end

  @doc """
  Determine the appropriate banter context based on game state.
  """
  @spec detect_banter_context(map()) :: String.t() | nil
  def detect_banter_context(state) do
    cond do
      # First hand of match
      state.hand_index == 1 and is_nil(state.last_hand_result) ->
        "greeting"

      # Big pot (all-in or large bet)
      state.pot > state.big_blind * 10 ->
        "big_pot"

      # Recent bad beat (could track this in state)
      # For now, default to idle/reaction
      true ->
        nil
    end
  end

  @doc """
  Get statistics about the banter library.
  Shows counts per category and total unique lines.
  """
  @spec banter_stats() :: %{total: integer(), by_category: %{String.t() => integer()}}
  def banter_stats do
    banter = load_banter()

    by_category =
      banter
      |> Enum.map(fn {category, examples} -> {category, length(examples)} end)
      |> Enum.into(%{})

    total = by_category |> Map.values() |> Enum.sum()

    %{total: total, by_category: by_category}
  end

  @doc """
  Refresh banter library by discovering any new .txt files in banter directory.
  Returns list of loaded categories.
  """
  @spec refresh_banter() :: [String.t()]
  def refresh_banter do
    @banter_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".txt"))
    |> Enum.map(&String.replace_suffix(&1, ".txt", ""))
  end

  # Private helpers

  defp load_banter_file(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

        _ ->
          []
      end
    else
      []
    end
  end
end
