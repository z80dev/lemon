defmodule LemonRouter.RunProcess.RetryHandlerTest do
  use ExUnit.Case, async: true

  alias LemonRouter.RunProcess.RetryHandler

  test "tuple failures have actionable copy without Elixir terms" do
    for error <- [
          {:assistant_error, %{detail: :private}},
          {:unknown_failure, %{detail: :private}}
        ] do
      message = RetryHandler.format_run_error(error)
      assert message =~ "The model returned an error."
      assert message =~ "lemon doctor"
      refute message =~ "{"
      refute message =~ ":private"
    end
  end

  test "formats gateway exception failures without stack traces" do
    stack = [{CodingAgent.Session.ModelResolver, :resolve_session_model, 2, [line: 29]}]

    error =
      {:gateway_run_down,
       {%ArgumentError{message: "unknown model \"definitely-missing-model\""}, stack}}

    assert RetryHandler.format_run_error(error) == "unknown model \"definitely-missing-model\""
    refute RetryHandler.format_run_error(error) =~ "CodingAgent.Session.ModelResolver"
  end
end
