defmodule LemonSkills.SkillViewTest do
  use ExUnit.Case, async: true

  alias LemonSkills.{Entry, SkillView}

  defp entry(overrides \\ []) do
    defaults = [
      key: "test-skill",
      path: "/tmp/test-skill",
      name: "Test Skill",
      description: "A test skill",
      enabled: true,
      manifest: %{}
    ]

    struct(Entry, Keyword.merge(defaults, overrides))
  end

  describe "from_entry/2" do
    test "builds a view with active state for a ready skill" do
      view = SkillView.from_entry(entry())
      assert view.key == "test-skill"
      assert view.name == "Test Skill"
      assert view.description == "A test skill"
      assert view.path == "/tmp/test-skill"
      assert view.activation_state == :active
      assert view.platform_compatible == true
      assert view.missing_bins == []
      assert view.missing_env_vars == []
      assert view.missing_tools == []
    end

    test "carries trust_level and source_kind from entry" do
      e = entry(trust_level: :official, source_kind: :registry)
      view = SkillView.from_entry(e)
      assert view.trust_level == :official
      assert view.source_kind == :registry
    end

    test "activation_state is :hidden when entry is disabled" do
      e = entry(enabled: false)
      view = SkillView.from_entry(e)
      assert view.activation_state == :hidden
    end

    test "activation_state is :not_ready when bins are missing" do
      missing_bin = "definitely-missing-#{System.unique_integer([:positive])}"
      e = entry(manifest: %{"requires" => %{"bins" => [missing_bin]}})
      view = SkillView.from_entry(e)
      assert view.activation_state == :not_ready
      assert view.missing_bins == [missing_bin]
    end

    test "activation_state is :platform_incompatible for wrong platform" do
      e = entry(manifest: %{"platforms" => ["win32"]})

      view =
        case :os.type() do
          {:win32, _} ->
            # On Windows, win32 is compatible; use linux instead
            SkillView.from_entry(entry(manifest: %{"platforms" => ["linux"]}))

          _ ->
            SkillView.from_entry(e)
        end

      assert view.activation_state == :platform_incompatible
      assert view.platform_compatible == false
    end

    test "platforms defaults to ['any'] when manifest has no platforms key" do
      view = SkillView.from_entry(entry(manifest: %{}))
      assert view.platforms == ["any"]
    end
  end

  describe "displayable?/1" do
    test "returns true for :active" do
      view = %SkillView{key: "k", path: "/p", activation_state: :active}
      assert SkillView.displayable?(view)
    end

    test "returns true for :not_ready" do
      view = %SkillView{key: "k", path: "/p", activation_state: :not_ready}
      assert SkillView.displayable?(view)
    end

    test "returns false for :hidden" do
      view = %SkillView{key: "k", path: "/p", activation_state: :hidden}
      refute SkillView.displayable?(view)
    end

    test "returns false for :platform_incompatible" do
      view = %SkillView{key: "k", path: "/p", activation_state: :platform_incompatible}
      refute SkillView.displayable?(view)
    end

    test "returns false for :blocked" do
      view = %SkillView{key: "k", path: "/p", activation_state: :blocked}
      refute SkillView.displayable?(view)
    end
  end

  describe "active?/1" do
    test "true only for :active" do
      assert SkillView.active?(%SkillView{key: "k", path: "/p", activation_state: :active})
      refute SkillView.active?(%SkillView{key: "k", path: "/p", activation_state: :not_ready})
      refute SkillView.active?(%SkillView{key: "k", path: "/p", activation_state: :hidden})
    end
  end

  describe "all_missing/1" do
    test "aggregates bins, env_vars, and tools" do
      view = %SkillView{
        key: "k",
        path: "/p",
        missing_bins: ["kubectl"],
        missing_env_vars: ["AWS_KEY"],
        missing_tools: ["helm"]
      }

      assert SkillView.all_missing(view) == ["kubectl", "AWS_KEY", "helm"]
    end

    test "returns empty list when nothing is missing" do
      view = %SkillView{key: "k", path: "/p"}
      assert SkillView.all_missing(view) == []
    end
  end
end
