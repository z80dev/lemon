defmodule LemonRouter.RunProcess.RetryHandlerTest do
  use ExUnit.Case, async: true

  alias LemonRouter.RunProcess.RetryHandler

  test "formats gateway exception failures without stack traces" do
    stack = [{CodingAgent.Session.ModelResolver, :resolve_session_model, 2, [line: 29]}]

    error =
      {:gateway_run_down,
       {%ArgumentError{message: "unknown model \"definitely-missing-model\""}, stack}}

    assert RetryHandler.format_run_error(error) == "unknown model \"definitely-missing-model\""
    refute RetryHandler.format_run_error(error) =~ "CodingAgent.Session.ModelResolver"
  end
end
