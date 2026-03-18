defmodule LemonSim.Examples.WerewolfLoreIntegrationTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf

  describe "initial_world/1 character_profiles" do
    test "world includes character_profiles key defaulting to empty map" do
      world = Werewolf.initial_world()
      assert Map.has_key?(world, :character_profiles)
      assert world.character_profiles == %{}
    end

    test "character_profiles is empty when generate_lore? is false" do
      world = Werewolf.initial_world(generate_lore?: false)
      assert world.character_profiles == %{}
    end

    test "character_profiles is empty when generate_lore? is not provided" do
      world = Werewolf.initial_world(player_count: 5)
      assert world.character_profiles == %{}
    end

    test "world still has all required keys with lore disabled" do
      world = Werewolf.initial_world(player_count: 5)

      assert Map.has_key?(world, :players)
      assert Map.has_key?(world, :phase)
      assert Map.has_key?(world, :day_number)
      assert Map.has_key?(world, :backstory_connections)
      assert Map.has_key?(world, :character_profiles)
      assert Map.has_key?(world, :status)
      assert world.status == "in_progress"
    end

    test "players have traits assigned regardless of lore" do
      world = Werewolf.initial_world(player_count: 6)

      Enum.each(world.players, fn {_id, player} ->
        assert Map.has_key?(player, :traits)
        assert is_list(player.traits)
      end)
    end
  end

  describe "projector role_info includes character_profile" do
    test "role_info section builder includes character_profile when present" do
      role_info_builder = Werewolf.projector_opts()[:section_builders][:role_info]

      frame = %{
        world: %{
          active_actor_id: "Alice",
          phase: "day_discussion",
          day_number: 1,
          players: %{
            "Alice" => %{role: "villager", status: "alive", traits: ["brave"]},
            "Bob" => %{role: "werewolf", status: "alive", traits: ["cunning"]}
          },
          backstory_connections: [],
          journals: %{},
          player_items: %{},
          wanderer_results: [],
          seer_history: [],
          wolf_chat_transcript: [],
          character_profiles: %{
            "Alice" => %{
              "full_name" => "Alice Thornberry",
              "occupation" => "herbalist",
              "appearance" => "Tall with red hair",
              "personality" => "Brave and outspoken",
              "motivation" => "Protect the weak",
              "backstory" => "Born in the village"
            }
          }
        }
      }

      section = role_info_builder.(frame, [], [])
      content = section.content

      assert Map.has_key?(content, "character_profile")
      assert content["character_profile"]["full_name"] == "Alice Thornberry"
    end

    test "role_info omits character_profile when not present" do
      role_info_builder = Werewolf.projector_opts()[:section_builders][:role_info]

      frame = %{
        world: %{
          active_actor_id: "Alice",
          phase: "day_discussion",
          day_number: 1,
          players: %{
            "Alice" => %{role: "villager", status: "alive", traits: []},
            "Bob" => %{role: "werewolf", status: "alive", traits: []}
          },
          backstory_connections: [],
          journals: %{},
          player_items: %{},
          wanderer_results: [],
          seer_history: [],
          wolf_chat_transcript: [],
          character_profiles: %{}
        }
      }

      section = role_info_builder.(frame, [], [])
      content = section.content

      refute Map.has_key?(content, "character_profile")
    end
  end

  describe "decision_contract" do
    test "includes CHARACTER PROFILE instruction" do
      opts = Werewolf.projector_opts()
      contract = opts[:section_overrides][:decision_contract]

      assert contract =~ "CHARACTER PROFILE"
      assert contract =~ "embody your character"
    end
  end
end
