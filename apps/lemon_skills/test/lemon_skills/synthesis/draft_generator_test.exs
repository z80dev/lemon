defmodule LemonSkills.Synthesis.DraftGeneratorTest do
  use ExUnit.Case, async: true

  alias LemonCore.MemoryDocument
  alias LemonSkills.Synthesis.DraftGenerator

  defp doc(overrides \\ []) do
    %MemoryDocument{
      doc_id: "doc-gen-1",
      run_id: "run-1",
      session_key: "s1",
      agent_id: "agent-1",
      workspace_key: nil,
      scope: :agent,
      started_at_ms: 1_736_942_400_000,
      ingested_at_ms: 1_736_942_460_000,
      prompt_summary:
        Keyword.get(
          overrides,
          :prompt,
          "Implement a Kubernetes deployment script for the app"
        ),
      answer_summary:
        Keyword.get(
          overrides,
          :answer,
          "Use kubectl apply with a deployment YAML that sets replicas and resource limits"
        ),
      tools_used: Keyword.get(overrides, :tools, ["bash", "read_file"]),
      provider: "anthropic",
      model: "claude-sonnet",
      outcome: :success,
      meta: %{}
    }
  end

  describe "generate/1" do
    test "returns ok tuple with draft map" do
      assert {:ok, draft} = DraftGenerator.generate(doc())
      assert is_binary(draft.key)
      assert is_binary(draft.name)
      assert is_binary(draft.content)
      assert draft.source_doc_id == "doc-gen-1"
    end

    test "key is URL-safe slug starting with synth-" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert String.starts_with?(draft.key, "synth-")
      refute draft.key =~ ~r/[^a-z0-9-]/
    end

    test "content includes YAML frontmatter delimiters" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert draft.content =~ "---"
    end

    test "content includes name field in frontmatter" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert draft.content =~ ~r/name:\s+"/
    end

    test "content includes description field in frontmatter" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert draft.content =~ ~r/description:\s+"/
    end

    test "content includes requires_tools when tools are present" do
      {:ok, draft} = DraftGenerator.generate(doc(tools: ["bash", "read_file"]))
      assert draft.content =~ "requires_tools"
      assert draft.content =~ "bash"
      assert draft.content =~ "read_file"
    end

    test "content omits requires_tools when tools list is empty" do
      {:ok, draft} = DraftGenerator.generate(doc(tools: []))
      refute draft.content =~ "requires_tools"
    end

    test "content includes synthesized: true metadata" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert draft.content =~ "synthesized: true"
    end

    test "content body includes prompt summary" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert draft.content =~ "Kubernetes deployment"
    end

    test "content body includes answer summary" do
      {:ok, draft} = DraftGenerator.generate(doc())
      assert draft.content =~ "kubectl apply"
    end

    test "content body includes a date or fallback" do
      {:ok, draft} = DraftGenerator.generate(doc())
      # Either a formatted date or the "an earlier run" fallback
      assert draft.content =~ ~r/\d{4}-\d{2}-\d{2}|an earlier run/
    end

    test "category is engineering for code prompts" do
      {:ok, draft} = DraftGenerator.generate(doc(prompt: "Implement a deployment script"))
      assert draft.content =~ "engineering"
    end
  end

  describe "derive_key_hint/1" do
    test "returns a slug from the first 3 words" do
      hint = DraftGenerator.derive_key_hint("implement kubernetes deployment")
      assert hint == "implement-kubernetes-deployment"
    end

    test "handles nil" do
      assert DraftGenerator.derive_key_hint(nil) == "unknown"
    end

    test "handles empty string" do
      assert DraftGenerator.derive_key_hint("") == "unknown"
    end

    test "strips non-alphanumeric characters" do
      hint = DraftGenerator.derive_key_hint("deploy to K8s! now")
      assert hint =~ ~r/^[a-z0-9-]+$/
    end
  end
end
