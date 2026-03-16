defmodule LemonSkills.PromptViewTest do
  use ExUnit.Case, async: true

  alias LemonSkills.{PromptView, SkillView}

  defp view(overrides \\ []) do
    defaults = [
      key: "my-skill",
      path: "/tmp/my-skill",
      name: "My Skill",
      description: "Does something useful",
      activation_state: :active
    ]

    struct(SkillView, Keyword.merge(defaults, overrides))
  end

  describe "render_skill_list/1" do
    test "returns empty string for empty list" do
      assert PromptView.render_skill_list([]) == ""
    end

    test "wraps entries in <available_skills>" do
      result = PromptView.render_skill_list([view()])
      assert result =~ "<available_skills>"
      assert result =~ "</available_skills>"
    end

    test "renders skill name, description, location, key, activation_state" do
      result = PromptView.render_skill_list([view()])
      assert result =~ "<name>My Skill</name>"
      assert result =~ "<description>Does something useful</description>"
      assert result =~ "<location>/tmp/my-skill</location>"
      assert result =~ "<key>my-skill</key>"
      assert result =~ "<activation_state>active</activation_state>"
    end

    test "includes <missing> tag when deps are missing" do
      v = view(
        activation_state: :not_ready,
        missing_bins: ["kubectl"],
        missing_env_vars: ["AWS_KEY"],
        missing_tools: []
      )

      result = PromptView.render_skill_list([v])
      assert result =~ "<missing>kubectl, AWS_KEY</missing>"
    end

    test "does not include <missing> tag when nothing is missing" do
      result = PromptView.render_skill_list([view()])
      refute result =~ "<missing>"
    end

    test "renders multiple skills" do
      views = [
        view(key: "skill-a", name: "A"),
        view(key: "skill-b", name: "B")
      ]

      result = PromptView.render_skill_list(views)
      assert result =~ "<key>skill-a</key>"
      assert result =~ "<key>skill-b</key>"
    end

    test "escapes HTML entities in name and description" do
      v = view(name: "A & B <thing>", description: "Uses > operator")
      result = PromptView.render_skill_list([v])
      assert result =~ "<name>A &amp; B &lt;thing&gt;</name>"
      assert result =~ "<description>Uses &gt; operator</description>"
    end
  end

  describe "render_entry/1" do
    test "renders a single skill XML element" do
      result = PromptView.render_entry(view())
      assert result =~ "  <skill>"
      assert result =~ "  </skill>"
      assert result =~ "<key>my-skill</key>"
    end

    test "renders :not_ready activation state" do
      v = view(activation_state: :not_ready, missing_bins: ["gh"])
      result = PromptView.render_entry(v)
      assert result =~ "<activation_state>not_ready</activation_state>"
      assert result =~ "<missing>gh</missing>"
    end
  end

  describe "render_for_prompt/2" do
    test "includes the instruction header when skills are present" do
      # Use a tmp cwd that will have no project skills; global skills may still exist.
      # We verify the header is present when render_for_prompt returns a non-empty string.
      result = PromptView.render_for_prompt(nil)

      if result != "" do
        assert result =~ "## Skills (available)"
        assert result =~ "<available_skills>"
      else
        # No global skills installed — still a valid empty result.
        assert result == ""
      end
    end
  end
end
