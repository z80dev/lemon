defmodule LemonSkills.PromptRegressionTest do
  @moduledoc """
  Regression tests for prompt size and progressive disclosure (M3-04).

  These tests protect against two categories of regressions:

  1. **Inlining regressions** — accidentally including skill body content in
     bootstrap (system) prompts. The rendered `<available_skills>` block must
     contain only SkillView metadata: name, description, key, path,
     activation_state, and optionally the missing-dependencies list.
     No `## Content`, `## Usage`, `## Examples`, or any other body text
     may appear.

  2. **Size regressions** — progressive disclosure is broken when
     `view="summary"` is as large as `view="full"`. Tests assert that
     character counts satisfy: summary << full, and that summary size is
     independent of body length (i.e. body growth doesn't inflate the
     bootstrap prompt).

  ## Deterministic regression loop

  This file is included in the `Deterministic regression loop` step of
  `quality.yml` and run twice to catch any non-determinism in prompt
  rendering or snapshot sizes.
  """

  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias LemonSkills.{PromptView, SkillView}
  alias LemonSkills.Tools.ReadSkill

  @moduletag :tmp_dir

  # Character-count budgets used in snapshot assertions.
  # These are deliberate — if a future change would cause prompt size to
  # exceed these thresholds, the test fails and the engineer must justify
  # and update the budget explicitly rather than silently inflating prompts.

  # Maximum chars for a single skill entry in the bootstrap XML block.
  # A full skill's SKILL.md can easily be 2 000–20 000 chars; 1 000 chars per
  # slot is generous for just the metadata fields (name + description + path
  # + key + activation_state + up to several missing deps), while being far
  # smaller than any skill body that would indicate an inlining regression.
  @max_chars_per_skill_slot 1_000

  # Minimum ratio by which full > summary.  If a skill has a 2 000-char
  # body and its summary is only 300 chars, the ratio should be > 3×.
  @full_to_summary_min_ratio 3

  # ──────────────────────────────────────────────────────────────────────────
  # Setup
  # ──────────────────────────────────────────────────────────────────────────

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")

    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")

    File.mkdir_p!(home)
    File.mkdir_p!(agent_dir)

    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    LemonSkills.refresh()

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
      LemonSkills.refresh()
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Part 1: Bootstrap prompt inlining protection
  #
  # PromptView builds bootstrap XML from SkillView structs.  SkillView has
  # no body field — so body content can never appear here by design.  These
  # tests assert that invariant holds for representative render paths.
  # ──────────────────────────────────────────────────────────────────────────

  describe "bootstrap prompt — no body content" do
    test "render_skill_list/1 output contains only metadata fields" do
      view = skill_view("k8s-rollout",
        name: "K8s Rollout",
        description: "Manage Kubernetes rollouts with kubectl",
        activation_state: :active
      )

      xml = PromptView.render_skill_list([view])

      assert xml =~ "<name>K8s Rollout</name>"
      assert xml =~ "<description>Manage Kubernetes rollouts with kubectl</description>"
      assert xml =~ "<key>k8s-rollout</key>"
      assert xml =~ "<activation_state>active</activation_state>"

      # Must NOT contain body-like structure markers
      refute xml =~ "## Content"
      refute xml =~ "## Usage"
      refute xml =~ "## Overview"
      refute xml =~ "## Examples"
      refute xml =~ "## Steps"
      refute xml =~ "SKILL.md"
    end

    test "render_relevant_skills/1 output contains only metadata fields" do
      views = [
        skill_view("deploy-aws",
          name: "Deploy AWS",
          description: "Deploy to AWS with CDK",
          activation_state: :active
        ),
        skill_view("helm-chart",
          name: "Helm Chart",
          description: "Manage Helm chart deployments",
          activation_state: :not_ready,
          missing_bins: ["helm"]
        )
      ]

      block = PromptView.render_relevant_skills(views)

      assert block =~ "<key>deploy-aws</key>"
      assert block =~ "<key>helm-chart</key>"
      assert block =~ "<missing>helm</missing>"

      # Must not inline body content
      refute block =~ "## Content"
      refute block =~ "## Usage"
    end

    test "render_skill_list/1 size is bounded regardless of how many skills are shown" do
      # Construct 10 skills with descriptions of varying length.
      # The rendered block must stay within the per-slot budget × count.
      views =
        for i <- 1..10 do
          skill_view("skill-#{i}",
            name: "Skill #{i}",
            description: "Description for skill #{i} — " <> String.duplicate("x", 100),
            activation_state: :active
          )
        end

      xml = PromptView.render_skill_list(views)
      char_count = String.length(xml)
      max_allowed = @max_chars_per_skill_slot * length(views)

      assert char_count <= max_allowed,
             "Bootstrap XML grew to #{char_count} chars for #{length(views)} skills " <>
               "(max #{max_allowed}). Possible body inlining regression."
    end

    test "single skill XML entry stays within per-slot budget" do
      view = skill_view("my-skill",
        name: "My Skill",
        description: String.duplicate("A very long description. ", 20),
        activation_state: :not_ready,
        missing_bins: ["tool1", "tool2"],
        missing_env_vars: ["SECRET_KEY", "API_TOKEN"]
      )

      entry = PromptView.render_entry(view)
      char_count = String.length(entry)

      assert char_count <= @max_chars_per_skill_slot,
             "Single skill entry is #{char_count} chars, exceeds budget of #{@max_chars_per_skill_slot}"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Part 2: Progressive disclosure size ordering
  #
  # These tests use real skill files via ReadSkill.execute/5.
  # Key invariant: summary_size << full_size, regardless of how large the
  # skill body grows.
  # ──────────────────────────────────────────────────────────────────────────

  describe "progressive disclosure — summary smaller than full" do
    test "summary view is smaller than full view", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "size-test-skill", """
      ---
      name: Size Test Skill
      description: Used to test progressive disclosure sizing
      ---

      ## Overview

      This skill has a moderately long body to ensure the size difference
      between summary and full is meaningful. #{String.duplicate("Detail text. ", 50)}

      ## Usage

      Step 1: Do this. Step 2: Do that. #{String.duplicate("Follow this pattern. ", 40)}

      ## Examples

      #{String.duplicate("Example line with content. ", 30)}
      """)

      LemonSkills.refresh(cwd: tmp_dir)

      summary_text = read_skill_text(tmp_dir, "size-test-skill", "summary")
      full_text = read_skill_text(tmp_dir, "size-test-skill", "full")

      refute summary_text =~ "## Content", "summary must not include ## Content"
      assert full_text =~ "## Content", "full must include ## Content"

      summary_len = String.length(summary_text)
      full_len = String.length(full_text)

      assert full_len > summary_len,
             "full (#{full_len}) should be larger than summary (#{summary_len})"

      assert full_len >= summary_len * @full_to_summary_min_ratio,
             "full (#{full_len}) should be ≥#{@full_to_summary_min_ratio}× summary (#{summary_len}). " <>
               "Progressive disclosure may be broken."
    end

    test "section view is smaller than full view and larger than summary", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "section-size-skill", """
      ---
      name: Section Size Skill
      description: Multi-section skill for size comparison
      ---

      ## Setup

      #{String.duplicate("Setup instruction. ", 30)}

      ## Usage

      #{String.duplicate("Usage instruction. ", 30)}

      ## Troubleshooting

      #{String.duplicate("Troubleshooting step. ", 30)}
      """)

      LemonSkills.refresh(cwd: tmp_dir)

      summary_len = read_skill_text(tmp_dir, "section-size-skill", "summary") |> String.length()
      section_len = read_skill_text(tmp_dir, "section-size-skill", "section", "Usage") |> String.length()
      full_len = read_skill_text(tmp_dir, "section-size-skill", "full") |> String.length()

      assert summary_len < full_len,
             "summary (#{summary_len}) should be < full (#{full_len})"

      assert section_len < full_len,
             "section (#{section_len}) should be < full (#{full_len})"

      assert section_len > summary_len,
             "section (#{section_len}) should be > summary (#{summary_len})"
    end

    test "summary size is body-independent — large body doesn't inflate summary", %{tmp_dir: tmp_dir} do
      # Skill A: tiny body
      write_skill!(tmp_dir, "small-body-skill", """
      ---
      name: Small Body Skill
      description: Has a tiny body
      ---

      Short.
      """)

      # Skill B: huge body (50× larger)
      write_skill!(tmp_dir, "large-body-skill", """
      ---
      name: Large Body Skill
      description: Has a huge body
      ---

      #{String.duplicate("This is a very long body paragraph with lots of instructions. ", 200)}
      """)

      LemonSkills.refresh(cwd: tmp_dir)

      small_summary_len = read_skill_text(tmp_dir, "small-body-skill", "summary") |> String.length()
      large_summary_len = read_skill_text(tmp_dir, "large-body-skill", "summary") |> String.length()

      # Headers are identical structure; the difference should only be the
      # description difference, not the body size.  Both summaries should be
      # within 2× of each other.
      ratio = large_summary_len / max(small_summary_len, 1)

      assert ratio < 2.0,
             "Large-body summary (#{large_summary_len}) is #{Float.round(ratio, 2)}× the " <>
               "small-body summary (#{small_summary_len}). Body growth is leaking into summaries."
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Part 3: Snapshot regression
  #
  # These tests capture a representative prompt size for a known skill set
  # and assert it stays within a documented range.  Updating the range
  # requires an explicit, reviewable code change — preventing silent prompt
  # bloat from slipping through code review.
  # ──────────────────────────────────────────────────────────────────────────

  describe "prompt snapshot — character budget" do
    @doc """
    Representative snapshot: 5 skills with realistic names and descriptions.

    Expected output range:
    - Lower bound: 5 × ~120 chars (name + description + structural XML)
    - Upper bound: 5 × #{@max_chars_per_skill_slot} chars (the per-slot budget)

    If this test fails with a count above the upper bound, a body-inlining
    regression has occurred.  If it falls below the lower bound, the prompt
    renderer may have regressed to dropping fields.
    """
    test "5-skill bootstrap prompt stays within documented character budget" do
      views = [
        skill_view("terraform-plan",
          name: "Terraform Plan",
          description: "Run terraform plan and review infrastructure changes",
          activation_state: :active
        ),
        skill_view("docker-compose-up",
          name: "Docker Compose Up",
          description: "Start local dev stack with docker-compose",
          activation_state: :not_ready,
          missing_bins: ["docker"]
        ),
        skill_view("git-flow-release",
          name: "Git Flow Release",
          description: "Create and merge a git-flow release branch",
          activation_state: :active
        ),
        skill_view("pytest-coverage",
          name: "Pytest Coverage",
          description: "Run pytest with coverage reporting and thresholds",
          activation_state: :active
        ),
        skill_view("migrate-db",
          name: "Migrate DB",
          description: "Run Ecto or Alembic migrations with rollback safety",
          activation_state: :not_ready,
          missing_env_vars: ["DATABASE_URL"]
        )
      ]

      xml = PromptView.render_skill_list(views)
      char_count = String.length(xml)

      # Lower bound: each skill should produce at least some output
      min_chars = length(views) * 100
      max_chars = length(views) * @max_chars_per_skill_slot

      assert char_count >= min_chars,
             "Prompt snapshot too small (#{char_count} < #{min_chars}). " <>
               "Rendering may be stripping required fields."

      assert char_count <= max_chars,
             "Prompt snapshot too large (#{char_count} > #{max_chars}). " <>
               "Body content may have been accidentally inlined.\n\n" <>
               "Snapshot:\n#{xml}"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp skill_view(key, opts) do
    defaults = [
      path: "/tmp/skills/#{key}",
      name: key,
      description: "Description for #{key}",
      activation_state: :active,
      missing_bins: [],
      missing_env_vars: [],
      missing_tools: []
    ]

    struct(SkillView, [key: key] ++ Keyword.merge(defaults, opts))
  end

  defp read_skill_text(tmp_dir, key, view, section \\ nil) do
    params =
      %{"key" => key, "view" => view}
      |> then(fn p -> if section, do: Map.put(p, "section", section), else: p end)

    assert %AgentToolResult{content: [%TextContent{text: text}]} =
             ReadSkill.execute("reg-#{key}-#{view}", params, nil, nil, tmp_dir)

    text
  end

  defp write_skill!(tmp_dir, key, skill_md) do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    skill_dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
