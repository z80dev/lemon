defmodule LemonSim.Examples.WerewolfActionSpaceTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.ActionSpace
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Kernel.State
  alias LemonAi.Types.Model

  test "runoff voting forces a choice between the finalists" do
    state =
      State.new(
        sim_id: "werewolf-runoff-vote",
        world: %{
          status: "in_progress",
          phase: "runoff_voting",
          active_actor_id: "Alice",
          runoff_candidates: ["Bram", "Cora"],
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "cast_vote"
    assert tool.parameters["properties"]["target_id"]["enum"] == ["Bram", "Cora"]
    refute "skip" in tool.parameters["properties"]["target_id"]["enum"]
  end

  test "day voting also forces a vote target" do
    state =
      State.new(
        sim_id: "werewolf-day-vote",
        world: %{
          status: "in_progress",
          phase: "day_voting",
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "cast_vote"
    assert tool.parameters["properties"]["target_id"]["enum"] == ["Bram", "Cora"]
    refute "skip" in tool.parameters["properties"]["target_id"]["enum"]
  end

  test "seer investigates on night 1" do
    state =
      State.new(
        sim_id: "werewolf-seer-night-1",
        world: %{
          status: "in_progress",
          phase: "night",
          day_number: 1,
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "seer", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])

    assert tool.name == "investigate_player"
    assert tool.parameters["properties"]["target_id"]["enum"] == ["Bram", "Cora"]
    assert tool.parameters["properties"]["meeting_target_id"]["enum"] == ["Bram", "Cora"]
    assert "meeting_target_id" in tool.parameters["required"]
  end

  test "private thoughts are bounded" do
    state =
      State.new(
        sim_id: "werewolf-thought-limit",
        world: %{
          status: "in_progress",
          phase: "day_voting",
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [action]} = ActionSpace.available_actions(state, "Alice")
    assert action["parameters"]["properties"]["thought"]["maxLength"] == 600

    assert {:error, :invalid_parameters} =
             ActionSpace.execute_action(state, "Alice", "cast_vote", %{
               "target_id" => "Bram",
               "thought" => String.duplicate("x", 601)
             })
  end

  test "model output budgets leave GLM enough room to complete tool calls" do
    opts =
      Werewolf.default_opts(
        model: %Model{id: "test", name: "test", provider: :test, api: :openai_completions},
        stream_options: %{}
      )

    budget = Keyword.fetch!(opts, :stream_options_for_model)

    glm = budget.(%Model{id: "glm-5.1", name: "GLM", provider: :opencode_go})
    assert glm.max_tokens == 768
    assert glm.reasoning == false
    assert glm.tool_choice == :any

    gpt = budget.(%Model{id: "gpt", name: "GPT", provider: :github_copilot})
    assert gpt.max_tokens == 768
    assert gpt.tool_choice == :any

    # DeepSeek via OpenCode Go rejects tool_choice "required" while thinking is
    # enabled, so reasoning must be forced off (reasoning_effort "none").
    ds = budget.(%Model{id: "deepseek-v4-flash", name: "DS", provider: :opencode_go})
    assert ds.max_tokens == 768
    assert ds.reasoning == :none
    assert ds.tool_choice == :any
  end

  test "doctor cannot protect the same player on consecutive nights" do
    state =
      State.new(
        sim_id: "werewolf-doctor-rotation",
        world: %{
          status: "in_progress",
          phase: "night",
          active_actor_id: "Alice",
          night_history: [%{player: "Alice", action: "protect", target: "Bram"}],
          players: %{
            "Alice" => %{role: "doctor", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [tool]} = ActionSpace.tools(state, [])
    refute "Bram" in tool.parameters["properties"]["target_id"]["enum"]
  end

  test "night action records the meeting preference in the authoritative event" do
    state =
      State.new(
        sim_id: "werewolf-night-meeting",
        world: %{
          status: "in_progress",
          phase: "night",
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "seer", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, event} =
             ActionSpace.execute_action(state, "Alice", "investigate_player", %{
               "target_id" => "Cora",
               "meeting_target_id" => "Bram"
             })

    assert event.payload["meeting_target_id"] == "Bram"
  end

  test "fallback records a missed decision and emits a legal action" do
    state =
      State.new(
        sim_id: "werewolf-fallback",
        world: %{
          status: "in_progress",
          phase: "day_voting",
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [missed, action]} = ActionSpace.fallback_events(state, :empty_response)
    assert missed.kind == "decision_missed"
    assert missed.payload["fallback_action"] == "cast_vote"
    assert action.kind == "cast_vote"
    assert action.payload["target_id"] == "Bram"
  end

  test "hosted actions embed the authoritative actor and reject unlisted input" do
    state =
      State.new(
        sim_id: "werewolf-hosted-command",
        world: %{
          status: "in_progress",
          phase: "day_voting",
          active_actor_id: "Alice",
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "villager", status: "alive"},
            "Cora" => %{role: "werewolf", status: "alive"}
          }
        }
      )

    assert {:ok, [action]} = ActionSpace.available_actions(state, "Alice")
    assert action["name"] == "cast_vote"
    assert {:ok, []} = ActionSpace.available_actions(state, "Bram")

    assert {:ok, event} =
             ActionSpace.execute_action(state, "Alice", "cast_vote", %{"target_id" => "Bram"})

    assert event.payload["player_id"] == "Alice"
    assert event.payload["target_id"] == "Bram"

    assert {:error, :not_active_actor} =
             ActionSpace.execute_action(state, "Bram", "cast_vote", %{"target_id" => "Alice"})

    assert {:error, :invalid_parameters} =
             ActionSpace.execute_action(state, "Alice", "cast_vote", %{
               "target_id" => "Cora",
               "player_id" => "Bram"
             })

    assert {:error, :invalid_parameters} =
             ActionSpace.execute_action(state, "Alice", "cast_vote", %{
               "target_id" => "not-a-player"
             })
  end

  test "classic rules remove wandering from the villager night action" do
    state =
      State.new(
        sim_id: "werewolf-classic-actions",
        world: %{
          status: "in_progress",
          phase: "night",
          day_number: 2,
          active_actor_id: "Alice",
          rules: LemonSim.Examples.Werewolf.RulesConfig.for_preset("classic"),
          players: %{
            "Alice" => %{role: "villager", status: "alive"},
            "Bram" => %{role: "werewolf", status: "alive"}
          },
          player_items: %{}
        }
      )

    assert {:ok, actions} = ActionSpace.available_actions(state, "Alice")
    assert Enum.map(actions, & &1["name"]) == ["sleep"]
  end

  test "eliminated players get the make_last_words tool in last-words phases" do
    for phase <- ["last_words_night", "last_words_vote"] do
      state =
        State.new(
          sim_id: "werewolf-last-words",
          world: %{
            status: "in_progress",
            phase: phase,
            active_actor_id: "Bram",
            players: %{
              "Bram" => %{role: "villager", status: "dead"},
              "Alice" => %{role: "villager", status: "alive"},
              "Cora" => %{role: "werewolf", status: "alive"}
            }
          }
        )

      assert {:ok, [tool]} = ActionSpace.tools(state, [])
      assert tool.name == "make_last_words"
    end
  end

  test "projector opts never instruct the model to consult memory files" do
    opts = Werewolf.projector_opts()

    system_prompt = Keyword.fetch!(opts, :system_prompt)
    refute system_prompt =~ "Use memory tools"
    # the prompt must explicitly forbid the hallucinated tools instead
    assert system_prompt =~ "read_index"

    memory = opts |> Keyword.fetch!(:section_overrides) |> Map.get(:memory)

    assert memory[:content] =~ "no memory files"
    refute memory[:content] =~ "Read index.md first"
  end
end
