defmodule LemonSim.Examples.SpaceStation.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  # -- Action phase events --

  @spec repair_system(String.t(), String.t()) :: Event.t()
  def repair_system(player_id, system_id) do
    Event.new("repair_system", %{
      "player_id" => player_id,
      "system_id" => system_id
    })
  end

  @spec sabotage_system(String.t(), String.t()) :: Event.t()
  def sabotage_system(player_id, system_id) do
    Event.new("sabotage_system", %{
      "player_id" => player_id,
      "system_id" => system_id
    })
  end

  @spec fake_repair(String.t(), String.t()) :: Event.t()
  def fake_repair(player_id, system_id) do
    Event.new("fake_repair", %{
      "player_id" => player_id,
      "system_id" => system_id
    })
  end

  @spec scan_player(String.t(), String.t()) :: Event.t()
  def scan_player(engineer_id, target_id) do
    Event.new("scan_player", %{
      "player_id" => engineer_id,
      "target_id" => target_id
    })
  end

  @spec lock_room(String.t(), String.t()) :: Event.t()
  def lock_room(captain_id, system_id) do
    Event.new("lock_room", %{
      "player_id" => captain_id,
      "system_id" => system_id
    })
  end

  @spec call_emergency_meeting(String.t()) :: Event.t()
  def call_emergency_meeting(captain_id) do
    Event.new("call_emergency_meeting", %{
      "player_id" => captain_id
    })
  end

  @spec vent(String.t()) :: Event.t()
  def vent(saboteur_id) do
    Event.new("vent", %{
      "player_id" => saboteur_id
    })
  end

  # -- Discussion & voting events --

  @spec make_statement(String.t(), String.t()) :: Event.t()
  def make_statement(player_id, statement) do
    Event.new("make_statement", %{
      "player_id" => player_id,
      "statement" => statement
    })
  end

  @spec ask_question(String.t(), String.t(), String.t()) :: Event.t()
  def ask_question(player_id, target_id, question) do
    Event.new("ask_question", %{
      "player_id" => player_id,
      "target_id" => target_id,
      "question" => question
    })
  end

  @spec accuse(String.t(), String.t(), String.t()) :: Event.t()
  def accuse(player_id, target_id, evidence) do
    Event.new("accuse", %{
      "player_id" => player_id,
      "target_id" => target_id,
      "evidence" => evidence
    })
  end

  @spec cast_vote(String.t(), String.t()) :: Event.t()
  def cast_vote(voter_id, target_id) do
    Event.new("cast_vote", %{
      "player_id" => voter_id,
      "target_id" => target_id
    })
  end

  # -- Resolution events --

  @spec environmental_event(String.t(), integer(), String.t()) :: Event.t()
  def environmental_event(system_id, damage, description) do
    Event.new("environmental_event", %{
      "system_id" => system_id,
      "damage" => damage,
      "description" => description
    })
  end

  @spec round_resolved(map(), non_neg_integer()) :: Event.t()
  def round_resolved(system_changes, round) do
    Event.new("round_resolved", %{
      "system_changes" => system_changes,
      "round" => round,
      "message" => "Round #{round} actions resolved. System health updated."
    })
  end

  @spec scan_result(String.t(), String.t(), String.t()) :: Event.t()
  def scan_result(engineer_id, target_id, result) do
    Event.new("scan_result", %{
      "engineer_id" => engineer_id,
      "target_id" => target_id,
      "result" => result
    })
  end

  @spec player_ejected(String.t(), String.t()) :: Event.t()
  def player_ejected(player_id, role) do
    Event.new("player_ejected", %{
      "player_id" => player_id,
      "role" => role,
      "message" => "#{player_id} has been ejected from the station. They were a #{role}."
    })
  end

  @spec phase_changed(String.t(), non_neg_integer()) :: Event.t()
  def phase_changed(new_phase, round) do
    Event.new("phase_changed", %{
      "phase" => new_phase,
      "round" => round,
      "message" =>
        case new_phase do
          "action" -> "Round #{round} begins. Choose your actions at the station systems."
          "report" -> "Actions complete. Reviewing system status..."
          "discussion" -> "Time to discuss. Share observations and suspicions."
          "voting" -> "Discussion over. Vote to eject a suspect, or skip."
          _ -> "Phase changed to #{new_phase}."
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

  @spec vote_result(String.t() | nil, map()) :: Event.t()
  def vote_result(ejected_id, vote_tally) do
    Event.new("vote_result", %{
      "ejected_id" => ejected_id,
      "vote_tally" => vote_tally,
      "message" =>
        if ejected_id do
          "The crew has voted to eject #{ejected_id}."
        else
          "No majority reached. No one is ejected."
        end
    })
  end

  @spec clue_found(String.t(), map()) :: Event.t()
  def clue_found(player_id, clue) do
    Event.new("clue_found", %{
      "player_id" => player_id,
      "clue" => clue
    })
  end

  @spec crisis_triggered(map()) :: Event.t()
  def crisis_triggered(crisis) do
    Event.new("crisis_triggered", %{
      "crisis" => crisis,
      "message" => Map.get(crisis, :announcement, "A crisis has struck the station!")
    })
  end
end
