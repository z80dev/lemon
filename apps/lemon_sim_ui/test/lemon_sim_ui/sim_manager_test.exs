defmodule LemonSimUi.SimManagerTest do
  use ExUnit.Case, async: true

  alias LemonSimUi.SimManager

  test "parse_model_spec resolves hyphenated provider names" do
    assert SimManager.parse_model_spec("openai-codex:gpt-5.3-codex-spark") ==
             {:"openai-codex", "gpt-5.3-codex-spark"}
  end

  test "parse_model_spec resolves aliased provider names" do
    assert SimManager.parse_model_spec("openai_codex:gpt-5.3-codex-spark") ==
             {:"openai-codex", "gpt-5.3-codex-spark"}
  end

  test "parse_model_spec resolves world-snapshot provider/model strings" do
    # attach_model_assignments stores "provider/model_id"; resume reads it back.
    assert SimManager.parse_model_spec("kimi/k2p5") == {:kimi, "k2p5"}

    assert SimManager.parse_model_spec("openai-codex/gpt-5.3-codex-spark") ==
             {:"openai-codex", "gpt-5.3-codex-spark"}
  end

  test "parse_model_spec treats unknown-prefix slashes as a bare model id" do
    assert SimManager.parse_model_spec("not-a-provider/some-model") ==
             {:anthropic, "not-a-provider/some-model"}
  end

  test "parse_model_spec defaults bare ids to anthropic" do
    assert SimManager.parse_model_spec("claude-haiku-4-5") ==
             {:anthropic, "claude-haiku-4-5"}
  end
end
