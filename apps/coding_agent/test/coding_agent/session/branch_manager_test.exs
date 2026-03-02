defmodule CodingAgent.Session.BranchManagerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.BranchManager

  describe "branch_switch?/4" do
    test "returns false when current_leaf_id is nil" do
      refute BranchManager.branch_switch?([], [], nil, "target")
    end

    test "returns false when target_id is nil" do
      refute BranchManager.branch_switch?([], [], "leaf", nil)
    end

    test "returns false when target is the current leaf" do
      entry = %{id: "entry_1"}
      refute BranchManager.branch_switch?([entry], [entry], "entry_1", "entry_1")
    end

    test "returns true when target is not on current branch" do
      current = [%{id: "a"}, %{id: "b"}]
      new_branch = [%{id: "c"}, %{id: "d"}]
      assert BranchManager.branch_switch?(current, new_branch, "b", "d")
    end

    test "returns true when current leaf not on new branch (ancestor navigation)" do
      current = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      new_branch = [%{id: "a"}, %{id: "b"}]
      assert BranchManager.branch_switch?(current, new_branch, "c", "b")
    end

    test "returns false when both are on each other's paths (linear history)" do
      entries = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      refute BranchManager.branch_switch?(entries, entries, "b", "c")
    end
  end

  describe "maybe_summarize_abandoned_branch/3" do
    test "returns state unchanged when from_id is nil" do
      state = %{model: %{id: "test"}}
      assert BranchManager.maybe_summarize_abandoned_branch(state, [], nil) == state
    end

    test "returns state unchanged when fewer than 2 message entries" do
      state = %{model: %{id: "test"}}
      entries = [%{type: :message, message: %{role: :user}}]
      assert BranchManager.maybe_summarize_abandoned_branch(state, entries, "from_1") == state
    end

    test "returns state unchanged when no message entries" do
      state = %{model: %{id: "test"}}

      entries = [
        %{type: :header, message: nil},
        %{type: :compaction, message: nil}
      ]

      assert BranchManager.maybe_summarize_abandoned_branch(state, entries, "from_1") == state
    end
  end

  describe "summarize_current_branch/5" do
    test "returns error when branch has no messages" do
      session_manager = CodingAgent.SessionManager.new("/tmp/test")

      state = %{
        session_manager: session_manager,
        model: %{id: "test-model", provider: :test}
      }

      noop_broadcast = fn _state, _event -> :ok end
      noop_working = fn _state, _msg -> :ok end
      noop_notify = fn _state, _msg, _type -> :ok end

      assert {:error, :empty_branch} =
               BranchManager.summarize_current_branch(
                 state,
                 [],
                 noop_broadcast,
                 noop_working,
                 noop_notify
               )
    end
  end
end
