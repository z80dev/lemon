{:ok, _} = Application.ensure_all_started(:lemon_core)

alias LemonChannels.Adapters.Discord.Transport

parent = self()

Application.put_env(:lemon_channels, :discord_interaction_responder, fn _interaction, payload ->
  send(parent, {:interaction_response, payload})
  :ok
end)

now = DateTime.utc_now()

eventually = fn fun ->
  Enum.reduce_while(1..20, nil, fn _, _ ->
    case fun.() do
      nil ->
        Process.sleep(25)
        {:cont, nil}

      value ->
        {:halt, value}
    end
  end)
end

request_task =
  Task.async(fn ->
    LemonCore.ExecApprovals.request(%{
      run_id: "run_discord_component_proof",
      session_key: "agent:discord_component_proof:main",
      tool: "bash",
      action: %{command: "touch proof"},
      expires_in_ms: 5_000
    })
  end)

pending =
  eventually.(fn ->
    LemonCore.Store.list(:exec_approvals_pending)
    |> Enum.find_value(fn {_key, pending} ->
      if pending.run_id == "run_discord_component_proof", do: pending, else: nil
    end)
  end)

interaction = %{
  type: 3,
  id: "proof_interaction",
  channel_id: "proof_channel",
  guild_id: "proof_guild",
  data: %{custom_id: "#{pending.id}|once"},
  member: %{user: %{id: "proof_user"}}
}

{:noreply, %{}} =
  Transport.handle_info({:discord_event, {:INTERACTION_CREATE, interaction, nil}}, %{})

resolution =
  try do
    Task.await(request_task, 1_000)
  catch
    :exit, _ -> :failed
  end

response_ok? =
  receive do
    {:interaction_response,
     %{
       type: 7,
       data: %{
         content: "Approval: Approved (once)",
         components: [],
         allowed_mentions: %{parse: [], replied_user: false}
       }
     }} ->
      true
  after
    500 -> false
  end

checks = [
  %{
    name: "approval_component_resolves_once",
    status: if(resolution == {:ok, :approved, :approve_once}, do: "completed", else: "failed")
  },
  %{
    name: "approval_component_updates_message_safely",
    status: if(response_ok?, do: "completed", else: "failed")
  }
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "discord_approval_component",
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
File.write!(".lemon/proofs/discord-approval-component-proof-latest.json", json <> "\n")

archive =
  ".lemon/proofs/discord-approval-component-proof-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

Application.delete_env(:lemon_channels, :discord_interaction_responder)

if failed_count == 0 do
  IO.puts("discord approval component proof passed: #{completed_count} completed")
else
  IO.puts("discord approval component proof failed: #{failed_count} failed")
  System.halt(1)
end
