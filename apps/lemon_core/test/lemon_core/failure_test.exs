defmodule LemonCore.FailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LemonCore.Failure

  test "logs a rescued exception with its stacktrace at warning by default" do
    log =
      capture_log(fn ->
        try do
          raise ArgumentError, "bad input"
        rescue
          exception -> Failure.log("widget assembly", exception, __STACKTRACE__)
        end
      end)

    assert log =~ "[warning]"
    assert log =~ "widget assembly raised: ** (ArgumentError) bad input"
    assert log =~ "failure_test.exs"
  end

  test "the level option selects the log level" do
    log =
      capture_log(fn ->
        try do
          raise "boom"
        rescue
          exception -> Failure.log("nightly job", exception, __STACKTRACE__, level: :error)
        end
      end)

    assert log =~ "[error]"
    assert log =~ "nightly job raised: ** (RuntimeError) boom"
  end

  test "a caught exit or throw is logged with the kind it was caught as" do
    exit_log =
      capture_log(fn ->
        try do
          exit(:shutdown_now)
        catch
          kind, reason -> Failure.log_caught("store call", kind, reason, __STACKTRACE__)
        end
      end)

    assert exit_log =~ "store call exited: ** (exit) :shutdown_now"

    throw_log =
      capture_log(fn ->
        try do
          throw(:ball)
        catch
          kind, reason -> Failure.log_caught("game", kind, reason, __STACKTRACE__)
        end
      end)

    assert throw_log =~ "game threw: ** (throw) :ball"
  end

  test "log returns :ok so it can end a rescue clause" do
    capture_log(fn ->
      assert :ok = Failure.log("noop", %RuntimeError{message: "x"}, [])
    end)
  end
end
