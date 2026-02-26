defmodule LemonRouter.StickyEngineTest do
  use ExUnit.Case, async: true

  alias LemonRouter.StickyEngine

  describe "extract_from_prompt/1" do
    test "returns :none for nil prompt" do
      assert :none = StickyEngine.extract_from_prompt(nil)
    end

    test "returns :none for empty prompt" do
      assert :none = StickyEngine.extract_from_prompt("")
    end

    test "returns :none for non-string input" do
      assert :none = StickyEngine.extract_from_prompt(42)
    end

    test "detects 'use <engine>' pattern" do
      assert {:ok, "codex"} = StickyEngine.extract_from_prompt("use codex")
    end

    test "detects 'switch to <engine>' pattern" do
      assert {:ok, "claude"} = StickyEngine.extract_from_prompt("switch to claude")
    end

    test "detects 'with <engine>' pattern" do
      assert {:ok, "echo"} = StickyEngine.extract_from_prompt("with echo")
    end

    test "is case-insensitive" do
      assert {:ok, "codex"} = StickyEngine.extract_from_prompt("Use Codex")
      assert {:ok, "claude"} = StickyEngine.extract_from_prompt("SWITCH TO Claude")
      assert {:ok, "echo"} = StickyEngine.extract_from_prompt("WITH Echo")
    end

    test "allows leading whitespace" do
      assert {:ok, "codex"} = StickyEngine.extract_from_prompt("  use codex")
    end

    test "works with trailing text after engine name" do
      assert {:ok, "codex"} = StickyEngine.extract_from_prompt("use codex for this task")
    end

    test "returns :none for unknown engine" do
      assert :none = StickyEngine.extract_from_prompt("use unknown_engine_xyz")
    end

    test "returns :none when pattern is not at start" do
      assert :none = StickyEngine.extract_from_prompt("please use codex for this")
    end

    test "returns :none for ordinary prompts" do
      assert :none = StickyEngine.extract_from_prompt("Tell me about the weather")
      assert :none = StickyEngine.extract_from_prompt("How do I use git?")
    end
  end

  describe "resolve/1" do
    test "explicit engine_id takes priority and becomes sticky" do
      {engine, updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: "codex",
          prompt: "use claude",
          session_preferred_engine: "echo"
        })

      assert engine == "codex"
      assert updates == %{preferred_engine: "codex"}
    end

    test "prompt-detected engine overrides session preference" do
      {engine, updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: nil,
          prompt: "use codex then help me",
          session_preferred_engine: "echo"
        })

      assert engine == "codex"
      assert updates == %{preferred_engine: "codex"}
    end

    test "falls back to session preferred engine when no override" do
      {engine, updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: nil,
          prompt: "just a normal prompt",
          session_preferred_engine: "claude"
        })

      assert engine == "claude"
      assert updates == %{}
    end

    test "returns nil engine when no preference exists" do
      {engine, updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: nil,
          prompt: "just a normal prompt",
          session_preferred_engine: nil
        })

      assert engine == nil
      assert updates == %{}
    end

    test "ignores empty string explicit engine" do
      {engine, _updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: "",
          prompt: "use codex",
          session_preferred_engine: nil
        })

      assert engine == "codex"
    end

    test "ignores empty string session preference" do
      {engine, updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: nil,
          prompt: "normal prompt",
          session_preferred_engine: ""
        })

      assert engine == nil
      assert updates == %{}
    end
  end
end
