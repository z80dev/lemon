defmodule LemonSim.Examples.SpaceStation.Lore do
  @moduledoc """
  Generates rich character profiles for space station crew members via LLM.

  Produces backstories, occupations, and personality expansions that
  make each game feel like a unique story. Falls back gracefully if
  generation fails — the game always starts regardless.
  """

  alias Ai.Types.{Context, AssistantMessage, UserMessage}

  @timeout_ms 15_000

  @doc """
  Generates rich character profiles via LLM.

  Returns `{:ok, profiles_map}` where profiles_map is `%{player_id => profile_map}`
  or `{:error, reason}`.
  """
  @spec generate(map(), list(), Ai.Types.Model.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def generate(players, connections, model, stream_options) do
    prompt = build_prompt(players, connections)

    context = %Context{
      messages: [%UserMessage{content: prompt}]
    }

    task =
      Task.async(fn ->
        try do
          Ai.complete(model, context, stream_options)
        rescue
          e -> {:error, {:exception, Exception.message(e)}}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, %AssistantMessage{} = msg}} ->
        text = Ai.get_text(msg)
        parse_profiles(text, players)

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        {:error, :timeout}
    end
  end

  defp build_prompt(players, connections) do
    sorted_player_ids =
      players
      |> Map.keys()
      |> Enum.sort()

    player_descriptions =
      players
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map(fn {id, info} ->
        traits = Map.get(info, :traits, [])
        role = Map.get(info, :role, "unknown")

        player_connections =
          connections
          |> Enum.filter(fn conn ->
            players_list = Map.get(conn, :players, [])
            id in players_list
          end)
          |> Enum.map(fn conn ->
            other = conn |> Map.get(:players, []) |> Enum.find(&(&1 != id))
            "#{Map.get(conn, :type, "")}: #{Map.get(conn, :description, "")} (with #{other})"
          end)
          |> Enum.join("; ")

        "- #{id}: role=#{role}, traits=[#{Enum.join(traits, ", ")}]#{if player_connections != "", do: ", connections=[#{player_connections}]", else: ""}"
      end)
      |> Enum.join("\n")

    example_player_id = List.first(sorted_player_ids) || "Alice"

    """
    Generate rich character profiles for a Space Station Crisis game. Each player needs a vivid, \
    memorable backstory that makes them feel like a real crew member on a deep-space station.

    Setting: An isolated research and maintenance station in deep space. The crew has been \
    stationed here for months, maintaining critical systems (oxygen, reactor, hull, comms, \
    navigation, medical, shields). Tensions are rising as systems degrade and someone may be \
    sabotaging the station.

    Players:
    #{player_descriptions}

    For each player, generate a JSON object with these fields:
    - "full_name": An expanded full name (e.g., "Alice Vasquez-Chen")
    - "occupation": A station role (systems engineer, pilot, communications officer, medical officer, security chief, reactor technician, navigation specialist, shield operator, xenobiologist, quartermaster, etc.)
    - "appearance": 1-2 sentence physical description suited to a space crew member
    - "personality": 2-3 sentence personality expansion based on their traits
    - "motivation": A personal secret or driving goal (1 sentence)
    - "backstory": 2-3 sentence narrative incorporating their connections, past missions, training academy experiences, or crew dynamics

    Return ONLY a JSON object where keys are the EXACT player IDs listed above and values are profile objects.
    Example format:
    {"#{example_player_id}": {"full_name": "...", "occupation": "...", "appearance": "...", "personality": "...", "motivation": "...", "backstory": "..."}}

    Important: Do NOT reveal roles in the profiles. The backstory should be role-agnostic — \
    do not hint at whether someone is the saboteur, engineer, captain, or crew.
    """
  end

  defp parse_profiles(text, players) do
    cleaned =
      text
      |> String.trim()
      |> strip_markdown_fences()

    case Jason.decode(cleaned) do
      {:ok, profiles} when is_map(profiles) ->
        normalize_profiles(players, profiles)

      {:ok, _} ->
        {:error, :unexpected_format}

      {:error, _} ->
        {:error, :json_parse_failed}
    end
  end

  defp strip_markdown_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*\n?/m, "")
    |> String.replace(~r/\n?```\s*$/m, "")
    |> String.trim()
  end

  defp normalize_profiles(players, profiles) when is_map(players) and is_map(profiles) do
    player_ids =
      players
      |> Map.keys()
      |> Enum.sort()

    normalized =
      Enum.reduce(profiles, %{}, fn {profile_id, profile}, acc ->
        case normalize_profile_id(profile_id, player_ids) do
          nil ->
            acc

          player_id when is_map(profile) ->
            Map.put(acc, player_id, profile)

          _ ->
            acc
        end
      end)

    if normalized == %{} and profiles != %{} do
      {:error, :unexpected_keys}
    else
      {:ok, normalized}
    end
  end

  defp normalize_profile_id(profile_id, player_ids) when is_atom(profile_id) do
    normalize_profile_id(Atom.to_string(profile_id), player_ids)
  end

  defp normalize_profile_id(profile_id, player_ids) when is_binary(profile_id) do
    cond do
      profile_id in player_ids ->
        profile_id

      Regex.match?(~r/^player_(\d+)$/, profile_id) ->
        case Regex.run(~r/^player_(\d+)$/, profile_id, capture: :all_but_first) do
          [index] ->
            index
            |> String.to_integer()
            |> then(&Enum.at(player_ids, &1 - 1))

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp normalize_profile_id(_, _player_ids), do: nil
end
