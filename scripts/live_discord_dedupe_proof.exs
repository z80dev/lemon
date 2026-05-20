{:ok, _} = Application.ensure_all_started(:lemon_core)

defmodule LemonDiscordDedupeProofRouter do
  def submit(run_request) do
    send(test_pid(), {:submit_run, run_request})
    {:ok, "run_discord_dedupe_proof"}
  end

  def abort_run(_run_id, _reason), do: :ok
  def keep_run_alive(_run_id, _decision), do: :ok

  defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
end

defmodule LemonDiscordDedupeProofApi do
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

:persistent_term.put({LemonDiscordDedupeProofRouter, :test_pid}, parent)

:ok =
  LemonCore.RouterBridge.configure(
    router: LemonDiscordDedupeProofRouter,
    run_orchestrator: LemonDiscordDedupeProofRouter
  )

Application.put_env(:lemon_core, :config_test_mode, true)

Application.put_env(:lemon_gateway, gateway_config_key, %{
  enable_discord: true,
  discord: %{api_mod: LemonDiscordDedupeProofApi}
})

:ok = LemonCore.Dedupe.Ets.init(:lemon_channels_discord_dedupe)
_ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

now = DateTime.utc_now()
bot_user_id = 1_476_753_643_834_183_690
run_suffix = System.system_time(:millisecond) |> rem(1_000_000_000)
message_id = 1_503_803_470_493_259_000 + run_suffix * 1_000 + System.unique_integer([:positive])
channel_id = 1_475_727_417_372_049_419 + run_suffix

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

message = %{
  "id" => Integer.to_string(message_id),
  "channel_id" => Integer.to_string(channel_id),
  "guild_id" => "1475727416549969980",
  "content" => "<@#{bot_user_id}> dedupe proof",
  "author" => %{"id" => "1476753643834183691", "bot" => false}
}

state_after_first =
  case Transport.handle_info({:discord_event, {:MESSAGE_CREATE, message, nil}}, state) do
    {:noreply, next_state} -> next_state
    _ -> state
  end

buffer_entry = Map.to_list(state_after_first.buffers)

state_after_duplicate =
  case Transport.handle_info({:discord_event, {:MESSAGE_CREATE, message, nil}}, state_after_first) do
    {:noreply, next_state} -> next_state
    _ -> state_after_first
  end

_state_after_flush =
  case buffer_entry do
    [{scope_key, buffer}] ->
      case Transport.handle_info(
             {:debounce_flush, scope_key, buffer.debounce_ref},
             state_after_duplicate
           ) do
        {:noreply, next_state} -> next_state
        _ -> state_after_duplicate
      end

    _ ->
      state_after_duplicate
  end

first_submission =
  receive do
    {:submit_run, run_request} -> run_request
  after
    500 -> nil
  end

first_reaction? =
  receive do
    {:discord_react, _, _, _} -> true
  after
    200 -> false
  end

_ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

restarted_state = %{
  state
  | buffers: %{},
    reaction_runs: %{},
    pending_new: %{}
}

_ =
  Transport.handle_info(
    {:discord_event, {:MESSAGE_CREATE, message, nil}},
    restarted_state
  )

second_submission? =
  receive do
    {:submit_run, _run_request} -> true
  after
    200 -> false
  end

second_reaction? =
  receive do
    {:discord_react, _, _, _} -> true
  after
    200 -> false
  end

run_check = fn name, fun ->
  status =
    try do
      if fun.(), do: "completed", else: "failed"
    rescue
      _ -> "failed"
    end

  %{name: name, status: status}
end

checks = [
  run_check.("first_message_buffered", fn ->
    match?([{_scope_key, %{messages: [_], debounce_ref: _}}], buffer_entry)
  end),
  run_check.("duplicate_marked_seen_before_flush", fn ->
    state_after_duplicate.buffers == state_after_first.buffers
  end),
  run_check.("single_run_submitted_after_flush", fn ->
    match?(%LemonCore.RunRequest{origin: :channel}, first_submission) and
      first_submission.meta[:user_msg_id] == message_id and
      first_reaction?
  end),
  run_check.("transport_restart_replay_duplicate_does_not_submit_again", fn ->
    second_submission? == false and second_reaction? == false
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "discord_inbound_dedupe",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "dedupe_boundary" => %{
    "event" => "MESSAGE_CREATE",
    "duplicate_position" => "before_debounce_flush_and_after_transport_restart",
    "persistent_scope" => "discord_inbound",
    "transport_restart_simulated" => true,
    "fresh_state_buffers" => map_size(restarted_state.buffers),
    "router_submissions" => if(is_nil(first_submission), do: 0, else: 1)
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
File.write!(".lemon/proofs/discord-dedupe-proof-latest.json", json <> "\n")

archive =
  ".lemon/proofs/discord-dedupe-proof-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

:persistent_term.erase({LemonDiscordDedupeProofRouter, :test_pid})

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
  IO.puts("discord dedupe proof passed: #{completed_count} completed")
else
  IO.puts("discord dedupe proof failed: #{failed_count} failed")
  System.halt(1)
end
