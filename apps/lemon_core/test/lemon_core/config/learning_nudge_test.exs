defmodule LemonCore.Config.LearningNudgeTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.{Modular, ProjectLayer}

  test "[skills.learning_nudge] resolves as a raw table, empty by default" do
    assert {:ok, config} = Modular.validate_settings(%{})
    assert config.skills.learning_nudge == %{}

    nudge = %{
      "enabled" => true,
      "memory_turn_interval" => 4,
      "background_review" => %{"enabled" => true, "model" => "openai:gpt-4o-mini"}
    }

    assert {:ok, config} =
             Modular.validate_settings(%{"skills" => %{"learning_nudge" => nudge}})

    assert config.skills.learning_nudge == nudge
  end

  test "invalid and unknown learning_nudge keys are rejected rather than coerced" do
    for {nudge, key} <- [
          {%{"memory_turn_interval" => 0}, "memory_turn_interval"},
          {%{"skill_tool_threshold" => "15"}, "skill_tool_threshold"},
          {%{"enabled" => "yes"}, "enabled"},
          {%{"cadence" => 1}, "cadence"},
          {%{"background_review" => %{"timeout_ms" => -1}}, "background_review.timeout_ms"},
          {%{"background_review" => %{"model" => ""}}, "background_review.model"},
          {%{"background_review" => true}, "background_review"}
        ] do
      assert {:error, errors} =
               Modular.validate_settings(%{"skills" => %{"learning_nudge" => nudge}})

      assert Enum.any?(errors, &String.contains?(&1, "skills.learning_nudge." <> key)),
             inspect(errors)
    end

    assert {:error, errors} = Modular.validate_settings(%{"skills" => %{"learning_nudge" => 1}})
    assert Enum.any?(errors, &String.contains?(&1, "skills.learning_nudge: must be a table"))
  end

  test "a project layer can only narrow learning reminders" do
    operator = %{"skills" => %{"learning_nudge" => %{"memory_turn_interval" => 20}}}

    project = %{
      "skills" => %{
        "learning_nudge" => %{
          "enabled" => true,
          "memory_turn_interval" => 5,
          "skill_tool_threshold" => 30,
          "background_review" => %{"enabled" => true, "model" => "attacker:model"}
        }
      }
    }

    {merged, rejected} = ProjectLayer.merge(operator, project)

    assert merged["skills"]["learning_nudge"] == %{
             "memory_turn_interval" => 20,
             "skill_tool_threshold" => 30
           }

    assert {"skills.learning_nudge.enabled", :narrow_only} in rejected
    assert {"skills.learning_nudge.memory_turn_interval", :narrow_only} in rejected
    assert {"skills.learning_nudge.background_review.enabled", :operator_only} in rejected
    assert {"skills.learning_nudge.background_review.model", :operator_only} in rejected

    project = %{
      "skills" => %{"learning_nudge" => %{"enabled" => false, "memory_turn_interval" => 40}}
    }

    {merged, []} = ProjectLayer.merge(operator, project)

    assert merged["skills"]["learning_nudge"] == %{
             "enabled" => false,
             "memory_turn_interval" => 40
           }

    # Without an operator value the default (15) is the floor.
    {merged, [_]} =
      ProjectLayer.merge(%{}, %{"skills" => %{"learning_nudge" => %{"skill_tool_threshold" => 3}}})

    refute get_in(merged, ["skills", "learning_nudge", "skill_tool_threshold"])
  end
end
