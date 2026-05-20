defmodule LemonDiscordSafeMentionsProofApi do
  def create(channel_id, params) do
    send(self(), {:create, channel_id, params})
    {:ok, %{id: 4444}}
  end

  def edit(channel_id, message_id, params) do
    send(self(), {:edit, channel_id, message_id, params})
    {:ok, %{id: message_id}}
  end

  def delete(_channel_id, _message_id), do: {:ok, %{}}
  def react(_channel_id, _message_id, _emoji), do: {:ok}
  def unreact(_channel_id, _message_id, _emoji), do: {:ok}
end

alias LemonChannels.Adapters.Discord.Outbound
alias LemonChannels.OutboundPayload

gateway_config_key = :"Elixir.LemonGateway.Config"
old_config = Application.get_env(:lemon_gateway, gateway_config_key)
old_test_mode = Application.get_env(:lemon_core, :config_test_mode)

Application.put_env(:lemon_core, :config_test_mode, true)

Application.put_env(:lemon_gateway, gateway_config_key, %{
  enable_discord: true,
  discord: %{api_mod: LemonDiscordSafeMentionsProofApi}
})

now = DateTime.utc_now()
safe_mentions = %{parse: [], replied_user: false}

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
  run_check.("text_mentions_disabled", fn ->
    payload = %OutboundPayload{
      channel_id: "discord",
      account_id: "acct",
      peer: %{kind: :group, id: "123", thread_id: nil},
      kind: :text,
      content: "@everyone <@123> <@&456> @here",
      reply_to: "777"
    }

    {:ok, _} = Outbound.deliver(payload)

    receive do
      {:create, 123,
       %{
         allowed_mentions: ^safe_mentions,
         message_reference: %{message_id: 777}
       }} ->
        true
    after
      500 -> false
    end
  end),
  run_check.("edit_mentions_disabled", fn ->
    payload = %OutboundPayload{
      channel_id: "discord",
      account_id: "acct",
      peer: %{kind: :group, id: "123", thread_id: nil},
      kind: :edit,
      content: %{message_id: "888", text: "@everyone edited"}
    }

    {:ok, _} = Outbound.deliver(payload)

    receive do
      {:edit, 123, 888, %{allowed_mentions: ^safe_mentions}} -> true
    after
      500 -> false
    end
  end),
  run_check.("file_caption_mentions_disabled", fn ->
    path =
      Path.join(
        System.tmp_dir!(),
        "discord-safe-mentions-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "artifact")

    try do
      payload = %OutboundPayload{
        channel_id: "discord",
        account_id: "acct",
        peer: %{kind: :group, id: "123", thread_id: nil},
        kind: :file,
        content: %{path: path, filename: "artifact.txt", caption: "@everyone artifact"}
      }

      {:ok, _} = Outbound.deliver(payload)

      receive do
        {:create, 123, %{allowed_mentions: ^safe_mentions, files: [_]}} -> true
      after
        500 -> false
      end
    after
      File.rm(path)
    end
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "discord_safe_mentions",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "allowed_mentions" => %{"parse_count" => 0, "replied_user" => false},
  "redaction" => %{
    "contains_raw_tokens" => false,
    "contains_channel_ids" => false,
    "contains_message_bodies" => false,
    "contains_session_ids" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/discord-safe-mentions-proof-latest.json", json <> "\n")

archive =
  ".lemon/proofs/discord-safe-mentions-proof-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

if old_config == nil do
  Application.delete_env(:lemon_gateway, gateway_config_key)
else
  Application.put_env(:lemon_gateway, gateway_config_key, old_config)
end

if old_test_mode == nil do
  Application.delete_env(:lemon_core, :config_test_mode)
else
  Application.put_env(:lemon_core, :config_test_mode, old_test_mode)
end

if failed_count == 0 do
  IO.puts("discord safe mentions proof passed: #{completed_count} completed")
else
  IO.puts("discord safe mentions proof failed: #{failed_count} failed")
  System.halt(1)
end
