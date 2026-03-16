defmodule LemonSkills.Synthesis.CandidateSelectorTest do
  use ExUnit.Case, async: true

  alias LemonCore.MemoryDocument
  alias LemonSkills.Synthesis.CandidateSelector

  @prompt String.duplicate("implement a k8s deployment script ", 3)  # > 50 chars
  @answer String.duplicate("use kubectl apply with the deployment manifest ", 4)  # > 100 chars

  defp doc(overrides \\ []) do
    %MemoryDocument{
      doc_id: "doc-#{System.unique_integer([:positive])}",
      run_id: "run-1",
      session_key: "s1",
      agent_id: "agent-1",
      workspace_key: nil,
      scope: :agent,
      started_at_ms: System.system_time(:millisecond),
      ingested_at_ms: System.system_time(:millisecond),
      prompt_summary: Keyword.get(overrides, :prompt, @prompt),
      answer_summary: Keyword.get(overrides, :answer, @answer),
      tools_used: Keyword.get(overrides, :tools, ["bash"]),
      provider: "anthropic",
      model: "claude-sonnet",
      outcome: Keyword.get(overrides, :outcome, :success),
      meta: %{}
    }
  end

  describe "select/1 quality filters" do
    test "includes :success documents" do
      docs = [doc(outcome: :success)]
      assert [_] = CandidateSelector.select(docs)
    end

    test "includes :partial documents" do
      docs = [doc(outcome: :partial)]
      assert [_] = CandidateSelector.select(docs)
    end

    test "excludes :failure documents" do
      assert [] = CandidateSelector.select([doc(outcome: :failure)])
    end

    test "excludes :aborted documents" do
      assert [] = CandidateSelector.select([doc(outcome: :aborted)])
    end

    test "excludes :unknown documents" do
      assert [] = CandidateSelector.select([doc(outcome: :unknown)])
    end

    test "excludes docs with short prompt_summary" do
      short = "deploy"
      assert [] = CandidateSelector.select([doc(prompt: short)])
    end

    test "excludes docs with short answer_summary" do
      short = "done"
      assert [] = CandidateSelector.select([doc(answer: short)])
    end

    test "excludes docs with nil prompt_summary" do
      assert [] = CandidateSelector.select([doc(prompt: nil)])
    end

    test "excludes docs with nil answer_summary" do
      assert [] = CandidateSelector.select([doc(answer: nil)])
    end
  end

  describe "select/1 secret filtering" do
    test "excludes docs with password= pattern" do
      secret_prompt = @prompt <> " password=hunter2"
      assert [] = CandidateSelector.select([doc(prompt: secret_prompt)])
    end

    test "excludes docs with API key pattern (sk-...)" do
      secret_answer = @answer <> " sk-abcdefghijklmnopqrstuvwxyz1234567890"
      assert [] = CandidateSelector.select([doc(answer: secret_answer)])
    end

    test "excludes docs with PRIVATE KEY header" do
      secret = @answer <> " -----BEGIN RSA PRIVATE KEY-----"
      assert [] = CandidateSelector.select([doc(answer: secret)])
    end

    test "includes clean docs without secrets" do
      assert [_] = CandidateSelector.select([doc()])
    end
  end

  describe "select/1 task family filtering" do
    test "excludes :chat family documents" do
      chat_prompt = String.duplicate("yes okay thanks hello ", 5)
      assert [] = CandidateSelector.select([doc(prompt: chat_prompt)])
    end

    test "includes :code family documents" do
      code_prompt = String.duplicate("implement a deployment script for kubernetes ", 3)
      assert [_] = CandidateSelector.select([doc(prompt: code_prompt)])
    end

    test "includes :query family documents" do
      query_prompt = String.duplicate("explain how kubernetes deployments work in detail ", 3)
      assert [_] = CandidateSelector.select([doc(prompt: query_prompt)])
    end
  end

  describe "select/1 deduplication" do
    test "deduplicates by normalized prompt_summary" do
      d1 = doc(prompt: @prompt)
      d2 = doc(prompt: @prompt)  # same prompt
      result = CandidateSelector.select([d1, d2])
      assert length(result) == 1
    end

    test "keeps first (most-recent) on duplicate" do
      d1 = doc(prompt: @prompt)
      d2 = %{doc(prompt: @prompt) | doc_id: "different-id"}
      [kept] = CandidateSelector.select([d1, d2])
      assert kept.doc_id == d1.doc_id
    end

    test "preserves distinct documents" do
      d1 = doc(prompt: String.duplicate("implement a kubernetes deployment ", 3))
      d2 = doc(prompt: String.duplicate("explain how git rebasing works in detail ", 3))
      assert length(CandidateSelector.select([d1, d2])) == 2
    end
  end

  test "empty list returns empty list" do
    assert [] = CandidateSelector.select([])
  end
end
