defmodule LemonGames.Games.RockPaperScissorsTest do
  use ExUnit.Case, async: true

  alias LemonGames.Games.RockPaperScissors, as: RPS

  # ---------------------------------------------------------------------------
  # game_type/0
  # ---------------------------------------------------------------------------

  test "game_type returns rock_paper_scissors" do
    assert RPS.game_type() == "rock_paper_scissors"
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  test "init returns empty state with no throws and unresolved" do
    state = RPS.init(%{})
    assert state == %{"throws" => %{}, "resolved" => false, "winner" => nil}
  end

  # ---------------------------------------------------------------------------
  # legal_moves/2
  # ---------------------------------------------------------------------------

  test "legal_moves returns all three throws when slot has not thrown" do
    state = RPS.init(%{})
    moves = RPS.legal_moves(state, "p1")
    assert length(moves) == 3
    assert %{"kind" => "throw", "value" => "rock"} in moves
    assert %{"kind" => "throw", "value" => "paper"} in moves
    assert %{"kind" => "throw", "value" => "scissors"} in moves
  end

  test "legal_moves returns empty list after slot has already thrown" do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "rock"})
    assert RPS.legal_moves(state, "p1") == []
  end

  test "legal_moves still returns moves for other slot after one slot throws" do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "rock"})
    moves = RPS.legal_moves(state, "p2")
    assert length(moves) == 3
  end

  # ---------------------------------------------------------------------------
  # apply_move/3 – error cases
  # ---------------------------------------------------------------------------

  test "apply_move rejects invalid throw value" do
    state = RPS.init(%{})

    assert {:error, :illegal_move, _msg} =
             RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "lizard"})
  end

  test "apply_move rejects already-thrown slot" do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "rock"})

    assert {:error, :illegal_move, _msg} =
             RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "paper"})
  end

  test "apply_move rejects invalid move format" do
    state = RPS.init(%{})
    assert {:error, :illegal_move, _msg} = RPS.apply_move(state, "p1", %{"kind" => "unknown"})
  end

  test "apply_move rejects move map missing kind key" do
    state = RPS.init(%{})
    assert {:error, :illegal_move, _msg} = RPS.apply_move(state, "p1", %{"value" => "rock"})
  end

  # ---------------------------------------------------------------------------
  # All 9 throw outcomes
  # ---------------------------------------------------------------------------

  defp play(p1_throw, p2_throw) do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => p1_throw})
    {:ok, state} = RPS.apply_move(state, "p2", %{"kind" => "throw", "value" => p2_throw})
    state
  end

  test "rock vs rock is a draw" do
    state = play("rock", "rock")
    assert RPS.winner(state) == "draw"
    assert RPS.terminal_reason(state) == "draw"
  end

  test "paper vs paper is a draw" do
    state = play("paper", "paper")
    assert RPS.winner(state) == "draw"
    assert RPS.terminal_reason(state) == "draw"
  end

  test "scissors vs scissors is a draw" do
    state = play("scissors", "scissors")
    assert RPS.winner(state) == "draw"
    assert RPS.terminal_reason(state) == "draw"
  end

  test "rock vs scissors p1 wins" do
    state = play("rock", "scissors")
    assert RPS.winner(state) == "p1"
    assert RPS.terminal_reason(state) == "winner"
  end

  test "paper vs rock p1 wins" do
    state = play("paper", "rock")
    assert RPS.winner(state) == "p1"
    assert RPS.terminal_reason(state) == "winner"
  end

  test "scissors vs paper p1 wins" do
    state = play("scissors", "paper")
    assert RPS.winner(state) == "p1"
    assert RPS.terminal_reason(state) == "winner"
  end

  test "scissors vs rock p2 wins" do
    state = play("scissors", "rock")
    assert RPS.winner(state) == "p2"
    assert RPS.terminal_reason(state) == "winner"
  end

  test "rock vs paper p2 wins" do
    state = play("rock", "paper")
    assert RPS.winner(state) == "p2"
    assert RPS.terminal_reason(state) == "winner"
  end

  test "paper vs scissors p2 wins" do
    state = play("paper", "scissors")
    assert RPS.winner(state) == "p2"
    assert RPS.terminal_reason(state) == "winner"
  end

  # ---------------------------------------------------------------------------
  # winner/1 and terminal_reason/1 on fresh state
  # ---------------------------------------------------------------------------

  test "winner returns nil on initial state" do
    state = RPS.init(%{})
    assert RPS.winner(state) == nil
  end

  test "terminal_reason returns nil on initial state" do
    state = RPS.init(%{})
    assert RPS.terminal_reason(state) == nil
  end

  test "terminal_reason returns nil after only one throw" do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "rock"})
    assert RPS.terminal_reason(state) == nil
  end

  # ---------------------------------------------------------------------------
  # public_state/2
  # ---------------------------------------------------------------------------

  test "public_state hides throws before resolution" do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "rock"})
    pub = RPS.public_state(state, "p2")
    assert pub["throws"] == %{}
    assert pub["resolved"] == false
    assert pub["winner"] == nil
  end

  test "public_state reveals full state after resolution" do
    state = play("rock", "scissors")
    pub = RPS.public_state(state, "p1")
    assert pub["resolved"] == true
    assert pub["throws"] == %{"p1" => "rock", "p2" => "scissors"}
    assert pub["winner"] == "p1"
  end

  test "public_state on unresolved state is identical for both viewers" do
    state = RPS.init(%{})
    {:ok, state} = RPS.apply_move(state, "p1", %{"kind" => "throw", "value" => "paper"})
    assert RPS.public_state(state, "p1") == RPS.public_state(state, "p2")
  end
end
