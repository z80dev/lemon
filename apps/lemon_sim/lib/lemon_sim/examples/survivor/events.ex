defmodule LemonSim.Examples.Survivor.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  # -- Challenge actions --

  @spec challenge_choice(String.t(), String.t()) :: Event.t()
  def challenge_choice(player_id, strategy) do
    Event.new("challenge_choice", %{
      "player_id" => player_id,
      "strategy" => strategy
    })
  end

  @spec challenge_resolved(String.t(), map()) :: Event.t()
  def challenge_resolved(winner, results) do
    Event.new("challenge_resolved", %{
      "winner" => winner,
      "results" => results,
      "message" => "Challenge won by #{winner}!"
    })
  end

  # -- Strategy phase actions --

  @spec make_statement(String.t(), String.t()) :: Event.t()
  def make_statement(player_id, statement) do
    Event.new("make_statement", %{
      "player_id" => player_id,
      "statement" => statement
    })
  end

  @spec send_whisper(String.t(), String.t(), String.t()) :: Event.t()
  def send_whisper(from_id, to_id, message) do
    Event.new("send_whisper", %{
      "from_id" => from_id,
      "to_id" => to_id,
      "message" => message
    })
  end

  # -- Tribal council actions --

  @spec cast_vote(String.t(), String.t()) :: Event.t()
  def cast_vote(voter_id, target_id) do
    Event.new("cast_vote", %{
      "player_id" => voter_id,
      "target_id" => target_id
    })
  end

  @spec play_idol(String.t()) :: Event.t()
  def play_idol(player_id) do
    Event.new("play_idol", %{
      "player_id" => player_id,
      "message" => "#{player_id} plays a Hidden Immunity Idol!"
    })
  end

  @spec skip_idol(String.t()) :: Event.t()
  def skip_idol(player_id) do
    Event.new("skip_idol", %{
      "player_id" => player_id
    })
  end

  # -- Resolution events --

  @spec vote_result(String.t() | nil, map()) :: Event.t()
  def vote_result(eliminated_id, vote_tally) do
    Event.new("vote_result", %{
      "eliminated_id" => eliminated_id,
      "vote_tally" => vote_tally,
      "message" =>
        if eliminated_id do
          "The tribe has spoken. #{eliminated_id} is eliminated."
        else
          "No majority reached. No one is eliminated."
        end
    })
  end

  @spec player_eliminated(String.t(), String.t()) :: Event.t()
  def player_eliminated(player_id, reason) do
    Event.new("player_eliminated", %{
      "player_id" => player_id,
      "reason" => reason,
      "message" => "#{player_id} has been #{reason}."
    })
  end

  @spec tribes_merged(String.t()) :: Event.t()
  def tribes_merged(merge_tribe_name) do
    Event.new("tribes_merged", %{
      "merge_tribe_name" => merge_tribe_name,
      "message" =>
        "The tribes have merged into #{merge_tribe_name}! It's every player for themselves now."
    })
  end

  # -- Final tribal council --

  @spec jury_statement(String.t(), String.t()) :: Event.t()
  def jury_statement(jury_member_id, statement) do
    Event.new("jury_statement", %{
      "player_id" => jury_member_id,
      "statement" => statement
    })
  end

  @spec jury_vote(String.t(), String.t()) :: Event.t()
  def jury_vote(jury_member_id, target_id) do
    Event.new("jury_vote", %{
      "player_id" => jury_member_id,
      "target_id" => target_id
    })
  end

  @spec make_final_plea(String.t(), String.t()) :: Event.t()
  def make_final_plea(player_id, plea) do
    Event.new("make_final_plea", %{
      "player_id" => player_id,
      "plea" => plea
    })
  end

  # -- Phase / game events --

  @spec phase_changed(String.t(), non_neg_integer()) :: Event.t()
  def phase_changed(new_phase, episode) do
    Event.new("phase_changed", %{
      "phase" => new_phase,
      "episode" => episode,
      "message" =>
        case new_phase do
          "challenge" ->
            "Episode #{episode}: The challenge begins!"

          "strategy" ->
            "Episode #{episode}: Time to strategize before tribal council."

          "tribal_council" ->
            "Episode #{episode}: Tribal council is now in session."

          "final_tribal_council" ->
            "The Final Tribal Council begins. Jury, you will now address the finalists."

          "game_over" ->
            "The game is over."

          _ ->
            "Phase changed to #{new_phase}."
        end
    })
  end

  @spec game_over(String.t(), String.t()) :: Event.t()
  def game_over(winner, message) do
    Event.new("game_over", %{
      "status" => "game_over",
      "winner" => winner,
      "message" => message
    })
  end

  @spec action_rejected(String.t(), String.t(), String.t()) :: Event.t()
  def action_rejected(kind, player_id, reason) do
    Event.new("action_rejected", %{
      "kind" => kind,
      "player_id" => player_id,
      "reason" => reason
    })
  end
end
