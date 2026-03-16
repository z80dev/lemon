defmodule LemonCore.RunOutcomeTest do
  use ExUnit.Case, async: true

  alias LemonCore.RunOutcome

  describe "valid_outcomes/0" do
    test "returns the five outcome atoms" do
      outcomes = RunOutcome.valid_outcomes()
      assert :success in outcomes
      assert :partial in outcomes
      assert :failure in outcomes
      assert :aborted in outcomes
      assert :unknown in outcomes
    end
  end

  describe "valid?/1" do
    test "returns true for all valid outcome atoms" do
      for outcome <- RunOutcome.valid_outcomes() do
        assert RunOutcome.valid?(outcome)
      end
    end

    test "returns false for unknown atoms" do
      refute RunOutcome.valid?(:ok)
      refute RunOutcome.valid?(:error)
      refute RunOutcome.valid?(nil)
    end
  end

  describe "cast/1" do
    test "accepts valid outcome atoms" do
      assert RunOutcome.cast(:success) == {:ok, :success}
      assert RunOutcome.cast(:partial) == {:ok, :partial}
      assert RunOutcome.cast(:failure) == {:ok, :failure}
      assert RunOutcome.cast(:aborted) == {:ok, :aborted}
      assert RunOutcome.cast(:unknown) == {:ok, :unknown}
    end

    test "accepts valid outcome strings" do
      assert RunOutcome.cast("success") == {:ok, :success}
      assert RunOutcome.cast("aborted") == {:ok, :aborted}
    end

    test "returns :error for invalid values" do
      assert RunOutcome.cast(:nope) == :error
      assert RunOutcome.cast("nope") == :error
      assert RunOutcome.cast(nil) == :error
      assert RunOutcome.cast(42) == :error
    end
  end

  describe "infer/1 — explicit override" do
    test "returns the explicit outcome when present and valid" do
      for outcome <- RunOutcome.valid_outcomes() do
        assert RunOutcome.infer(%{outcome: outcome}) == outcome
      end
    end

    test "ignores invalid explicit outcome and falls through to heuristics" do
      # :nope is not valid, should fall through to :unknown (no ok key)
      assert RunOutcome.infer(%{outcome: :nope}) == :unknown
    end
  end

  describe "infer/1 — completed sub-map heuristics" do
    test "success: ok true with non-empty answer" do
      summary = %{completed: %{ok: true, answer: "Done."}}
      assert RunOutcome.infer(summary) == :success
    end

    test "partial: ok true with blank answer" do
      assert RunOutcome.infer(%{completed: %{ok: true, answer: ""}}) == :partial
      assert RunOutcome.infer(%{completed: %{ok: true, answer: "   "}}) == :partial
    end

    test "partial: ok true with nil answer" do
      assert RunOutcome.infer(%{completed: %{ok: true, answer: nil}}) == :partial
    end

    test "partial: ok true with no answer key" do
      assert RunOutcome.infer(%{completed: %{ok: true}}) == :partial
    end

    test "aborted: ok false with abort error marker" do
      for marker <- ["abort", "user_requested", "cancelled", "watchdog", "idle_timeout", "keepalive_cancelled"] do
        summary = %{completed: %{ok: false, error: marker}}
        assert RunOutcome.infer(summary) == :aborted, "expected :aborted for error marker #{marker}"
      end
    end

    test "aborted: case-insensitive error matching" do
      assert RunOutcome.infer(%{completed: %{ok: false, error: "USER_REQUESTED"}}) == :aborted
      assert RunOutcome.infer(%{completed: %{ok: false, error: "Watchdog"}}) == :aborted
    end

    test "aborted: atom error" do
      assert RunOutcome.infer(%{completed: %{ok: false, error: :watchdog}}) == :aborted
      assert RunOutcome.infer(%{completed: %{ok: false, error: :cancelled}}) == :aborted
    end

    test "failure: ok false with non-abort error" do
      assert RunOutcome.infer(%{completed: %{ok: false, error: "timeout"}}) == :failure
      assert RunOutcome.infer(%{completed: %{ok: false, error: "network error"}}) == :failure
    end

    test "failure: ok false with nil error" do
      assert RunOutcome.infer(%{completed: %{ok: false, error: nil}}) == :failure
    end

    test "unknown: no ok key in completed" do
      assert RunOutcome.infer(%{completed: %{answer: "hi"}}) == :unknown
    end
  end

  describe "infer/1 — flat summary heuristics (no completed sub-map)" do
    test "success: top-level ok true with answer" do
      assert RunOutcome.infer(%{ok: true, answer: "Done."}) == :success
    end

    test "partial: top-level ok true with empty answer" do
      assert RunOutcome.infer(%{ok: true, answer: ""}) == :partial
      assert RunOutcome.infer(%{ok: true}) == :partial
    end

    test "aborted: top-level ok false with abort error" do
      assert RunOutcome.infer(%{ok: false, error: "cancelled"}) == :aborted
    end

    test "failure: top-level ok false with non-abort error" do
      assert RunOutcome.infer(%{ok: false, error: "internal_error"}) == :failure
    end

    test "unknown: no ok key at top level" do
      assert RunOutcome.infer(%{answer: "hi"}) == :unknown
    end
  end

  describe "infer/1 — string-keyed maps" do
    test "handles string-keyed completed map" do
      summary = %{"completed" => %{"ok" => true, "answer" => "Done."}}
      assert RunOutcome.infer(summary) == :success
    end

    test "handles string-keyed flat map" do
      assert RunOutcome.infer(%{"ok" => false, "error" => "cancelled"}) == :aborted
    end
  end

  describe "infer/1 — edge cases" do
    test "returns :unknown for non-map input" do
      assert RunOutcome.infer(nil) == :unknown
      assert RunOutcome.infer("string") == :unknown
      assert RunOutcome.infer(42) == :unknown
    end

    test "returns :unknown for empty map" do
      assert RunOutcome.infer(%{}) == :unknown
    end

    test "explicit outcome takes precedence over heuristics" do
      # Even though completed says success, explicit :aborted wins
      summary = %{outcome: :aborted, completed: %{ok: true, answer: "Done."}}
      assert RunOutcome.infer(summary) == :aborted
    end
  end
end
