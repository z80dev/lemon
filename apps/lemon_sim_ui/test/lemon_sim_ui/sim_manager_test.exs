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
end
