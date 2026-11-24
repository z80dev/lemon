defmodule CodingAgent.PromptStatusRedactionTest do
  use ExUnit.Case, async: true

  @secret "PRIVATE-prompt-and-answer-text"

  for {module, kept} <- [
        {CodingAgent.Session, [run_id: "run_1", session_key: "sk_1", turn_index: 3]},
        {CodingAgent.Executor.SessionRunner, [run_id: "run_1", session_key: "sk_1"]},
        {CodingAgent.Executor.RemoteSessionRunner, [run_id: "run_1", session_key: "sk_1"]},
        {CodingAgent.Advisor, [emitted: 2, ready: true]},
        {CodingAgent.AsyncFollowups, [window_ms: 50]},
        {CodingAgent.BackgroundRun.Worker, [id: "bg_1", session_id: "s_1"]}
      ] do
    @module module
    @kept kept

    test "#{inspect(module)} format_status keeps ids and drops conversation content" do
      state =
        Map.new(@kept)
        |> Map.merge(%{
          prompt: @secret,
          system_prompt: @secret,
          messages: [%{role: :user, content: @secret}],
          accumulated_text: @secret,
          request: %{prompt: @secret},
          batches: %{"k" => @secret},
          events: [{:message_end, @secret}]
        })

      status = %{
        state: state,
        message: {:prompt, @secret},
        reason: {%RuntimeError{message: @secret}, [{__MODULE__, :run, [@secret], [line: 1]}]},
        log: [{:in, @secret}]
      }

      formatted = @module.format_status(status)

      refute inspect(formatted, limit: :infinity, printable_limit: :infinity) =~ @secret
      assert formatted.state == Map.new(@kept)
      assert formatted.message == :redacted
      assert formatted.log == []

      assert {%LemonCore.StatusRedaction.RedactedCrashError{}, [{__MODULE__, :run, 1, _}]} =
               formatted.reason
    end
  end
end
