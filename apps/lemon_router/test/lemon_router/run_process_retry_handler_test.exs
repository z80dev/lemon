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

  test "formats executor exits without exposing internal terms" do
    for reason <- [:normal, :killed, :shutdown, :crashed] do
      assert RetryHandler.format_run_error(%{type: :executor_down, reason: reason}) ==
               "executor exited: #{reason}"
    end
  end
end
