defmodule LemonChannels.Adapters.Discord.TransportCommandAuthorityTest do
  @moduledoc """
  Owner authority and target binding for Discord slash commands and message
  components, driven through `Transport.process_event/2`.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Transport
  alias LemonChannels.Adapters.Discord.TriggerMode

  @channel_id 1_475_727_417_372_049_419
  @guild_id 1_475_727_417_372_049_000
  @user_id 1_476_753_643_834_183_691

  # Discord permission bits (https://discord.com/developers/docs/topics/permissions).
  @manage_guild "32"
  @send_messages "2048"

  setup do
    start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Discord.AsyncSupervisor})
    parent = self()

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    on_exit(fn -> Application.delete_env(:lemon_channels, :discord_interaction_responder) end)
    :ok
  end

  describe "adminOnly slash commands" do
    test "a guild member without Manage Server cannot change the trigger mode" do
      channel_id = unique_channel()
      interaction = slash("trigger", [option("mode", "all")], channel_id, @send_messages)

      process(interaction)

      assert_receive {:interaction_response, ^interaction, %{data: %{content: content}}}
      assert content =~ "Only the bot owner"
      assert TriggerMode.resolve("default", channel_id, nil).chat_mode == nil
    end

    test "a member with Manage Server keeps changing the trigger mode" do
      channel_id = unique_channel()
      interaction = slash("trigger", [option("mode", "all")], channel_id, @manage_guild)

      process(interaction)

      assert_receive {:interaction_response, ^interaction, %{data: %{content: content}}}
      assert content =~ "Trigger mode set to **all**"
      assert TriggerMode.resolve("default", channel_id, nil).chat_mode == :all
    end

    test "/reload is no longer registered or dispatched" do
      refute "reload" in Enum.map(Transport.slash_commands(), & &1.name)
      refute "reload" in Enum.map(LemonChannels.CommandCatalog.catalog("discord"), & &1["name"])

      interaction = slash("reload", [], unique_channel(), @manage_guild)
      process(interaction)

      assert_receive {:interaction_response, ^interaction, %{data: %{content: "Unknown command"}}}
    end
  end

  describe "checkpoint slash schema" do
    test "restore takes an optional preview token instead of a confirm flag" do
      restore =
        Transport.checkpoint_command_schema().options
        |> Enum.find(&(&1.name == "restore"))

      options = Map.new(restore.options, &{&1.name, &1})
      refute Map.has_key?(options, "confirm")
      assert options["token"].type == 3
      refute options["token"].required

      assert {:ok, %{args: "restore chk_0123456789abcdef"}} =
               Transport.slash_command_args_for_interaction(
                 slash(
                   "checkpoint",
                   [subcommand("restore", checkpoint_id: "chk_0123456789abcdef")],
                   @channel_id,
                   @send_messages
                 )
               )

      assert {:ok, %{args: "restore chk_0123456789abcdef 0011223344556677"}} =
               Transport.slash_command_args_for_interaction(
                 slash(
                   "rollback",
                   [
                     subcommand("restore",
                       checkpoint_id: "chk_0123456789abcdef",
                       token: "0011223344556677"
                     )
                   ],
                   @channel_id,
                   @send_messages
                 )
               )
    end
  end

  describe "/checkpoint restore" do
    @tag :tmp_dir
    test "binds to the invoking user's session and needs the preview token", %{tmp_dir: tmp_dir} do
      channel_id = unique_channel()
      native = "native-discord-#{System.unique_integer([:positive])}"
      foreign = "native-discord-foreign-#{System.unique_integer([:positive])}"
      seed_native_session(user_session_key(channel_id, @user_id), native)

      path = Path.join(tmp_dir, "owned.txt")
      foreign_path = Path.join(tmp_dir, "foreign.txt")
      File.write!(path, "before\n")
      File.write!(foreign_path, "foreign-before\n")

      on_exit(fn ->
        LemonAgent.Checkpoint.delete_all(native)
        LemonAgent.Checkpoint.delete_all(foreign)
      end)

      {:ok, own} = LemonAgent.Checkpoint.create_filesystem(native, [path], cwd: tmp_dir)

      {:ok, other} =
        LemonAgent.Checkpoint.create_filesystem(foreign, [foreign_path], cwd: tmp_dir)

      File.write!(path, "after\n")
      File.write!(foreign_path, "foreign-after\n")

      foreign_restore = restore_interaction(channel_id, other.id, nil)
      process(foreign_restore)
      assert_receive {:interaction_response, ^foreign_restore, %{data: %{content: text}}}
      assert text == "Checkpoint not found in this chat's session: #{other.id}"

      preview = restore_interaction(channel_id, own.id, nil)
      process(preview)
      assert_receive {:interaction_response, ^preview, %{data: %{content: preview_text}}}
      assert [_, token] = Regex.run(~r/restore #{own.id} ([A-Za-z0-9_-]{32,})/, preview_text)
      assert File.read!(path) == "after\n"

      # Another guild member in the same channel has a different session.
      stranger = restore_interaction(channel_id, own.id, token, @user_id + 1)
      process(stranger)
      assert_receive {:interaction_response, ^stranger, %{data: %{content: stranger_text}}}
      assert stranger_text =~ "not found in this chat's session"
      assert File.read!(path) == "after\n"

      confirm = restore_interaction(channel_id, own.id, token)
      process(confirm)
      assert_receive {:interaction_response, ^confirm, %{data: %{content: restored}}}
      assert restored =~ "Checkpoint Restored"
      assert File.read!(path) == "before\n"
      assert File.read!(foreign_path) == "foreign-after\n"
    end
  end

  defp restore_interaction(channel_id, checkpoint_id, token, user_id \\ @user_id) do
    opts =
      if token,
        do: [checkpoint_id: checkpoint_id, token: token],
        else: [checkpoint_id: checkpoint_id]

    "checkpoint"
    |> slash([subcommand("restore", opts)], channel_id, @send_messages)
    |> put_in([:member, :user, :id], Integer.to_string(user_id))
  end

  defp user_session_key(channel_id, user_id) do
    LemonCore.SessionKey.channel_peer(%{
      agent_id:
        LemonChannels.BindingResolver.resolve_agent_id(%LemonCore.ChatScope{
          transport: :discord,
          chat_id: channel_id,
          topic_id: nil
        }),
      channel_id: "discord",
      account_id: "default",
      peer_kind: :group,
      peer_id: Integer.to_string(channel_id),
      thread_id: nil,
      sub_id: Integer.to_string(user_id)
    })
  end

  # The router binds a native session to the session that created it; history
  # alone never makes a session the checkpoint owner.
  defp seed_native_session(session_key, native_id) do
    run_id = "run_#{System.unique_integer([:positive])}"
    resume = %LemonCore.ResumeToken{engine: "lemon", value: native_id}
    assert :ok = LemonCore.NativeSessionOwner.bind(resume, session_key)

    assert :ok =
             LemonCore.RunStore.finalize(run_id, %{
               session_key: session_key,
               completed: %{ok: true, resume: resume}
             })

    wait_until(fn -> LemonCore.RunStore.history(session_key, limit: 1) != [] end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  defp process(interaction) do
    state = state()

    assert {:noreply, _} =
             Transport.process_event(
               {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
               state
             )
  end

  defp state do
    %{
      account_id: "default",
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
  end

  defp unique_channel, do: @channel_id + System.unique_integer([:positive])

  defp slash(name, options, channel_id, permissions) do
    %{
      type: 2,
      id: Integer.to_string(1_503_803_470_493_257_999 + System.unique_integer([:positive])),
      channel_id: Integer.to_string(channel_id),
      guild_id: Integer.to_string(@guild_id),
      channel: %{id: Integer.to_string(channel_id), type: 0},
      data: %{name: name, options: options},
      member: %{user: %{id: Integer.to_string(@user_id)}, permissions: permissions}
    }
  end

  defp option(name, value), do: %{name: name, value: value}

  defp subcommand(name, opts) do
    %{
      type: 1,
      name: name,
      options: Enum.map(opts, fn {key, value} -> %{name: Atom.to_string(key), value: value} end)
    }
  end
end
