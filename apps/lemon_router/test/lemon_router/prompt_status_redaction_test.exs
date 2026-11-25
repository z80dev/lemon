defmodule LemonRouter.PromptStatusRedactionTest do
  use ExUnit.Case, async: true

  @secret "PRIVATE-prompt-and-answer-text"

  for {module, kept} <- [
        {LemonRouter.StreamCoalescer, [run_id: "run_1", session_key: "sk_1", last_seq: 4]},
        {LemonRouter.SessionCoordinator, []},
        {LemonRouter.RestartCarryover, []}
      ] do
    @module module
    @kept kept

    test "#{inspect(module)} format_status keeps ids and drops conversation content" do
      state =
        Map.new(@kept)
        |> Map.merge(%{
          prompt: @secret,
          messages: [%{role: :user, content: @secret}],
          accumulated_text: @secret,
          full_text: @secret,
          execution_request: %{prompt: @secret},
          jobs: %{"j" => %{prompt: @secret}},
          sessions: %{"s" => @secret}
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

  test "LemonRouter.RunProcess (gen_statem) format_status keeps phase and ids only" do
    status = %{
      state: :running,
      data: %{run_id: "run_1", session_key: "sk_1", execution_request: %{prompt: @secret}},
      reason: {:bad_answer, @secret},
      queue: [{:info, {:delta, @secret}}],
      postponed: [{:info, @secret}],
      timeouts: [{:t, @secret}],
      log: [{:in, @secret}]
    }

    formatted = LemonRouter.RunProcess.format_status(status)

    refute inspect(formatted, limit: :infinity, printable_limit: :infinity) =~ @secret
    assert formatted.state == :running
    assert formatted.data == %{run_id: "run_1", session_key: "sk_1"}
    assert formatted.reason == {:bad_answer, :redacted}
    assert formatted.queue == []
  end
end
