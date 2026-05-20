alias LemonChannels.Adapters.Discord.Transport

Application.ensure_all_started(:lemon_core)

parent = self()

Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction, payload ->
  send(parent, {:interaction_response, interaction, payload})
  :ok
end)

now = DateTime.utc_now()
proof_channel = Integer.to_string(1_475_727_417_372_049_419 + System.unique_integer([:positive]))
proof_thread = Integer.to_string(1_475_727_417_372_149_419 + System.unique_integer([:positive]))

interaction = fn name, options ->
  %{
    type: 2,
    id: "proof_interaction_#{System.unique_integer([:positive])}",
    channel_id: proof_channel,
    guild_id: "proof_guild",
    data: %{name: name, options: List.wrap(options)},
    member: %{user: %{id: "proof_user"}}
  }
end

thread_interaction = fn name, options ->
  base = interaction.(name, options)

  Map.put(base, :channel, %{
    id: proof_thread,
    parent_id: proof_channel,
    type: 11
  })
end

option = fn name, value -> %{name: name, value: value} end

subcommand = fn name, opts ->
  %{
    type: 1,
    name: name,
    options:
      Enum.map(opts, fn {key, value} ->
        %{name: Atom.to_string(key), value: value}
      end)
  }
end

subcommand0 = fn name -> subcommand.(name, []) end

safe_state = %{
  account_id: "proof_account",
  bot_user_id: 1,
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

decode_check = fn name, discord_interaction, expected ->
  fn ->
    actual = Transport.slash_command_args_for_interaction(discord_interaction)
    {name, actual == {:ok, expected}, %{command: expected.command, args: expected.args}}
  end
end

response_check = fn name, discord_interaction, content_matcher ->
  fn ->
    {:noreply, _state} =
      Transport.handle_info(
        {:discord_event, {:INTERACTION_CREATE, discord_interaction, nil}},
        safe_state
      )

    passed? =
      receive do
        {:interaction_response, ^discord_interaction,
         %{
           type: type,
           data: %{
             content: content,
             allowed_mentions: %{parse: [], replied_user: false}
           }
         }}
        when type in [4, 7] and is_binary(content) ->
          content_matcher.(content)

        {:interaction_response, ^discord_interaction, %{type: 6}} ->
          content_matcher.("")
      after
        500 -> false
      end

    {name, passed?, %{}}
  end
end

nonempty = fn content -> String.trim(content) != "" end
contains = fn needle -> fn content -> String.contains?(content, needle) end end

checks = [
  fn ->
    names = Enum.map(Transport.slash_commands(), & &1.name)

    expected =
      ~w(lemon session model thinking resume cancel checkpoint rollback goal kanban media trigger cwd reload topic file)

    {"slash_command_inventory_16", Enum.sort(names) == Enum.sort(expected),
     %{
       command_count: length(names)
     }}
  end,
  decode_check.(
    "checkpoint_status_decode",
    interaction.("checkpoint", subcommand0.("status")),
    %{command: "checkpoint", args: "status"}
  ),
  decode_check.(
    "checkpoint_events_decode",
    interaction.("checkpoint", subcommand.("events", limit: 5)),
    %{command: "checkpoint", args: "events 5"}
  ),
  decode_check.(
    "checkpoint_diff_decode",
    interaction.("checkpoint", subcommand.("diff", checkpoint_id: "chk_proof")),
    %{command: "checkpoint", args: "diff chk_proof"}
  ),
  decode_check.(
    "checkpoint_restore_decode",
    interaction.("checkpoint", subcommand.("restore", checkpoint_id: "chk_proof", confirm: true)),
    %{command: "checkpoint", args: "restore chk_proof confirm"}
  ),
  decode_check.(
    "rollback_restore_decode",
    interaction.("rollback", subcommand.("restore", checkpoint_id: "chk_proof", confirm: true)),
    %{command: "rollback", args: "restore chk_proof confirm"}
  ),
  decode_check.(
    "kanban_boards_decode",
    interaction.("kanban", subcommand.("boards", status: "open", owner: "agent", limit: 10)),
    %{command: "kanban", args: "boards --status open --owner agent --limit 10"}
  ),
  decode_check.(
    "kanban_create_decode",
    interaction.("kanban", subcommand.("create", name: "proof board", workspace: "/tmp/proof")),
    %{command: "kanban", args: "create --workspace /tmp/proof proof board"}
  ),
  decode_check.(
    "kanban_show_decode",
    interaction.("kanban", subcommand.("show", board_id: "board_proof", limit: 5)),
    %{command: "kanban", args: "show board_proof --limit 5"}
  ),
  decode_check.(
    "kanban_archive_decode",
    interaction.("kanban", subcommand.("archive", board_id: "board_proof")),
    %{command: "kanban", args: "archive board_proof"}
  ),
  decode_check.(
    "kanban_task_create_decode",
    interaction.(
      "kanban",
      subcommand.("task_create",
        board_id: "board_proof",
        priority: "high",
        assignee: "alice",
        worker_profile: "builder",
        title: "ship slash proof"
      )
    ),
    %{
      command: "kanban",
      args:
        "task create board_proof --priority high --assignee alice --worker-profile builder ship slash proof"
    }
  ),
  decode_check.(
    "kanban_task_update_decode",
    interaction.(
      "kanban",
      subcommand.("task_update",
        task_id: "task_proof",
        status: "doing",
        priority: "medium",
        assignee: "bob",
        worker_profile: "reviewer"
      )
    ),
    %{
      command: "kanban",
      args:
        "task update task_proof --status doing --priority medium --assignee bob --worker-profile reviewer"
    }
  ),
  decode_check.(
    "kanban_comment_decode",
    interaction.("kanban", subcommand.("comment", task_id: "task_proof", body: "proof note")),
    %{command: "kanban", args: "comment task_proof proof note"}
  ),
  decode_check.(
    "kanban_dispatch_start_decode",
    interaction.(
      "kanban",
      subcommand.("dispatch_start",
        board_id: "board_proof",
        max_concurrency: 3,
        worker_profile: "builder"
      )
    ),
    %{
      command: "kanban",
      args: "dispatch start board_proof --max-concurrency 3 --worker-profile builder"
    }
  ),
  decode_check.(
    "kanban_dispatch_status_decode",
    interaction.("kanban", subcommand.("dispatch_status", board_id: "board_proof")),
    %{command: "kanban", args: "dispatch status board_proof"}
  ),
  decode_check.(
    "kanban_dispatch_stop_decode",
    interaction.("kanban", subcommand.("dispatch_stop", board_id: "board_proof")),
    %{command: "kanban", args: "dispatch stop board_proof"}
  ),
  decode_check.(
    "media_status_decode",
    interaction.("media", subcommand0.("status")),
    %{command: "media", args: "status"}
  ),
  response_check.(
    "lemon_empty_prompt_response",
    interaction.("lemon", option.("prompt", "")),
    contains.("Prompt cannot be empty")
  ),
  response_check.(
    "session_info_response",
    interaction.("session", subcommand0.("info")),
    contains.("Session Info")
  ),
  response_check.("model_picker_response", interaction.("model", []), nonempty),
  response_check.(
    "thinking_status_response",
    interaction.("thinking", option.("level", "status")),
    contains.("Thinking")
  ),
  response_check.(
    "thinking_set_response",
    interaction.("thinking", option.("level", "medium")),
    contains.("Thinking level")
  ),
  response_check.(
    "thinking_clear_response",
    interaction.("thinking", option.("level", "clear")),
    nonempty
  ),
  response_check.(
    "resume_empty_response",
    interaction.("resume", []),
    contains.("recent sessions")
  ),
  response_check.("cancel_no_active_run_response", interaction.("cancel", []), nonempty),
  response_check.(
    "media_status_interaction_response",
    interaction.("media", subcommand0.("status")),
    nonempty
  ),
  response_check.(
    "trigger_status_response",
    interaction.("trigger", option.("mode", "status")),
    contains.("Trigger mode")
  ),
  response_check.(
    "trigger_all_response",
    interaction.("trigger", option.("mode", "all")),
    contains.("Trigger mode set")
  ),
  response_check.(
    "trigger_mentions_response",
    interaction.("trigger", option.("mode", "mentions")),
    contains.("Trigger mode set")
  ),
  response_check.("cwd_status_response", interaction.("cwd", []), nonempty),
  response_check.(
    "cwd_clear_response",
    interaction.("cwd", option.("path", "clear")),
    nonempty
  ),
  response_check.(
    "topic_empty_name_response",
    interaction.("topic", []),
    contains.("Thread name")
  ),
  response_check.(
    "file_put_missing_attachment_response",
    interaction.("file", subcommand0.("put")),
    contains.("attach a file")
  ),
  response_check.(
    "file_get_missing_path_response",
    interaction.("file", subcommand0.("get")),
    contains.("file path")
  ),
  response_check.(
    "unknown_command_response",
    thread_interaction.("unknown", []),
    contains.("Unknown command")
  )
]

results =
  Enum.map(checks, fn check ->
    {name, passed?, details} = check.()
    %{name: name, status: if(passed?, do: "completed", else: "failed"), details: details}
  end)

completed_count = Enum.count(results, &(&1.status == "completed"))
failed_count = Enum.count(results, &(&1.status == "failed"))

proof = %{
  "proof" => "discord_slash_interaction",
  "proof_object" => "lemon.discord_slash_interaction",
  "proof_scope" => "discord_slash_interaction_deterministic",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => results,
  "coverage" => %{
    "registered_command_count" => length(Transport.slash_commands()),
    "decode_command_count" => 3,
    "local_response_command_count" => 13,
    "real_client_click_proof" => false
  },
  "redaction" => %{
    "contains_raw_tokens" => false,
    "contains_channel_ids" => false,
    "contains_message_bodies" => false,
    "contains_session_ids" => false
  },
  "notes" => [
    "Deterministic proof covers Discord application-command inventory, local payload decoding, and local INTERACTION_CREATE response handling.",
    "This is not a live Discord client-click proof from a human Discord client.",
    "Side-effecting live paths such as reload, topic creation, real file transfer, and queued agent runs remain outside this deterministic proof."
  ]
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/discord-slash-interaction-proof-latest.json", json <> "\n")

archive =
  ".lemon/proofs/discord-slash-interaction-proof-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")
Application.delete_env(:lemon_channels, :discord_interaction_responder)

if failed_count == 0 do
  IO.puts("discord slash interaction proof passed: #{completed_count} completed")
else
  IO.puts("discord slash interaction proof failed: #{failed_count} failed")
  System.halt(1)
end
