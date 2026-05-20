{:ok, _} = Application.ensure_all_started(:lemon_core)

defmodule LemonDiscordRuntimeComponentsProofRouter do
  def abort_run(run_id, reason) do
    send(test_pid(), {:abort_run, run_id, reason})
    :ok
  end

  def keep_run_alive(run_id, decision) do
    send(test_pid(), {:keep_run_alive, run_id, decision})
    :ok
  end

  defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
end

alias LemonChannels.Adapters.Discord.Transport

parent = self()
previous_bridge = Application.get_env(:lemon_core, :router_bridge)
:persistent_term.put({LemonDiscordRuntimeComponentsProofRouter, :test_pid}, parent)
:ok = LemonCore.RouterBridge.configure(router: LemonDiscordRuntimeComponentsProofRouter)

Application.put_env(:lemon_channels, :discord_interaction_responder, fn _interaction, payload ->
  send(parent, {:interaction_response, payload})
  :ok
end)

now = DateTime.utc_now()

interaction = fn custom_id ->
  %{
    type: 3,
    id: "proof_interaction",
    channel_id: "proof_channel",
    guild_id: "proof_guild",
    data: %{custom_id: custom_id},
    member: %{user: %{id: "proof_user"}}
  }
end

run_component = fn custom_id ->
  {:noreply, %{}} =
    Transport.handle_info(
      {:discord_event, {:INTERACTION_CREATE, interaction.(custom_id), nil}},
      %{}
    )
end

check = fn name, fun ->
  status =
    try do
      if fun.(), do: "completed", else: "failed"
    rescue
      _ -> "failed"
    end

  %{name: name, status: status}
end

safe_update? = fn expected ->
  receive do
    {:interaction_response,
     %{
       type: 7,
       data: %{
         content: ^expected,
         components: [],
         allowed_mentions: %{parse: [], replied_user: false}
       }
     }} ->
      true
  after
    500 -> false
  end
end

checks = [
  check.("cancel_component_aborts_run", fn ->
    run_component.("lemon:cancel:run_cancel_proof")

    routed? =
      receive do
        {:abort_run, "run_cancel_proof", :user_requested} -> true
      after
        500 -> false
      end

    routed? and safe_update?.("Cancelling...")
  end),
  check.("keepalive_continue_component_routes_decision", fn ->
    run_component.("lemon:idle:c:run_keepalive_proof")

    routed? =
      receive do
        {:keep_run_alive, "run_keepalive_proof", :continue} -> true
      after
        500 -> false
      end

    routed? and safe_update?.("Continuing run.")
  end),
  check.("keepalive_cancel_component_routes_decision", fn ->
    run_component.("lemon:idle:k:run_keepalive_proof")

    routed? =
      receive do
        {:keep_run_alive, "run_keepalive_proof", :cancel} -> true
      after
        500 -> false
      end

    routed? and safe_update?.("Stopping run.")
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "discord_runtime_components",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "redaction" => %{
    "contains_raw_tokens" => false,
    "contains_channel_ids" => false,
    "contains_message_bodies" => false,
    "contains_session_ids" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/discord-runtime-components-proof-latest.json", json <> "\n")

archive =
  ".lemon/proofs/discord-runtime-components-proof-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

Application.delete_env(:lemon_channels, :discord_interaction_responder)
:persistent_term.erase({LemonDiscordRuntimeComponentsProofRouter, :test_pid})

if previous_bridge == nil do
  Application.delete_env(:lemon_core, :router_bridge)
else
  Application.put_env(:lemon_core, :router_bridge, previous_bridge)
end

if failed_count == 0 do
  IO.puts("discord runtime components proof passed: #{completed_count} completed")
else
  IO.puts("discord runtime components proof failed: #{failed_count} failed")
  System.halt(1)
end
