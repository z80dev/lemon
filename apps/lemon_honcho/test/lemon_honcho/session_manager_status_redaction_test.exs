defmodule LemonHoncho.SessionManagerStatusRedactionTest do
  use ExUnit.Case, async: true

  @secret "PRIVATE-prompt-and-answer-text"

  for {module, kept} <- [
        {LemonHoncho.SessionManager, [max_sessions: 10]}
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

      assert {%LemonCore.StatusRedaction.RedactedCrash{}, [{__MODULE__, :run, 1, _}]} =
               formatted.reason
    end
  end
end
