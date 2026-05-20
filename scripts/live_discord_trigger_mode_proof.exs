{:ok, _} = Application.ensure_all_started(:lemon_core)

defmodule LemonDiscordTriggerModeProofRouter do
  def submit(run_request) do
    send(test_pid(), {:submit_run, run_request})
    {:ok, "run_discord_trigger_mode_proof"}
  end

  def abort_run(_run_id, _reason), do: :ok
  def keep_run_alive(_run_id, _decision), do: :ok

  defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
end

defmodule LemonDiscordTriggerModeProofApi do
  def create(_channel_id, _params), do: {:ok, %{id: 4444}}
  def edit(_channel_id, message_id, _params), do: {:ok, %{id: message_id}}
  def delete(_channel_id, _message_id), do: {:ok, %{}}

  def react(channel_id, message_id, emoji) do
    send(self(), {:discord_react, channel_id, message_id, emoji})
    {:ok}
  end

  def unreact(_channel_id, _message_id, _emoji), do: {:ok}
end

alias LemonChannels.Adapters.Discord.Transport

gateway_config_key = :"Elixir.LemonGateway.Config"
parent = self()
previous_bridge = Application.get_env(:lemon_core, :router_bridge)
previous_config = Application.get_env(:lemon_gateway, gateway_config_key)
previous_test_mode = Application.get_env(:lemon_core, :config_test_mode)

:persistent_term.put({LemonDiscordTriggerModeProofRouter, :test_pid}, parent)

:ok =
  LemonCore.RouterBridge.configure(
    router: LemonDiscordTriggerModeProofRouter,
    run_orchestrator: LemonDiscordTriggerModeProofRouter
  )

Application.put_env(:lemon_core, :config_test_mode, true)

Application.put_env(:lemon_gateway, gateway_config_key, %{
  enable_discord: true,
  discord: %{api_mod: LemonDiscordTriggerModeProofApi}
})

:ok = LemonCore.Dedupe.Ets.init(:lemon_channels_discord_dedupe)
_ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

now = DateTime.utc_now()
bot_user_id = 1_476_753_643_834_183_690
run_suffix = System.system_time(:millisecond) |> rem(1_000_000_000)
channel_id = 1_475_727_417_372_049_419 + run_suffix
guild_id = 1_475_727_416_549_969_980

state = %{
  account_id: "default",
  bot_user_id: bot_user_id,
  allowed_guild_ids: nil,
  allowed_channel_ids: nil,
  deny_unbound_channels: false,
  model_pickers: %{},
  buffers: %{},
  reaction_runs: %{},
  pending_new: %{},
  debounce_ms: 10_000,
  dedupe_ttl_ms: 600_000,
  files: %{}
}

message = fn text ->
  %{
    "id" =>
      Integer.to_string(
        1_503_803_470_493_300_000 + run_suffix * 1_000 + System.unique_integer([:positive])
      ),
    "channel_id" => Integer.to_string(channel_id),
    "guild_id" => Integer.to_string(guild_id),
    "content" => text,
    "author" => %{"id" => "1476753643834183691", "bot" => false}
  }
end

interaction = fn mode ->
  %{
    type: 2,
    id:
      Integer.to_string(
        1_503_803_470_493_310_000 + run_suffix * 1_000 + System.unique_integer([:positive])
      ),
    channel_id: Integer.to_string(channel_id),
    guild_id: Integer.to_string(guild_id),
    data: %{name: "trigger", options: [%{name: "mode", value: mode}]},
    member: %{user: %{id: "1476753643834183691"}}
  }
end

Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction, payload ->
  send(parent, {:interaction_response, interaction, payload})
  :ok
end)

no_submit? = fn ->
  receive do
    {:submit_run, _run_request} -> false
  after
    100 -> true
  end
end

ignored_message = message.("ordinary message before trigger all")

ignored_state =
  case Transport.handle_info({:discord_event, {:MESSAGE_CREATE, ignored_message, nil}}, state) do
    {:noreply, next_state} -> next_state
    _ -> state
  end

default_suppressed? = ignored_state.buffers == %{} and no_submit?.()

trigger_all = interaction.("all")

_ =
  Transport.handle_info({:discord_event, {:INTERACTION_CREATE, trigger_all, nil}}, ignored_state)

trigger_all_response? =
  receive do
    {:interaction_response, ^trigger_all,
     %{
       type: 4,
       data: %{
         content: "Trigger mode set to **all** for this channel.",
         flags: 64,
         allowed_mentions: %{parse: [], replied_user: false}
       }
     }} ->
      true
  after
    500 -> false
  end

free_message = message.("ordinary message after trigger all")

routed_state =
  case Transport.handle_info(
         {:discord_event, {:MESSAGE_CREATE, free_message, nil}},
         ignored_state
       ) do
    {:noreply, next_state} -> next_state
    _ -> ignored_state
  end

flushed_state =
  case Map.to_list(routed_state.buffers) do
    [{scope_key, buffer}] ->
      case Transport.handle_info({:debounce_flush, scope_key, buffer.debounce_ref}, routed_state) do
        {:noreply, next_state} -> next_state
        _ -> routed_state
      end

    _ ->
      routed_state
  end

free_response_submission? =
  receive do
    {:submit_run,
     %LemonCore.RunRequest{origin: :channel, prompt: "ordinary message after trigger all"}} ->
      receive do
        {:discord_react, ^channel_id, _message_id, _emoji} -> true
      after
        500 -> false
      end
  after
    500 -> false
  end

trigger_mentions = interaction.("mentions")

_ =
  Transport.handle_info(
    {:discord_event, {:INTERACTION_CREATE, trigger_mentions, nil}},
    flushed_state
  )

trigger_mentions_response? =
  receive do
    {:interaction_response, ^trigger_mentions,
     %{
       type: 4,
       data: %{
         content: "Trigger mode set to **mentions** for this channel.",
         flags: 64,
         allowed_mentions: %{parse: [], replied_user: false}
       }
     }} ->
      true
  after
    500 -> false
  end

suppressed_after_mentions_message = message.("ordinary message after trigger mentions")

suppressed_after_mentions_state =
  case Transport.handle_info(
         {:discord_event, {:MESSAGE_CREATE, suppressed_after_mentions_message, nil}},
         flushed_state
       ) do
    {:noreply, next_state} -> next_state
    _ -> flushed_state
  end

mentions_suppressed? = suppressed_after_mentions_state.buffers == %{} and no_submit?.()

checks = [
  %{
    name: "default_mentions_mode_suppresses_unmentioned_message",
    status: if(default_suppressed?, do: "completed", else: "failed")
  },
  %{
    name: "trigger_all_updates_channel_mode_safely",
    status: if(trigger_all_response?, do: "completed", else: "failed")
  },
  %{
    name: "trigger_all_allows_unmentioned_runtime_submission",
    status: if(free_response_submission?, do: "completed", else: "failed")
  },
  %{
    name: "trigger_mentions_restores_suppression",
    status:
      if(trigger_mentions_response? and mentions_suppressed?, do: "completed", else: "failed")
  }
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "discord_trigger_mode",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "trigger_boundary" => %{
    "default_mode" => "mentions",
    "free_response_mode" => "all",
    "restore_mode" => "mentions",
    "router_submissions_in_free_response_mode" => if(free_response_submission?, do: 1, else: 0)
  },
  "redaction" => %{
    "contains_raw_tokens" => false,
    "contains_channel_ids" => false,
    "contains_message_bodies" => false,
    "contains_session_ids" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/discord-trigger-mode-proof-latest.json", json <> "\n")

archive =
  ".lemon/proofs/discord-trigger-mode-proof-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

Application.delete_env(:lemon_channels, :discord_interaction_responder)
:persistent_term.erase({LemonDiscordTriggerModeProofRouter, :test_pid})

if previous_bridge == nil do
  Application.delete_env(:lemon_core, :router_bridge)
else
  Application.put_env(:lemon_core, :router_bridge, previous_bridge)
end

if previous_config == nil do
  Application.delete_env(:lemon_gateway, gateway_config_key)
else
  Application.put_env(:lemon_gateway, gateway_config_key, previous_config)
end

if previous_test_mode == nil do
  Application.delete_env(:lemon_core, :config_test_mode)
else
  Application.put_env(:lemon_core, :config_test_mode, previous_test_mode)
end

if failed_count == 0 do
  IO.puts("discord trigger mode proof passed: #{completed_count} completed")
else
  IO.puts("discord trigger mode proof failed: #{failed_count} failed")
  System.halt(1)
end
