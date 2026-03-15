defmodule LemonSim.Examples.Werewolf.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  # -- Night actions --

  @spec choose_victim(String.t(), String.t()) :: Event.t()
  def choose_victim(werewolf_id, victim_id) do
    Event.new("choose_victim", %{
      "player_id" => werewolf_id,
      "victim_id" => victim_id
    })
  end

  @spec investigate_player(String.t(), String.t()) :: Event.t()
  def investigate_player(seer_id, target_id) do
    Event.new("investigate_player", %{
      "player_id" => seer_id,
      "target_id" => target_id
    })
  end

  @spec protect_player(String.t(), String.t()) :: Event.t()
  def protect_player(doctor_id, target_id) do
    Event.new("protect_player", %{
      "player_id" => doctor_id,
      "target_id" => target_id
    })
  end

  @spec sleep(String.t()) :: Event.t()
  def sleep(player_id) do
    Event.new("sleep", %{"player_id" => player_id})
  end

  @spec night_wander(String.t()) :: Event.t()
  def night_wander(player_id) do
    Event.new("night_wander", %{"player_id" => player_id})
  end

  @spec wanderer_result(String.t(), boolean(), String.t()) :: Event.t()
  def wanderer_result(player_id, saw_shadows, description) do
    Event.new("wanderer_result", %{
      "player_id" => player_id,
      "saw_shadows" => saw_shadows,
      "description" => description
    })
  end

  @spec evidence_found(list()) :: Event.t()
  def evidence_found(tokens) do
    Event.new("evidence_found", %{
      "tokens" => tokens,
      "message" => "The village finds evidence from last night..."
    })
  end

  # -- Meeting actions --

  @spec request_meeting(String.t(), String.t()) :: Event.t()
  def request_meeting(player_id, target_id) do
    Event.new("request_meeting", %{
      "player_id" => player_id,
      "target_id" => target_id
    })
  end

  @spec meeting_message(String.t(), String.t()) :: Event.t()
  def meeting_message(player_id, message) do
    Event.new("meeting_message", %{
      "player_id" => player_id,
      "message" => message
    })
  end

  # -- Day actions --

  @spec make_statement(String.t(), String.t()) :: Event.t()
  def make_statement(player_id, statement) do
    Event.new("make_statement", %{
      "player_id" => player_id,
      "statement" => statement
    })
  end

  @spec cast_vote(String.t(), String.t()) :: Event.t()
  def cast_vote(voter_id, target_id) do
    Event.new("cast_vote", %{
      "player_id" => voter_id,
      "target_id" => target_id
    })
  end

  @spec make_last_words(String.t(), String.t()) :: Event.t()
  def make_last_words(player_id, statement) do
    Event.new("make_last_words", %{
      "player_id" => player_id,
      "statement" => statement
    })
  end

  @spec wolf_chat(String.t(), String.t()) :: Event.t()
  def wolf_chat(player_id, message) do
    Event.new("wolf_chat", %{
      "player_id" => player_id,
      "message" => message
    })
  end

  @spec make_accusation(String.t(), String.t(), String.t()) :: Event.t()
  def make_accusation(player_id, target_id, reason) do
    Event.new("make_accusation", %{
      "player_id" => player_id,
      "target_id" => target_id,
      "reason" => reason
    })
  end

  # -- Resolution events --

  @spec night_resolved(String.t() | nil, String.t() | nil, boolean()) :: Event.t()
  def night_resolved(victim_id, protected_id, saved?) do
    Event.new("night_resolved", %{
      "victim_id" => victim_id,
      "protected_id" => protected_id,
      "saved" => saved?,
      "message" =>
        cond do
          is_nil(victim_id) -> "The night passes quietly. No one was targeted."
          saved? -> "The doctor saved #{victim_id}! No one died tonight."
          true -> "#{victim_id} was killed by the werewolves during the night!"
        end
    })
  end

  @spec investigation_result(String.t(), String.t(), String.t()) :: Event.t()
  def investigation_result(seer_id, target_id, role) do
    Event.new("investigation_result", %{
      "seer_id" => seer_id,
      "target_id" => target_id,
      "role" => role
    })
  end

  @spec player_eliminated(String.t(), String.t(), String.t()) :: Event.t()
  def player_eliminated(player_id, role, reason) do
    Event.new("player_eliminated", %{
      "player_id" => player_id,
      "role" => role,
      "reason" => reason,
      "message" => "#{player_id} (#{role}) has been #{reason}."
    })
  end

  @spec vote_result(String.t() | nil, map()) :: Event.t()
  def vote_result(eliminated_id, vote_tally) do
    Event.new("vote_result", %{
      "eliminated_id" => eliminated_id,
      "vote_tally" => vote_tally,
      "message" =>
        if eliminated_id do
          "The village has voted to eliminate #{eliminated_id}."
        else
          "No majority reached. No one is eliminated."
        end
    })
  end

  @spec phase_changed(String.t(), non_neg_integer()) :: Event.t()
  def phase_changed(new_phase, day_number) do
    Event.new("phase_changed", %{
      "phase" => new_phase,
      "day_number" => day_number,
      "message" =>
        case new_phase do
          "wolf_discussion" -> "Night #{day_number} falls. The wolves gather to plan..."
          "night" -> "Night #{day_number}. The village sleeps..."
          "meeting_selection" -> "Time to arrange private meetings before discussion."
          "private_meeting" -> "Private meetings are underway..."
          "day_discussion" -> "Day #{day_number} dawns. Time for discussion."
          "day_voting" -> "Discussion is over. Time to vote."
          "runoff_discussion" -> "No majority! The top candidates must defend themselves."
          "runoff_voting" -> "Runoff vote begins. Choose between the final candidates."
          "last_words_vote" -> "The condemned may speak their last words..."
          "last_words_night" -> "The fallen may speak their last words..."
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

  # -- Village events --

  @spec village_event(String.t(), String.t()) :: Event.t()
  def village_event(event_type, description) do
    Event.new("village_event", %{
      "event_type" => event_type,
      "description" => description
    })
  end

  # -- Items --

  @spec item_found(String.t(), String.t(), String.t()) :: Event.t()
  def item_found(player_id, item_type, description) do
    Event.new("item_found", %{
      "player_id" => player_id,
      "item_type" => item_type,
      "description" => description
    })
  end

  @spec item_used(String.t(), String.t()) :: Event.t()
  def item_used(player_id, item_type) do
    Event.new("item_used", %{
      "player_id" => player_id,
      "item_type" => item_type
    })
  end

  @spec anonymous_message(String.t()) :: Event.t()
  def anonymous_message(message) do
    Event.new("anonymous_message", %{
      "message" => message
    })
  end
end
