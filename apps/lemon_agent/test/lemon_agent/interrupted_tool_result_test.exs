defmodule LemonAgent.InterruptedToolResultTest do
  use ExUnit.Case, async: true

  alias LemonAgent.InterruptedToolResult
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  for reason <- [:aborted, :timeout, :crashed, :interrupted] do
    test "#{reason} after dispatch is unknown and forbids automatic repetition" do
      result = InterruptedToolResult.build(unquote(reason))
      assert result.is_error
      assert result.details.outcome == :unknown
      assert result.details.reason == unquote(reason)
      assert [%TextContent{text: text}] = result.content
      assert text =~ "Do not assume it did not run or automatically repeat it."
    end
  end

  for reason <- [:aborted, :skipped] do
    test "#{reason} before dispatch is certainly not started" do
      result = InterruptedToolResult.build(unquote(reason), started: false)
      assert result.details.outcome == :not_started
      assert result.details.reason == unquote(reason)
      assert [%TextContent{text: text}] = result.content
      assert text =~ "not started"
      refute text =~ "Outcome is unknown"
    end
  end

  test "partial output and trust survive without attesting to a final outcome" do
    partial = %AgentToolResult{
      content: [%TextContent{text: "observed output"}],
      details: %{bytes: 15},
      trust: :untrusted
    }

    result = InterruptedToolResult.build(:aborted, partial: partial)
    assert [%TextContent{text: "observed output"}, %TextContent{}] = result.content
    assert result.trust == :untrusted
    assert result.details.partial_details == %{bytes: 15}
    assert result.details.outcome == :unknown
    assert result.details.reason == :aborted
  end
end
