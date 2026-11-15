defmodule LemonControlPlane.PromptCacheContextTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.ACP.ContextReport
  alias LemonControlPlane.Methods.SessionsContext

  test "context explains changed digests without projecting prompt data" do
    digest = String.duplicate("a", 64)
    previous = String.duplicate("b", 64)

    usage = %{
      used_tokens: 10,
      categories: [%{id: :system_prompt, tokens: 10}],
      prompt_cache: %{
        status: :digest_changed,
        digest: digest,
        previous_digest: previous,
        explanation: "private prompt text",
        prompt: "private prompt text"
      }
    }

    assert {:ok, report} = SessionsContext.project("agent:default:test", usage)
    assert report["promptCache"]["digest"] == digest
    assert report["promptCache"]["previousDigest"] == previous
    assert report["promptCache"]["explanation"] =~ "Prompt digest changed"
    assert ContextReport.markdown(report) =~ "Prompt digest changed"
    refute Jason.encode!(report) =~ "private prompt text"
  end

  test "malformed digests and arbitrary diagnoses do not leak through context" do
    usage = %{
      used_tokens: 1,
      categories: [%{id: :system_prompt, tokens: 1}],
      prompt_cache: %{status: "/private/path", digest: "/private/path"}
    }

    assert {:ok, report} = SessionsContext.project("test", usage)
    assert report["promptCache"]["digest"] == nil
    refute Jason.encode!(report) =~ "/private/path"
  end
end
