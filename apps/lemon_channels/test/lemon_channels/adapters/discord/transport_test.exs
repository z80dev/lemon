defmodule LemonChannels.Adapters.Discord.TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonChannels.Adapters.Discord.Transport
  alias LemonChannels.Discord.KnownTargetStore
  alias LemonCore.Store

  @bot_user_id 1_476_753_643_834_183_690

  defmodule FakeRouter do
    def submit(run_request) do
      send(test_pid(), {:submit_run, run_request})
      {:ok, "run_discord_dedupe_proof"}
    end

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

  defmodule FakeDiscordApi do
    def create(_channel_id, _params), do: {:ok, %{id: 4444}}
    def edit(_channel_id, message_id, _params), do: {:ok, %{id: message_id}}
    def delete(_channel_id, _message_id), do: {:ok, %{}}

    def react(channel_id, message_id, emoji) do
      send(self(), {:discord_react, channel_id, message_id, emoji})
      {:ok}
    end

    def unreact(_channel_id, _message_id, _emoji), do: {:ok}
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"

  test "ignores messages authored by the bot" do
    state = %{bot_user_id: @bot_user_id}

    message = %{
      "id" => "1503803470493257890",
      "channel_id" => "1475727417372049419",
      "content" => "bot API smoke",
      "author" => %{"id" => "1476753643834183690", "bot" => true}
    }

    assert capture_log(fn ->
             assert {:noreply, ^state} =
                      Transport.handle_info(
                        {:discord_event, {:MESSAGE_CREATE, message, nil}},
                        state
                      )
           end) == ""
  end

  test "ignores webhook messages" do
    state = %{bot_user_id: @bot_user_id}

    message = %{
      "id" => "1503803470493257891",
      "channel_id" => "1475727417372049419",
      "content" => "webhook smoke",
      "webhook_id" => "1503800000000000000",
      "author" => %{"id" => "1476753643834183691", "bot" => false}
    }

    assert capture_log(fn ->
             assert {:noreply, ^state} =
                      Transport.handle_info(
                        {:discord_event, {:MESSAGE_CREATE, message, nil}},
                        state
                      )
           end) == ""
  end

  test "normalizes external bot authors without treating them as self messages" do
    message =
      discord_message(
        "1503803470493257892",
        "<@#{@bot_user_id}> external bot proof",
        1_475_727_417_372_049_419,
        %{"id" => "1476753643834183691", "username" => "proof-bot", "bot" => true}
      )

    assert {:ok, inbound} =
             LemonChannels.Adapters.Discord.Inbound.normalize(%{
               message: message,
               account_id: "default"
             })

    assert inbound.sender.bot == true

    with_discord_api(fn ->
      with_router_bridge(fn ->
        state = discord_message_state()

        assert {:noreply, routed_state} =
                 Transport.handle_info(
                   {:discord_event, {:MESSAGE_CREATE, message, nil}},
                   state
                 )

        assert [{scope_key, buffer}] = Map.to_list(routed_state.buffers)

        assert {:noreply, _flushed_state} =
                 Transport.handle_info(
                   {:debounce_flush, scope_key, buffer.debounce_ref},
                   routed_state
                 )

        assert_receive {:submit_run, run_request}
        assert run_request.prompt == "<@#{@bot_user_id}> external bot proof"
      end)
    end)
  end

  test "indexes allowed Discord message targets for script-send discovery" do
    clear_known_targets()
    on_exit(&clear_known_targets/0)

    channel_id = 1_475_727_417_372_049_419
    thread_id = 1_505_676_123_466_502_334

    message =
      discord_message("1503803470493257893", "index me", thread_id)
      |> Map.put("channel", %{
        "id" => Integer.to_string(thread_id),
        "parent_id" => Integer.to_string(channel_id),
        "name" => "deploys",
        "type" => 11
      })

    state = discord_message_state()

    assert {:noreply, _state} =
             Transport.handle_info({:discord_event, {:MESSAGE_CREATE, message, nil}}, state)

    assert {_, entry} =
             Enum.find(KnownTargetStore.list(), fn {key, _value} ->
               key == {"default", channel_id, thread_id}
             end)

    assert entry.peer_id == Integer.to_string(channel_id)
    assert entry.thread_id == Integer.to_string(thread_id)
    assert entry.thread_name == "deploys"

    clear_known_targets()
  end

  test "exports kanban slash command schema for live registration proof" do
    command = Transport.kanban_command_schema()
    subcommands = Map.new(command.options, &{&1.name, &1})

    assert command.name == "kanban"
    assert command.description == "Manage durable Lemon kanban boards"

    for name <- [
          "boards",
          "create",
          "show",
          "archive",
          "task_create",
          "task_update",
          "comment",
          "dispatch_start",
          "dispatch_status",
          "dispatch_stop"
        ] do
      assert Map.has_key?(subcommands, name)
    end

    assert "kanban" in Enum.map(Transport.slash_commands(), & &1.name)
  end

  test "exports checkpoint slash command schema with gated restore" do
    command = Transport.checkpoint_command_schema()
    subcommands = Map.new(command.options, &{&1.name, &1})

    assert command.name == "checkpoint"
    assert command.description == "Inspect or restore Lemon checkpoints"

    assert Map.has_key?(subcommands, "status")
    assert Map.has_key?(subcommands, "events")
    assert Map.has_key?(subcommands, "diff")
    assert Map.has_key?(subcommands, "restore")

    events_options = Map.new(subcommands["events"].options, &{&1.name, &1})
    diff_options = Map.new(subcommands["diff"].options, &{&1.name, &1})
    restore_options = Map.new(subcommands["restore"].options, &{&1.name, &1})

    assert events_options["limit"].type == 4
    refute events_options["limit"].required
    assert events_options["limit"].max_value == 20
    assert diff_options["checkpoint_id"].required
    assert restore_options["checkpoint_id"].required
    assert restore_options["confirm"].type == 5
    assert restore_options["confirm"].required
    assert "checkpoint" in Enum.map(Transport.slash_commands(), & &1.name)
  end

  test "exports rollback slash command alias with gated restore" do
    command = Transport.rollback_command_schema()
    subcommands = Map.new(command.options, &{&1.name, &1})

    assert command.name == "rollback"
    assert command.description == "Rollback Lemon checkpoint changes"

    assert Map.has_key?(subcommands, "status")
    assert Map.has_key?(subcommands, "events")
    assert Map.has_key?(subcommands, "diff")
    assert Map.has_key?(subcommands, "restore")

    restore_options = Map.new(subcommands["restore"].options, &{&1.name, &1})

    assert restore_options["checkpoint_id"].required
    assert restore_options["confirm"].type == 5
    assert restore_options["confirm"].required
    assert "rollback" in Enum.map(Transport.slash_commands(), & &1.name)
  end

  test "exports media slash command schema" do
    command = Transport.media_command_schema()
    subcommands = Map.new(command.options, &{&1.name, &1})

    assert command.name == "media"
    assert command.description == "Inspect redacted Lemon media jobs"
    assert Map.has_key?(subcommands, "status")
    assert subcommands["status"].description == "Show redacted media job status"
    assert "media" in Enum.map(Transport.slash_commands(), & &1.name)
  end

  test "decodes checkpoint slash command interactions through the runtime path" do
    assert {:ok, %{command: "checkpoint", args: "events 5"}} =
             Transport.slash_command_args_for_interaction(
               interaction("checkpoint", subcommand("events", limit: 5))
             )

    assert {:ok, %{command: "checkpoint", args: "restore chk_123 confirm"}} =
             Transport.slash_command_args_for_interaction(
               interaction(
                 "checkpoint",
                 subcommand("restore", checkpoint_id: "chk_123", confirm: true)
               )
             )

    assert {:ok, %{command: "rollback", args: "restore chk_123 confirm"}} =
             Transport.slash_command_args_for_interaction(
               interaction(
                 "rollback",
                 subcommand("restore", checkpoint_id: "chk_123", confirm: true)
               )
             )
  end

  test "decodes kanban slash command interactions through the runtime path" do
    assert {:ok, %{command: "kanban", args: args}} =
             Transport.slash_command_args_for_interaction(
               interaction(
                 "kanban",
                 subcommand("task_create",
                   board_id: "board_1",
                   priority: "high",
                   assignee: "alice",
                   worker_profile: "builder",
                   title: "ship Discord proof"
                 )
               )
             )

    assert args ==
             "task create board_1 --priority high --assignee alice --worker-profile builder ship Discord proof"

    assert {:ok, %{command: "kanban", args: "dispatch start board_1 --max-concurrency 3"}} =
             Transport.slash_command_args_for_interaction(
               interaction(
                 "kanban",
                 subcommand("dispatch_start", board_id: "board_1", max_concurrency: 3)
               )
             )
  end

  test "client-click media interaction returns an ephemeral response" do
    parent = self()

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:lemon_channels, :discord_interaction_responder) end)

    interaction = interaction("media", subcommand("status"))
    state = %{}

    assert {:noreply, ^state} =
             Transport.handle_info(
               {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
               state
             )

    assert_receive {:interaction_response, ^interaction,
                    %{
                      type: 4,
                      data: %{
                        content: content,
                        flags: 64,
                        allowed_mentions: %{parse: [], replied_user: false}
                      }
                    }}

    assert is_binary(content)
    assert content != ""
  end

  test "real slash interactions write redacted client-click proof" do
    proof_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(proof_dir) end)

    Application.put_env(:lemon_channels, :discord_client_click_proof_dir, proof_dir)

    on_exit(fn ->
      Application.delete_env(:lemon_channels, :discord_client_click_proof_dir)
    end)

    with_interaction_responder(fn ->
      synthetic = interaction("media", subcommand("status"))

      assert {:noreply, %{}} =
               Transport.handle_info(
                 {:discord_event, {:INTERACTION_CREATE, synthetic, nil}},
                 %{}
               )

      refute File.exists?(Path.join(proof_dir, "discord-slash-client-click-proof-latest.json"))

      clicked =
        interaction("media", subcommand("status"), %{
          application_id: "1500000000000000000",
          token: "private-interaction-token"
        })

      assert {:noreply, %{}} =
               Transport.handle_info(
                 {:discord_event, {:INTERACTION_CREATE, clicked, nil}},
                 %{}
               )

      proof_path = Path.join(proof_dir, "discord-slash-client-click-proof-latest.json")
      assert File.exists?(proof_path)

      proof = proof_path |> File.read!() |> Jason.decode!()
      assert proof["proof_object"] == "lemon.discord_slash_client_click"
      assert proof["proof_scope"] == "discord_slash_client_click_observed"
      assert proof["status"] == "completed"
      assert proof["coverage"]["registered_command_count"] == 16
      assert proof["coverage"]["client_click_command_count"] == 1
      assert proof["coverage"]["real_client_click_proof"] == true
      assert proof["details"]["command"] == "media"
      assert proof["details"]["live_fields"]["application_id_present"] == true
      assert proof["details"]["live_fields"]["token_present"] == true
      assert proof["details"]["safe_mentions_disabled"] == true
      assert Enum.any?(proof["checks"], &(&1["name"] == "discord_slash_client_click_observed"))

      proof_text = inspect(proof)
      refute proof_text =~ "private-interaction-token"
      refute proof_text =~ "1500000000000000000"
      refute proof_text =~ "1475727417372049419"
      refute proof_text =~ "1476753643834183691"
    end)
  end

  test "approval component resolves a pending approval through the runtime path" do
    parent = self()

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:lemon_channels, :discord_interaction_responder) end)

    task =
      Task.async(fn ->
        LemonCore.ExecApprovals.request(%{
          run_id: "run_discord_approval",
          session_key: "agent:test:main",
          tool: "bash",
          action: %{command: "touch proof"},
          expires_in_ms: 5_000
        })
      end)

    pending =
      eventually(fn ->
        LemonCore.Store.list(:exec_approvals_pending)
        |> Enum.find_value(fn {_key, pending} ->
          if pending.run_id == "run_discord_approval", do: pending, else: nil
        end)
      end)

    interaction = component_interaction("#{pending.id}|once")
    state = %{}

    assert {:noreply, ^state} =
             Transport.handle_info(
               {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
               state
             )

    assert {:ok, :approved, :approve_once} = Task.await(task, 1_000)

    assert_receive {:interaction_response, ^interaction,
                    %{
                      type: 7,
                      data: %{
                        content: "Approval: Approved (once)",
                        components: [],
                        allowed_mentions: %{parse: [], replied_user: false}
                      }
                    }}
  end

  test "cancel component aborts the run through the runtime path" do
    with_interaction_responder(fn ->
      with_router_bridge(fn ->
        interaction = component_interaction("lemon:cancel:run_cancel_proof")
        state = %{}

        assert {:noreply, ^state} =
                 Transport.handle_info(
                   {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
                   state
                 )

        assert_receive {:abort_run, "run_cancel_proof", :user_requested}

        assert_receive {:interaction_response, ^interaction,
                        %{
                          type: 7,
                          data: %{
                            content: "Cancelling...",
                            components: [],
                            allowed_mentions: %{parse: [], replied_user: false}
                          }
                        }}
      end)
    end)
  end

  test "keepalive components route continue and stop decisions" do
    with_interaction_responder(fn ->
      with_router_bridge(fn ->
        continue_interaction = component_interaction("lemon:idle:c:run_keepalive_proof")
        cancel_interaction = component_interaction("lemon:idle:k:run_keepalive_proof")
        state = %{}

        assert {:noreply, ^state} =
                 Transport.handle_info(
                   {:discord_event, {:INTERACTION_CREATE, continue_interaction, nil}},
                   state
                 )

        assert_receive {:keep_run_alive, "run_keepalive_proof", :continue}

        assert_receive {:interaction_response, ^continue_interaction,
                        %{type: 7, data: %{content: "Continuing run."}}}

        assert {:noreply, ^state} =
                 Transport.handle_info(
                   {:discord_event, {:INTERACTION_CREATE, cancel_interaction, nil}},
                   state
                 )

        assert_receive {:keep_run_alive, "run_keepalive_proof", :cancel}

        assert_receive {:interaction_response, ^cancel_interaction,
                        %{type: 7, data: %{content: "Stopping run."}}}
      end)
    end)
  end

  test "duplicate message create events submit only one run through the runtime path" do
    :ok = LemonCore.Dedupe.Ets.init(:lemon_channels_discord_dedupe)
    _ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

    with_discord_api(fn ->
      with_router_bridge(fn ->
        state = discord_message_state()
        message_id = 1_503_803_470_493_259_000 + System.unique_integer([:positive])

        message =
          discord_message(Integer.to_string(message_id), "<@#{@bot_user_id}> dedupe proof")

        assert {:noreply, state_after_first} =
                 Transport.handle_info(
                   {:discord_event, {:MESSAGE_CREATE, message, nil}},
                   state
                 )

        assert [{scope_key, buffer}] = Map.to_list(state_after_first.buffers)

        assert {:noreply, state_after_duplicate} =
                 Transport.handle_info(
                   {:discord_event, {:MESSAGE_CREATE, message, nil}},
                   state_after_first
                 )

        assert state_after_duplicate.buffers == state_after_first.buffers

        assert {:noreply, state_after_flush} =
                 Transport.handle_info(
                   {:debounce_flush, scope_key, buffer.debounce_ref},
                   state_after_duplicate
                 )

        assert_receive {:submit_run, run_request}
        assert run_request.origin == :channel
        assert run_request.prompt == "<@#{@bot_user_id}> dedupe proof"
        assert run_request.meta.user_msg_id == message_id
        assert_receive {:discord_react, 1_475_727_417_372_049_419, ^message_id, _}

        _ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

        assert {:noreply, _state_after_restart_replay} =
                 Transport.handle_info(
                   {:discord_event, {:MESSAGE_CREATE, message, nil}},
                   state_after_flush
                 )

        refute_receive {:submit_run, _}, 100
      end)
    end)
  end

  test "trigger all routes unmentioned group messages through the runtime path" do
    :ok = LemonCore.Dedupe.Ets.init(:lemon_channels_discord_dedupe)
    _ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

    with_interaction_responder(fn ->
      with_discord_api(fn ->
        with_router_bridge(fn ->
          channel_id = 1_475_727_417_372_049_419 + System.unique_integer([:positive])
          state = discord_message_state()

          ignored_message =
            discord_message(
              Integer.to_string(1_503_803_470_493_270_000 + System.unique_integer([:positive])),
              "free response should wait for trigger all",
              channel_id
            )

          assert {:noreply, ignored_state} =
                   Transport.handle_info(
                     {:discord_event, {:MESSAGE_CREATE, ignored_message, nil}},
                     state
                   )

          assert ignored_state.buffers == %{}
          refute_receive {:submit_run, _}, 100

          trigger_interaction =
            interaction("trigger", option("mode", "all"), %{
              channel_id: Integer.to_string(channel_id)
            })

          assert {:noreply, ^ignored_state} =
                   Transport.handle_info(
                     {:discord_event, {:INTERACTION_CREATE, trigger_interaction, nil}},
                     ignored_state
                   )

          assert_receive {:interaction_response, ^trigger_interaction,
                          %{
                            type: 4,
                            data: %{
                              content: "Trigger mode set to **all** for this channel.",
                              flags: 64,
                              allowed_mentions: %{parse: [], replied_user: false}
                            }
                          }}

          message_id = 1_503_803_470_493_280_000 + System.unique_integer([:positive])

          free_message =
            discord_message(Integer.to_string(message_id), "free response now routes", channel_id)

          assert {:noreply, routed_state} =
                   Transport.handle_info(
                     {:discord_event, {:MESSAGE_CREATE, free_message, nil}},
                     ignored_state
                   )

          assert [{scope_key, buffer}] = Map.to_list(routed_state.buffers)

          assert {:noreply, flushed_state} =
                   Transport.handle_info(
                     {:debounce_flush, scope_key, buffer.debounce_ref},
                     routed_state
                   )

          assert_receive {:submit_run, run_request}
          assert run_request.origin == :channel
          assert run_request.prompt == "free response now routes"
          assert run_request.meta.user_msg_id == message_id
          assert_receive {:discord_react, ^channel_id, ^message_id, _}

          trigger_mentions_interaction =
            interaction("trigger", option("mode", "mentions"), %{
              channel_id: Integer.to_string(channel_id)
            })

          assert {:noreply, ^flushed_state} =
                   Transport.handle_info(
                     {:discord_event, {:INTERACTION_CREATE, trigger_mentions_interaction, nil}},
                     flushed_state
                   )

          assert_receive {:interaction_response, ^trigger_mentions_interaction,
                          %{
                            type: 4,
                            data: %{
                              content: "Trigger mode set to **mentions** for this channel.",
                              flags: 64,
                              allowed_mentions: %{parse: [], replied_user: false}
                            }
                          }}

          suppressed_message =
            discord_message(
              Integer.to_string(1_503_803_470_493_290_000 + System.unique_integer([:positive])),
              "mentions mode should suppress this",
              channel_id
            )

          assert {:noreply, suppressed_state} =
                   Transport.handle_info(
                     {:discord_event, {:MESSAGE_CREATE, suppressed_message, nil}},
                     flushed_state
                   )

          assert suppressed_state.buffers == %{}
          refute_receive {:submit_run, _}, 100
        end)
      end)
    end)
  end

  test "trigger all routes thread messages when Discord omits parent channel context" do
    :ok = LemonCore.Dedupe.Ets.init(:lemon_channels_discord_dedupe)
    _ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

    with_discord_api(fn ->
      with_router_bridge(fn ->
        parent_channel_id = 1_475_727_417_372_049_419 + System.unique_integer([:positive])
        thread_id = 1_505_676_123_466_502_334 + System.unique_integer([:positive])

        scope = %LemonCore.ChatScope{
          transport: :discord,
          chat_id: thread_id,
          topic_id: thread_id
        }

        :ok = LemonChannels.Adapters.Discord.TriggerMode.set(scope, "default", :all)

        state = discord_message_state()
        message_id = 1_503_803_470_493_300_000 + System.unique_integer([:positive])

        message =
          discord_message(
            Integer.to_string(message_id),
            "thread free response now routes",
            thread_id
          )

        assert {:noreply, routed_state} =
                 Transport.handle_info(
                   {:discord_event, {:MESSAGE_CREATE, message, nil}},
                   state
                 )

        assert [{scope_key, buffer}] = Map.to_list(routed_state.buffers)

        assert {:noreply, _flushed_state} =
                 Transport.handle_info(
                   {:debounce_flush, scope_key, buffer.debounce_ref},
                   routed_state
                 )

        assert_receive {:submit_run, run_request}
        assert run_request.origin == :channel
        assert run_request.prompt == "thread free response now routes"
        assert_receive {:discord_react, ^thread_id, ^message_id, _}

        :ok =
          LemonChannels.Adapters.Discord.TriggerMode.clear_topic(
            "default",
            thread_id,
            thread_id
          )

        refute run_request.meta.channel_id == parent_channel_id
      end)
    end)
  end

  test "pushes redacted checkpoint event notices for tracked sessions" do
    parent = self()

    state = %{
      reaction_runs: %{
        "session:checkpoint" => %{channel_id: 123, thread_id: 456}
      },
      checkpoint_event_sender: fn channel_id, text ->
        send(parent, {:checkpoint_notice, channel_id, text})
        :ok
      end
    }

    event = %LemonCore.Event{
      type: :checkpoint_created,
      ts_ms: System.system_time(:millisecond),
      payload: %{
        checkpoint_id: "chk_push",
        path_count: 1,
        paths: ["/private/file.ex"],
        content: "secret"
      },
      meta: %{session_key: "session:checkpoint"}
    }

    assert {:noreply, returned} = Transport.handle_info(event, state)
    assert returned == state
    assert_receive {:checkpoint_notice, 456, "Checkpoint Event\ncreated chk_push (1 paths)"}
  end

  defp interaction(name, options, overrides \\ %{}) do
    Map.merge(
      %{
        type: 2,
        id: "1503803470493257999",
        channel_id: "1475727417372049419",
        guild_id: "1475727417372049000",
        data: %{name: name, options: List.wrap(options)},
        member: %{user: %{id: "1476753643834183691"}}
      },
      overrides
    )
  end

  defp option(name, value) do
    %{name: name, value: value}
  end

  defp subcommand(name, opts \\ []) do
    %{
      type: 1,
      name: name,
      options:
        Enum.map(opts, fn {key, value} ->
          %{name: Atom.to_string(key), value: value}
        end)
    }
  end

  defp component_interaction(custom_id) do
    %{
      type: 3,
      id: "1503803470493258000",
      channel_id: "1475727417372049419",
      guild_id: "1475727417372049000",
      data: %{custom_id: custom_id},
      member: %{user: %{id: "1476753643834183691"}}
    }
  end

  defp discord_message_state do
    %{
      account_id: "default",
      bot_user_id: @bot_user_id,
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
  end

  defp discord_message(
         id,
         content,
         channel_id \\ 1_475_727_417_372_049_419,
         author \\ %{"id" => "1476753643834183691", "bot" => false}
       ) do
    %{
      "id" => id,
      "channel_id" => Integer.to_string(channel_id),
      "guild_id" => "1475727416549969980",
      "content" => content,
      "author" => author
    }
  end

  defp clear_known_targets do
    KnownTargetStore.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(:discord_known_targets, key)
    end)
  end

  defp with_interaction_responder(fun) do
    parent = self()

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    try do
      fun.()
    after
      Application.delete_env(:lemon_channels, :discord_interaction_responder)
    end
  end

  defp with_router_bridge(fun) do
    previous = Application.get_env(:lemon_core, :router_bridge)
    :persistent_term.put({FakeRouter, :test_pid}, self())
    :ok = LemonCore.RouterBridge.configure(router: FakeRouter, run_orchestrator: FakeRouter)

    try do
      fun.()
    after
      :persistent_term.erase({FakeRouter, :test_pid})

      if previous == nil do
        Application.delete_env(:lemon_core, :router_bridge)
      else
        Application.put_env(:lemon_core, :router_bridge, previous)
      end
    end
  end

  defp with_discord_api(fun) do
    previous = Application.get_env(:lemon_gateway, @gateway_config_key)
    previous_test_mode = Application.get_env(:lemon_core, :config_test_mode)

    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_discord: true,
      discord: %{api_mod: FakeDiscordApi}
    })

    try do
      fun.()
    after
      restore_env(:lemon_core, :config_test_mode, previous_test_mode)
      restore_env(:lemon_gateway, @gateway_config_key, previous)
    end
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_discord_transport_test_#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(_fun, 0), do: flunk("condition was not met")
end
