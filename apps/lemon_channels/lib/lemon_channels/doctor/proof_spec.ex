defmodule LemonChannels.Doctor.ProofSpec do
  @moduledoc """
  Channel-shaped proof classification for the doctor framework.

  Implements `LemonCore.Doctor.ChannelProofs` with the Telegram/Discord check
  names, evidence fields, and launch-gate semantics that the live channel
  matrix proofs emit. The reference runtime registers this module under
  `config :lemon_core, :doctor_runtime, channel_proofs: __MODULE__` so
  lemon_core never names a vendor channel directly.
  """

  @behaviour LemonCore.Doctor.ChannelProofs

  alias LemonCore.Doctor.Check

  @impl LemonCore.Doctor.ChannelProofs
  def origin_cron_checks do
    ["telegram_channel_origin_cron_delivery", "discord_channel_origin_cron_delivery"]
  end

  @impl LemonCore.Doctor.ChannelProofs
  def media_delivery_check_names do
    [
      "telegram_forum_topic_generated_media_delivery",
      "telegram_forum_topic_generated_audio_delivery",
      "telegram_forum_topic_media_directive_delivery",
      "discord_generated_media_delivery",
      "discord_generated_audio_delivery",
      "discord_media_directive_delivery"
    ]
  end

  @impl LemonCore.Doctor.ChannelProofs
  def media_delivery_proof(checks) when is_list(checks) do
    checks
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn check, acc ->
      case safe_scope(value(check, "name")) do
        name
        when name in [
               "telegram_forum_topic_generated_media_delivery",
               "telegram_forum_topic_generated_audio_delivery",
               "telegram_forum_topic_media_directive_delivery"
             ] ->
          document = value(check, "document")

          acc
          |> Map.put(:channel_delivery, true)
          |> Map.put(:telegram_delivery, check_status_value(check) == "completed")
          |> maybe_put_atom(
            :telegram_has_document,
            first_non_nil([
              bool_or_nil(value(document, "has_document")),
              bool_or_nil(value(check, "telegram_has_document"))
            ])
          )
          |> maybe_put_atom(:marker_seen, bool_or_nil(value(check, "marker_seen")))
          |> put_media_directive_delivery(name == "telegram_forum_topic_media_directive_delivery")
          |> put_directive_leaked(bool_or_nil(value(check, "directive_leaked")))

        name
        when name in [
               "discord_generated_media_delivery",
               "discord_generated_audio_delivery",
               "discord_media_directive_delivery"
             ] ->
          bot_reply = value(check, "bot_reply")

          acc
          |> Map.put(:channel_delivery, true)
          |> Map.put(:discord_delivery, check_status_value(check) == "completed")
          |> maybe_put_atom(
            :discord_attachment_count,
            int_or_nil(value(bot_reply, "attachment_count")) ||
              int_or_nil(value(check, "attachment_count"))
          )
          |> put_media_directive_delivery(name == "discord_media_directive_delivery")
          |> put_directive_leaked(
            first_non_nil([
              bool_or_nil(value(bot_reply, "directive_leaked")),
              bool_or_nil(value(check, "directive_leaked"))
            ])
          )

        _ ->
          acc
      end
    end)
  end

  def media_delivery_proof(_), do: %{}

  @impl LemonCore.Doctor.ChannelProofs
  def media_delivery_check(proofs) do
    telegram? = completed_delivery?(proofs, :telegram_delivery)
    discord? = completed_delivery?(proofs, :discord_delivery)

    cond do
      telegram? and discord? ->
        Check.pass(
          "media.channel_delivery",
          "Media attachment delivery proof is completed for Telegram and Discord."
        )

      telegram? or discord? ->
        Check.warn(
          "media.channel_delivery",
          "Media attachment delivery proof is only complete for #{delivery_label(telegram?, discord?)}.",
          "Run the generated media/audio or MEDIA directive live matrix for both Telegram and Discord."
        )

      true ->
        Check.warn(
          "media.channel_delivery",
          "Media attachment delivery proof is missing for Telegram and Discord.",
          "Run the Telegram and Discord generated media/audio or MEDIA directive live matrix proofs."
        )
    end
  end

  @impl LemonCore.Doctor.ChannelProofs
  def failure_hint(nil), do: nil

  def failure_hint(hint) do
    cond do
      String.contains?(hint, "50007") or
          String.contains?(hint, "cannot send messages to this user") ->
        "discord_dm_setup_refused"

      String.contains?(hint, "message_content_intent_declared=false") ->
        "discord_message_content_intent_or_delivery"

      String.contains?(hint, "no lemon reply") and
          String.contains?(hint, "unmentioned") ->
        "discord_no_reply_for_unmentioned_message"

      String.contains?(hint, "message content intent") ->
        "discord_message_content_intent_or_delivery"

      true ->
        nil
    end
  end

  @impl LemonCore.Doctor.ChannelProofs
  def setup_error_hint(nil), do: nil

  def setup_error_hint(error) do
    cond do
      String.contains?(error, "50007") or
          String.contains?(error, "cannot send messages to this user") ->
        "discord_dm_setup_refused"

      true ->
        nil
    end
  end

  @impl LemonCore.Doctor.ChannelProofs
  def launch_gates(proof_status) do
    checks = Map.get(proof_status, :latest_checks, [])
    proofs = Map.get(proof_status, :recent_proofs, [])
    reason_counts = Map.get(proof_status, :reason_kind_counts, %{})

    %{
      "discordDm" => discord_dm_gate(checks, reason_counts),
      "discordSlashRegistration" => discord_slash_registration_gate(checks, proofs),
      "discordSlashClientClick" => discord_slash_client_gate(checks, proofs)
    }
  end

  defp discord_dm_gate(checks, reason_counts) do
    cond do
      latest_check_completed?(checks, "discord_dm_prompt_round_trip") ->
        %{
          "status" => "passed",
          "evidence" => "Discord DM prompt round-trip proof is completed."
        }

      Map.get(reason_counts, "discord_dm_setup_refused", 0) > 0 ->
        %{
          "status" => "blocked",
          "reasonKind" => "discord_dm_setup_refused",
          "evidence" =>
            "Discord DM setup refused because no reachable human/open-DM target was available.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --wait-dm-inbound with --dm-channel-id or --dm-recipient-id for a reachable human/open-DM target."
        }

      true ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_dm_missing",
          "evidence" => "Discord DM prompt round-trip proof has not been captured.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --wait-dm-inbound with --dm-channel-id or --dm-recipient-id."
        }
    end
  end

  defp discord_slash_registration_gate(checks, proofs) do
    cond do
      latest_check_completed?(checks, "discord_all_slash_registration") or
          completed_registration_coverage?(proofs, :contains_all_slash_registration) ->
        %{
          "status" => "passed",
          "evidence" =>
            "Discord application-command registration proof covers all expected Lemon commands."
        }

      latest_check_completed?(checks, "discord_rollback_slash_registration") or
          completed_registration_coverage?(proofs, :contains_rollback_slash_registration) ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_all_slash_registration_missing",
          "evidence" =>
            "Discord /rollback slash registration proof is present but all-command proof is missing.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        }

      latest_check_completed?(checks, "discord_media_slash_registration") or
          completed_registration_coverage?(proofs, :contains_media_slash_registration) ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_all_slash_registration_missing",
          "evidence" =>
            "Discord /media slash registration proof is present but all-command proof is missing.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        }

      true ->
        %{
          "status" => "warning",
          "reasonKind" => "discord_slash_registration_missing",
          "evidence" => "Discord application-command registration proof is missing.",
          "nextAction" =>
            "Run scripts/live_discord_matrix.py --check-all-slash-registration --proof-path .lemon/proofs/discord-all-slash-registration-latest.json."
        }
    end
  end

  defp discord_slash_client_gate(checks, proofs) do
    reason =
      latest_check_reason(checks, "discord_slash_client_click_proof_wait") ||
        latest_check_reason(checks, "discord_slash_client_click_proof_artifact") ||
        "discord_slash_client_click_missing"

    cond do
      latest_check_completed?(checks, "discord_slash_client_click_proof_wait") or
        latest_check_completed?(checks, "discord_slash_client_click_proof_artifact") or
          real_client_click_proof?(proofs) ->
        %{
          "status" => "passed",
          "evidence" =>
            "Discord slash client-click proof is completed from a real Discord interaction."
        }

      reason in [
        "discord_slash_client_click_invalid_artifact",
        "discord_slash_client_click_not_promotable",
        "discord_slash_client_click_stale"
      ] ->
        %{
          "status" => "blocked",
          "reasonKind" => reason,
          "evidence" =>
            "Discord slash client-click proof exists but cannot promote the launch gate.",
          "nextAction" =>
            "Rerun scripts/live_discord_matrix.py --wait-slash-client-click-proof while clicking a fresh real Discord slash command."
        }

      true ->
        %{
          "status" => "warning",
          "reasonKind" => reason,
          "evidence" =>
            "Discord slash client-click proof has not been captured from a real Discord client.",
          "nextAction" =>
            "Deploy or hot reload the runtime, then run scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id DISCORD_PROOF_CHANNEL_ID while clicking the requested real slash command."
        }
    end
  end

  defp latest_check_completed?(checks, name) do
    Enum.any?(checks, &(Map.get(&1, :name) == name and Map.get(&1, :status) == "completed"))
  end

  defp completed_registration_coverage?(proofs, key) do
    Enum.any?(proofs, fn proof ->
      Map.get(proof, :status) == "completed" and get_in(proof, [:coverage, key]) == true
    end)
  end

  defp latest_check_reason(checks, name) do
    case Enum.find(checks, &(Map.get(&1, :name) == name)) do
      nil -> nil
      check -> Map.get(check, :reason_kind)
    end
  end

  defp real_client_click_proof?(proofs) do
    Enum.any?(proofs, fn proof ->
      Map.get(proof, :status) == "completed" and
        Map.get(proof, :proof_object) == "lemon.discord_slash_client_click" and
        get_in(proof, [:coverage, :real_client_click_proof]) == true
    end)
  end

  defp completed_delivery?(proofs, key) do
    proofs
    |> Map.get(:recent_proofs, [])
    |> Enum.any?(fn proof ->
      Map.get(proof, :status) == "completed" and
        get_in(proof, [:media_proof, key]) == true
    end)
  end

  defp delivery_label(true, false), do: "Telegram"
  defp delivery_label(false, true), do: "Discord"
  defp delivery_label(_, _), do: "neither channel"

  defp put_media_directive_delivery(map, true), do: Map.put(map, :media_directive_delivery, true)
  defp put_media_directive_delivery(map, false), do: map

  defp put_directive_leaked(map, nil), do: map
  defp put_directive_leaked(map, true), do: Map.put(map, :directive_leaked, true)
  defp put_directive_leaked(map, false), do: Map.put_new(map, :directive_leaked, false)

  defp first_non_nil(values), do: Enum.find(values, &(not is_nil(&1)))

  defp maybe_put_atom(map, _key, nil), do: map
  defp maybe_put_atom(map, key, value), do: Map.put(map, key, value)

  defp check_status_value(check) do
    case nullable_string(value(check, "status")) do
      nil -> status_from_ok(value(check, "ok"))
      status -> status
    end
  end

  defp status_from_ok(true), do: "completed"
  defp status_from_ok(false), do: "failed"
  defp status_from_ok(_), do: nil

  defp int_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp int_or_nil(_), do: nil

  defp bool_or_nil(value) when is_boolean(value), do: value
  defp bool_or_nil(_), do: nil

  defp nullable_string(nil), do: nil
  defp nullable_string(value), do: safe_string(value, nil)

  defp safe_string(value, _default) when is_binary(value), do: value
  defp safe_string(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(_value, default), do: default

  defp safe_scope(value) do
    case nullable_string(value) do
      nil ->
        nil

      string ->
        scope =
          string
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")
          |> binary_part_safe(0, 80)

        if scope != "", do: scope
    end
  end

  defp binary_part_safe(string, start, length) do
    binary_part(string, start, min(byte_size(string), length))
  end

  defp value(map, key) when is_map(map) do
    atom = atom_key(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_atom(atom) and Map.has_key?(map, atom) -> Map.get(map, atom)
      true -> nil
    end
  end

  defp value(_, _), do: nil

  defp atom_key("name"), do: :name
  defp atom_key("document"), do: :document
  defp atom_key("bot_reply"), do: :bot_reply
  defp atom_key("has_document"), do: :has_document
  defp atom_key("telegram_has_document"), do: :telegram_has_document
  defp atom_key("marker_seen"), do: :marker_seen
  defp atom_key("attachment_count"), do: :attachment_count
  defp atom_key("directive_leaked"), do: :directive_leaked
  defp atom_key("status"), do: :status
  defp atom_key("ok"), do: :ok
  defp atom_key(_), do: nil
end
