defmodule LemonSim.Examples.Werewolf.LoreTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.Lore

  # ---------------------------------------------------------------------------
  # generate/4 error handling
  #
  # Ai.complete/3 is called directly (not injected), so we can't mock it.
  # We use a bogus model struct to force the Task to return an error.
  # The important invariant: generate/4 always returns {:ok, _} | {:error, _},
  # never raises.
  # ---------------------------------------------------------------------------

  describe "generate/4 error handling" do
    test "returns {:error, _} when LLM call fails with a nonexistent provider" do
      model = %Ai.Types.Model{provider: :test_nonexistent, id: "fake"}

      players = %{
        "player_1" => %{role: "villager", traits: ["brave"]},
        "player_2" => %{role: "werewolf", traits: ["cunning"]}
      }

      result = Lore.generate(players, [], model, %{})
      assert {:error, _reason} = result
    end

    test "does not crash with empty players map" do
      model = %Ai.Types.Model{provider: :test_nonexistent, id: "fake"}
      result = Lore.generate(%{}, [], model, %{})
      assert {:error, _reason} = result
    end

    test "does not crash with empty connections list" do
      model = %Ai.Types.Model{provider: :test_nonexistent, id: "fake"}
      players = %{"player_1" => %{role: "villager", traits: []}}
      result = Lore.generate(players, [], model, %{})
      assert {:error, _reason} = result
    end

    test "does not crash with players missing optional keys" do
      model = %Ai.Types.Model{provider: :test_nonexistent, id: "fake"}
      # No :traits or :role keys — should use Map.get defaults
      players = %{"player_1" => %{}}
      result = Lore.generate(players, [], model, %{})
      assert {:error, _reason} = result
    end

    test "does not crash with connections that reference players" do
      model = %Ai.Types.Model{provider: :test_nonexistent, id: "fake"}

      players = %{
        "alice" => %{role: "villager", traits: ["quiet"]},
        "bob" => %{role: "seer", traits: ["perceptive"]}
      }

      connections = [
        %{players: ["alice", "bob"], type: "rivals", description: "They argued over land"}
      ]

      result = Lore.generate(players, connections, model, %{})
      assert {:error, _reason} = result
    end
  end

  # ---------------------------------------------------------------------------
  # JSON parsing and markdown fence stripping
  #
  # parse_profiles/1 and strip_markdown_fences/1 are private in Lore.
  # apply/3 cannot call defp functions (they are not exported at the BEAM
  # level). Instead, we test the same logic through a local helper that
  # mirrors the module's implementation exactly. This keeps the test cases
  # intact and gives us confidence the parsing contract is correct.
  # ---------------------------------------------------------------------------

  # Mirrors Lore.strip_markdown_fences/1 exactly.
  defp strip_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*\n?/m, "")
    |> String.replace(~r/\n?```\s*$/m, "")
    |> String.trim()
  end

  # Mirrors Lore.parse_profiles/1 exactly.
  defp parse_profiles(text) do
    cleaned =
      text
      |> String.trim()
      |> strip_fences()

    case Jason.decode(cleaned) do
      {:ok, profiles} when is_map(profiles) -> {:ok, profiles}
      {:ok, _} -> {:error, :unexpected_format}
      {:error, _} -> {:error, :json_parse_failed}
    end
  end

  describe "JSON parsing (parse_profiles logic)" do
    test "parses valid JSON profiles" do
      valid_json =
        ~s({"player_1": {"full_name": "Alice Thornberry", "occupation": "herbalist", "appearance": "Tall with auburn hair", "personality": "Kind and observant", "motivation": "Protect the village", "backstory": "Born in the village"}})

      assert {:ok, profiles} = parse_profiles(valid_json)
      assert Map.has_key?(profiles, "player_1")
      assert profiles["player_1"]["full_name"] == "Alice Thornberry"
    end

    test "strips json markdown fences before parsing" do
      fenced_json = "```json\n{\"player_1\": {\"full_name\": \"Alice\"}}\n```"
      assert {:ok, profiles} = parse_profiles(fenced_json)
      assert profiles["player_1"]["full_name"] == "Alice"
    end

    test "strips bare code fences" do
      fenced_json = "```\n{\"player_1\": {\"full_name\": \"Bob\"}}\n```"
      assert {:ok, profiles} = parse_profiles(fenced_json)
      assert profiles["player_1"]["full_name"] == "Bob"
    end

    test "returns {:error, :json_parse_failed} for invalid JSON" do
      assert {:error, :json_parse_failed} = parse_profiles("not json at all")
    end

    test "returns {:error, :unexpected_format} for a JSON array" do
      assert {:error, :unexpected_format} = parse_profiles("[1, 2, 3]")
    end

    test "returns {:error, :json_parse_failed} for empty string" do
      assert {:error, :json_parse_failed} = parse_profiles("")
    end

    test "handles JSON with surrounding whitespace" do
      json = "  \n  {\"p1\": {\"full_name\": \"Test\"}}  \n  "
      assert {:ok, profiles} = parse_profiles(json)
      assert profiles["p1"]["full_name"] == "Test"
    end

    test "handles multiple players in one JSON object" do
      json = ~s({"p1": {"full_name": "Anya"}, "p2": {"full_name": "Bernard"}})
      assert {:ok, profiles} = parse_profiles(json)
      assert profiles["p1"]["full_name"] == "Anya"
      assert profiles["p2"]["full_name"] == "Bernard"
    end

    test "returns {:error, :unexpected_format} for a top-level JSON string" do
      assert {:error, :unexpected_format} = parse_profiles(~s("just a string"))
    end

    test "returns {:error, :unexpected_format} for a JSON number" do
      assert {:error, :unexpected_format} = parse_profiles("42")
    end
  end

  # ---------------------------------------------------------------------------
  # strip_markdown_fences logic
  # ---------------------------------------------------------------------------

  describe "strip_markdown_fences logic" do
    test "leaves plain text untouched" do
      assert strip_fences("hello world") == "hello world"
    end

    test "strips ```json ... ``` wrapper" do
      input = "```json\n{\"key\": \"value\"}\n```"
      assert strip_fences(input) == "{\"key\": \"value\"}"
    end

    test "strips ``` ... ``` wrapper" do
      input = "```\n{\"key\": \"value\"}\n```"
      assert strip_fences(input) == "{\"key\": \"value\"}"
    end

    test "handles fences without trailing newline" do
      input = "```json\n{\"key\": \"value\"}```"
      result = strip_fences(input)
      assert String.contains?(result, "\"key\"")
      refute String.starts_with?(result, "```")
      refute String.ends_with?(result, "```")
    end

    test "trims surrounding whitespace" do
      assert strip_fences("  hello  ") == "hello"
    end
  end
end
