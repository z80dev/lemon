defmodule CodingAgent.Tools.Task.FastPathTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.FastPath

  describe "use_direct_provider?/1" do
    test "uses direct provider for codex pure text tasks" do
      assert FastPath.use_direct_provider?(%{
               engine: "codex",
               description: "Write a riddle",
               prompt: "Write one short original riddle."
             })
    end

    test "uses direct provider for claude pure text tasks" do
      assert FastPath.use_direct_provider?(%{
               engine: "claude",
               description: "Write a joke",
               prompt: "Write one short original joke."
             })
    end

    test "does not use direct provider for coding-style tasks" do
      refute FastPath.use_direct_provider?(%{
               engine: "codex",
               description: "Fix failing test",
               prompt: "Open the repo, fix the failing test, and update the module."
             })
    end

    test "does not use direct provider when the prompt explicitly requires tools" do
      refute FastPath.use_direct_provider?(%{
               engine: "codex",
               description: "Check repo state",
               prompt: "Use bash/read/grep tools only. Return whether outbox.ex exists."
             })
    end

    test "does not use direct provider when model override is explicit" do
      refute FastPath.use_direct_provider?(%{
               engine: "codex",
               description: "Write a riddle",
               prompt: "Write one short original riddle.",
               model: "totally-unknown-model"
             })
    end

    test "does not use direct provider for repo inspection tasks that omit explicit tool names" do
      refute FastPath.use_direct_provider?(%{
               engine: "codex",
               description: "Count apps",
               prompt:
                 "Count the apps in the repo and check whether apps/lemon_channels/lib/lemon_channels/outbox.ex exists."
             })
    end

    test "uses direct provider for supported claude model aliases" do
      assert FastPath.use_direct_provider?(%{
               engine: "claude",
               description: "Write a joke",
               prompt: "Write one short original joke.",
               model: "haiku"
             })
    end
  end

  describe "default_model_spec/1" do
    test "returns provider defaults for supported fast-path engines" do
      assert FastPath.default_model_spec("codex") == "openai-codex:gpt-5.4"
      assert FastPath.default_model_spec("claude") == "anthropic:claude-sonnet-4-20250514"
      assert FastPath.default_model_spec("kimi") == nil
    end
  end

  describe "direct_model_spec/1" do
    test "maps supported shorthand models to direct provider models" do
      assert FastPath.direct_model_spec(%{engine: "claude", model: "haiku"}) ==
               "anthropic:claude-haiku-4-5"

      assert FastPath.direct_model_spec(%{engine: "claude", model: "sonnet"}) ==
               "anthropic:claude-sonnet-4-20250514"

      assert FastPath.direct_model_spec(%{engine: "codex", model: "mini"}) ==
               "openai-codex:gpt-5-mini"
    end
  end

  describe "requires_explicit_tools?/1" do
    test "detects slash-separated tool requirements" do
      assert FastPath.requires_explicit_tools?(%{
               description: "Inspect repo",
               prompt: "Use bash/read/grep tools only and return the result."
             })
    end
  end

  describe "internal bash fast path" do
    test "uses direct internal execution for bash-only tasks with an explicit command" do
      validated = %{
        engine: nil,
        tool_policy: %{allow: ["bash"]},
        prompt:
          "Use bash tools only. Do not use any tool except bash. Run `printf alpha`, verify the bash output, and return exactly `alpha`."
      }

      assert FastPath.use_internal_bash_fast_path?(validated)
      assert FastPath.extract_internal_bash_command(validated) == "printf alpha"
    end

    test "does not use the internal bash fast path without a bash-only policy" do
      refute FastPath.use_internal_bash_fast_path?(%{
               engine: nil,
               tool_policy: nil,
               prompt:
                 "Use bash tools only. Do not use any tool except bash. Run `printf alpha`, verify the bash output, and return exactly `alpha`."
             })
    end

    test "extracts explicit commands without backticks" do
      validated = %{
        engine: nil,
        tool_policy: %{allow: ["bash"]},
        prompt: "Run this exact command and return the output: printf minimax-ok"
      }

      assert FastPath.use_internal_bash_fast_path?(validated)
      assert FastPath.extract_internal_bash_command(validated) == "printf minimax-ok"
    end
  end
end
