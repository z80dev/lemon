defmodule LemonChannels.ScriptSendTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Discord.KnownTargetStore, as: DiscordKnownTargetStore
  alias LemonChannels.ScriptSend
  alias LemonChannels.Telegram.KnownTargetStore, as: TelegramKnownTargetStore
  alias LemonCore.Store

  defmodule TelegramDeliverer do
    def deliver(payload) do
      send(Application.fetch_env!(:lemon_channels, :script_send_test_pid), {:delivered, payload})
      {:ok, %{"result" => %{"message_id" => 123}}}
    end
  end

  defmodule TelegramBatchDeliverer do
    def deliver(payload) do
      send(Application.fetch_env!(:lemon_channels, :script_send_test_pid), {:delivered, payload})
      {:ok, [%{"result" => %{"message_id" => 123}}, %{"message_id" => 124}]}
    end
  end

  defmodule DiscordDeliverer do
    def deliver(payload) do
      send(Application.fetch_env!(:lemon_channels, :script_send_test_pid), {:delivered, payload})
      {:ok, %{message_id: "dc-1"}}
    end
  end

  setup do
    Application.put_env(:lemon_channels, :script_send_test_pid, self())
    old_gateway_config = Application.get_env(:lemon_gateway, LemonGateway.Config)
    clear_known_targets()

    on_exit(fn ->
      Application.delete_env(:lemon_channels, :script_send_test_pid)

      if is_nil(old_gateway_config) do
        Application.delete_env(:lemon_gateway, LemonGateway.Config)
      else
        Application.put_env(:lemon_gateway, LemonGateway.Config, old_gateway_config)
      end

      clear_known_targets()
    end)

    :ok
  end

  test "parses explicit Telegram target with thread" do
    assert {:ok, parsed} =
             ScriptSend.parse_args([
               "--to",
               "telegram:-100123:456",
               "--subject",
               "[deploy]",
               "done"
             ])

    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: "456"}
    assert parsed.subject == "[deploy]"
    assert parsed.body_args == ["done"]
  end

  test "parses standalone thread and topic target options" do
    assert {:ok, parsed} =
             ScriptSend.parse_args([
               "--to",
               "discord:123456",
               "--thread",
               "789",
               "done"
             ])

    assert parsed.target == %{platform: "discord", id: "123456", thread_id: "789"}

    assert {:ok, parsed} =
             ScriptSend.parse_args([
               "--to",
               "telegram:-100123",
               "--topic",
               "789",
               "done"
             ])

    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: "789"}
  end

  test "rejects conflicting thread target options" do
    assert {:error, :conflicting_thread_target} =
             ScriptSend.parse_args([
               "--to",
               "discord:123456:789",
               "--thread",
               "999",
               "done"
             ])

    assert {:error, :conflicting_thread_options} =
             ScriptSend.parse_args([
               "--to",
               "telegram:-100123",
               "--thread",
               "789",
               "--topic",
               "deploys",
               "done"
             ])
  end

  test "rejects empty reply target" do
    assert {:error, :missing_reply_to} =
             ScriptSend.parse_args(["--to", "discord:123456789", "--reply-to", " ", "done"])
  end

  test "parses default targets from environment" do
    env = %{
      "LEMON_TELEGRAM_DEFAULT_CHAT_ID" => "-100123",
      "LEMON_TELEGRAM_DEFAULT_THREAD_ID" => "99"
    }

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram", "body"], env)
    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: "99"}
  end

  test "parses default targets from gateway config" do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      telegram: %{default_account_id: "tg-work", default_chat_id: -100_123, default_thread_id: 77},
      discord: %{
        default_account_id: "dc-work",
        default_channel_id: "123456",
        default_thread_id: 789
      }
    })

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram", "body"], %{})
    assert parsed.account_id == "tg-work"
    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: "77"}

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "discord", "body"], %{})
    assert parsed.account_id == "dc-work"
    assert parsed.target == %{platform: "discord", id: "123456", thread_id: "789"}
  end

  test "environment default targets and accounts take precedence over gateway config" do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      telegram: %{default_account_id: "config", default_chat_id: -100_123, default_thread_id: 77}
    })

    env = %{
      "LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID" => "env",
      "LEMON_TELEGRAM_DEFAULT_CHAT_ID" => "-999",
      "LEMON_TELEGRAM_DEFAULT_THREAD_ID" => "11"
    }

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram", "body"], env)
    assert parsed.account_id == "env"
    assert parsed.target == %{platform: "telegram", id: "-999", thread_id: "11"}
  end

  test "default account scopes known-name resolution" do
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      discord: %{default_account_id: "work"}
    })

    :ok =
      DiscordKnownTargetStore.put({"default", 123_456, nil}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "123456",
        channel_name: "ops",
        updated_at_ms: 200
      })

    :ok =
      DiscordKnownTargetStore.put({"work", 999_999, nil}, %{
        channel_id: "discord",
        account_id: "work",
        peer_kind: "group",
        peer_id: "999999",
        channel_name: "ops",
        updated_at_ms: 300
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "discord:#ops", "green"])
    assert parsed.account_id == "work"
    assert parsed.target == %{platform: "discord", id: "999999", thread_id: nil}
  end

  test "rejects unsupported platforms" do
    assert {:error, {:unsupported_platform, "slack"}} =
             ScriptSend.parse_args(["--to", "slack:C1", "body"])
  end

  test "resolves body from positional args before file or stdin" do
    parsed = %{
      list: false,
      body_args: ["deploy", "finished"],
      file: "/no/such/file",
      subject: "[ci]"
    }

    assert ScriptSend.resolve_body(parsed,
             stdin_available?: true,
             stdin_reader: fn -> "stdin" end
           ) ==
             {:ok, "[ci]\n\ndeploy finished"}
  end

  test "resolves body from file" do
    path =
      Path.join(System.tmp_dir!(), "lemon-script-send-#{System.unique_integer([:positive])}.txt")

    File.write!(path, "file body")

    on_exit(fn -> File.rm(path) end)

    parsed = %{list: false, body_args: [], file: path, subject: nil}

    assert ScriptSend.resolve_body(parsed, stdin_available?: false) == {:ok, "file body"}
  end

  test "resolves body from forced stdin file marker" do
    parsed = %{list: false, body_args: [], file: "-", subject: "report"}

    assert ScriptSend.resolve_body(parsed, stdin_reader: fn -> "stdin body" end) ==
             {:ok, "report\n\nstdin body"}
  end

  test "resolves body from noninteractive stdin" do
    parsed = %{list: false, body_args: [], file: nil, subject: nil}

    assert ScriptSend.resolve_body(parsed,
             stdin_available?: true,
             stdin_reader: fn -> "from stdin" end
           ) ==
             {:ok, "from stdin"}
  end

  test "builds and delivers Telegram payload" do
    assert {:ok, result} =
             ScriptSend.run(["--to", "telegram:-100123:77", "--subject", "[ci]", "green"],
               telegram_deliverer: TelegramDeliverer,
               stdin_available?: false
             )

    assert result.platform == "telegram"
    assert result.target == "-100123"
    assert result.thread_id == "77"
    assert result.content_bytes == byte_size("[ci]\n\ngreen")
    assert result.message_id == 123
    assert result.extra_message_ids == []

    assert_receive {:delivered, payload}
    assert payload.channel_id == "telegram"
    assert payload.account_id == "script"
    assert payload.peer == %{kind: :channel, id: "-100123", thread_id: "77"}
    assert payload.kind == :text
    assert payload.content == "[ci]\n\ngreen"
    assert payload.meta == %{source: "lemon.send", subject: "[ci]"}
  end

  test "builds and delivers payload with explicit channel account" do
    assert {:ok, result} =
             ScriptSend.run(["--account", "work", "--to", "telegram:-100123:77", "green"],
               telegram_deliverer: TelegramDeliverer,
               stdin_available?: false
             )

    assert result.account_id == "work"

    assert_receive {:delivered, payload}
    assert payload.account_id == "work"
    assert payload.peer == %{kind: :channel, id: "-100123", thread_id: "77"}
  end

  test "builds and delivers payload with reply target" do
    assert {:ok, result} =
             ScriptSend.run(["--to", "discord:123456789", "--reply-to", "777", "green"],
               discord_deliverer: DiscordDeliverer,
               stdin_available?: false
             )

    assert result.reply_to == "777"

    assert_receive {:delivered, payload}
    assert payload.reply_to == "777"
    assert payload.peer == %{kind: :channel, id: "123456789", thread_id: nil}
  end

  test "builds and delivers Discord payload" do
    assert {:ok, result} =
             ScriptSend.run(["--to", "discord:123456789", "green"],
               discord_deliverer: DiscordDeliverer,
               stdin_available?: false
             )

    assert result.platform == "discord"
    assert result.target == "123456789"
    assert result.thread_id == nil
    assert result.message_id == "dc-1"
    assert result.extra_message_ids == []

    assert_receive {:delivered, payload}
    assert payload.channel_id == "discord"
    assert payload.peer == %{kind: :channel, id: "123456789", thread_id: nil}
    assert payload.content == "green"
  end

  test "builds and delivers Telegram attachment payload" do
    path = temp_file!("telegram-script-send-attachment", "artifact")

    assert {:ok, result} =
             ScriptSend.run(["--to", "telegram:-100123", "--attach", path, "artifact ready"],
               telegram_deliverer: TelegramDeliverer,
               stdin_available?: false
             )

    assert result.platform == "telegram"
    assert result.target == "-100123"
    assert result.content_bytes == byte_size("artifact ready")
    assert result.attachment_filename == Path.basename(path)
    assert result.attachment_bytes == byte_size("artifact")

    assert_receive {:delivered, payload}
    assert payload.channel_id == "telegram"
    assert payload.kind == :file

    assert payload.content == %{
             path: path,
             filename: Path.basename(path),
             caption: "artifact ready"
           }
  end

  test "builds and delivers Discord attachment payload with optional caption" do
    path = temp_file!("discord-script-send-attachment", "artifact")

    assert {:ok, result} =
             ScriptSend.run(["--to", "discord:123456789", "--attach", path],
               discord_deliverer: DiscordDeliverer,
               stdin_available?: false
             )

    assert result.platform == "discord"
    assert result.target == "123456789"
    assert result.content_bytes == 0
    assert result.attachment_filename == Path.basename(path)
    assert result.attachment_bytes == byte_size("artifact")

    assert_receive {:delivered, payload}
    assert payload.channel_id == "discord"
    assert payload.kind == :file
    assert payload.content == %{path: path, filename: Path.basename(path), caption: nil}
  end

  test "builds and delivers multiple Discord attachment payloads" do
    first = temp_file!("discord-script-send-first", "one")
    second = temp_file!("discord-script-send-second", "two")

    assert {:ok, result} =
             ScriptSend.run(
               [
                 "--to",
                 "discord:123456789",
                 "--attach",
                 first,
                 "--attach",
                 second,
                 "bundle ready"
               ],
               discord_deliverer: DiscordDeliverer,
               stdin_available?: false
             )

    assert result.platform == "discord"
    assert result.target == "123456789"
    assert result.content_bytes == byte_size("bundle ready")
    assert result.attachment_filename == Path.basename(first)
    assert result.attachment_filenames == [Path.basename(first), Path.basename(second)]
    assert result.attachment_count == 2
    assert result.attachment_bytes == byte_size("one") + byte_size("two")

    assert_receive {:delivered, payload}
    assert payload.channel_id == "discord"
    assert payload.kind == :file

    assert payload.content == %{
             files: [
               %{path: first, filename: Path.basename(first), caption: "bundle ready"},
               %{path: second, filename: Path.basename(second), caption: nil}
             ],
             caption: "bundle ready"
           }
  end

  test "preserves Telegram batch attachment message ids" do
    first = temp_file!("telegram-script-send-first", "one")
    second = temp_file!("telegram-script-send-second", "two")

    assert {:ok, result} =
             ScriptSend.run(
               [
                 "--to",
                 "telegram:-100123",
                 "--attach",
                 first,
                 "--attach",
                 second,
                 "bundle ready"
               ],
               telegram_deliverer: TelegramBatchDeliverer,
               stdin_available?: false
             )

    assert result.message_id == 123
    assert result.extra_message_ids == [124]
    assert result.attachment_filenames == [Path.basename(first), Path.basename(second)]
    assert result.attachment_count == 2

    assert_receive {:delivered, payload}
    assert payload.channel_id == "telegram"
    assert payload.kind == :file
    assert [%{caption: "bundle ready"}, %{caption: nil}] = payload.content.files
  end

  test "dry run validates attachment payload without delivery" do
    path = temp_file!("discord-script-send-dry-run", "artifact")

    assert {:ok, result} =
             ScriptSend.run(
               ["--dry-run", "--to", "discord:123456789", "--attach", path, "artifact ready"],
               discord_deliverer: DiscordDeliverer,
               stdin_available?: false
             )

    assert result.dry_run
    assert result.platform == "discord"
    assert result.target == "123456789"
    assert result.attachment_filename == Path.basename(path)
    assert result.attachment_count == 1
    assert result.delivery == %{dry_run: true, channel_id: "discord", kind: :file}
    refute_receive {:delivered, _payload}
  end

  test "rejects missing or too many attachment paths" do
    assert {:error, {:attachment_not_found, "/no/such/file"}} =
             ScriptSend.run(["--to", "discord:123", "--attach", "/no/such/file"],
               stdin_available?: false
             )

    paths =
      Enum.map(1..11, fn idx ->
        temp_file!("script-send-#{idx}", "file #{idx}")
      end)

    args = Enum.flat_map(paths, &["--attach", &1])

    assert {:error, {:too_many_attachments, 10}} =
             ScriptSend.run(
               ["--to", "discord:123"] ++ args,
               stdin_available?: false
             )
  end

  test "resolves unique Discord known channel names" do
    :ok =
      DiscordKnownTargetStore.put({"default", 123_456, nil}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "123456",
        channel_name: "ops",
        updated_at_ms: 200
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "discord:#ops", "green"])
    assert parsed.target == %{platform: "discord", id: "123456", thread_id: nil}

    assert {:ok, result} =
             ScriptSend.run(["--to", "discord:#ops", "green"],
               discord_deliverer: DiscordDeliverer,
               stdin_available?: false
             )

    assert result.platform == "discord"
    assert result.target == "123456"
    assert_receive {:delivered, payload}
    assert payload.peer == %{kind: :channel, id: "123456", thread_id: nil}
  end

  test "scopes Discord known-name resolution by account" do
    :ok =
      DiscordKnownTargetStore.put({"default", 123_456, nil}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "123456",
        channel_name: "ops",
        updated_at_ms: 200
      })

    :ok =
      DiscordKnownTargetStore.put({"work", 999_999, nil}, %{
        channel_id: "discord",
        account_id: "work",
        peer_kind: "group",
        peer_id: "999999",
        channel_name: "ops",
        updated_at_ms: 300
      })

    assert {:error, {:ambiguous_named_channel, "ops"}} =
             ScriptSend.parse_args(["--to", "discord:#ops", "green"])

    assert {:ok, parsed} =
             ScriptSend.parse_args(["--account", "work", "--to", "discord:#ops", "green"])

    assert parsed.account_id == "work"
    assert parsed.target == %{platform: "discord", id: "999999", thread_id: nil}
  end

  test "resolves unique Discord known thread names" do
    :ok =
      DiscordKnownTargetStore.put({"default", 123_456, 789}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "123456",
        thread_id: "789",
        channel_name: "ops",
        thread_name: "deploys",
        updated_at_ms: 200
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "discord:#ops:deploys", "green"])
    assert parsed.target == %{platform: "discord", id: "123456", thread_id: "789"}

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "discord:123456:deploys", "green"])
    assert parsed.target == %{platform: "discord", id: "123456", thread_id: "789"}
  end

  test "resolves unique Telegram known chat names" do
    :ok =
      TelegramKnownTargetStore.put({"default", -100_123, nil}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "group",
        peer_id: "-100123",
        chat_title: "Lemon Ops",
        chat_username: "lemon_ops",
        updated_at_ms: 200
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram:#lemon ops", "green"])
    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: nil}

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram:@lemon_ops", "green"])
    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: nil}

    assert {:ok, result} =
             ScriptSend.run(["--to", "telegram:@lemon_ops", "green"],
               telegram_deliverer: TelegramDeliverer,
               stdin_available?: false
             )

    assert result.platform == "telegram"
    assert result.target == "-100123"
    assert_receive {:delivered, payload}
    assert payload.peer == %{kind: :channel, id: "-100123", thread_id: nil}
  end

  test "resolves unique Telegram known topic names" do
    :ok =
      TelegramKnownTargetStore.put({"default", -100_123, 77}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "group",
        peer_id: "-100123",
        thread_id: "77",
        chat_title: "Lemon Ops",
        topic_name: "Deploys",
        updated_at_ms: 200
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram:#lemon ops:deploys", "green"])
    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: "77"}

    assert {:ok, parsed} = ScriptSend.parse_args(["--to", "telegram:-100123:deploys", "green"])
    assert parsed.target == %{platform: "telegram", id: "-100123", thread_id: "77"}
  end

  test "rejects missing or ambiguous Telegram known names" do
    assert {:error, {:named_channel_not_found, "missing"}} =
             ScriptSend.parse_args(["--to", "telegram:#missing", "green"])

    :ok =
      TelegramKnownTargetStore.put({"default", -100_123, nil}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "group",
        peer_id: "-100123",
        chat_title: "Ops",
        updated_at_ms: 200
      })

    :ok =
      TelegramKnownTargetStore.put({"default", -100_999, nil}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "group",
        peer_id: "-100999",
        chat_title: "Ops",
        updated_at_ms: 100
      })

    assert {:error, {:ambiguous_named_channel, "ops"}} =
             ScriptSend.parse_args(["--to", "telegram:#ops", "green"])
  end

  test "rejects missing or ambiguous Discord known channel names" do
    assert {:error, {:named_channel_not_found, "missing"}} =
             ScriptSend.parse_args(["--to", "discord:#missing", "green"])

    :ok =
      DiscordKnownTargetStore.put({"default", 123_456, nil}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "123456",
        channel_name: "ops",
        updated_at_ms: 200
      })

    :ok =
      DiscordKnownTargetStore.put({"default", 999_999, nil}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "999999",
        channel_name: "ops",
        updated_at_ms: 100
      })

    assert {:error, {:ambiguous_named_channel, "ops"}} =
             ScriptSend.parse_args(["--to", "discord:#ops", "green"])
  end

  test "lists supported script target formats" do
    assert {:ok, parsed} =
             ScriptSend.parse_args(["--list", "--json"], %{
               "LEMON_DISCORD_DEFAULT_CHANNEL_ID" => "123"
             })

    assert parsed.list
    assert parsed.json?
    assert Enum.map(parsed.targets, & &1.platform) == ["discord", "telegram"]
    assert Enum.find(parsed.targets, &(&1.platform == "discord")).default_target == "discord:123"
  end

  test "filters supported targets for list mode" do
    assert {:ok, parsed} =
             ScriptSend.parse_args(["--list", "telegram"], %{
               "LEMON_TELEGRAM_DEFAULT_CHAT_ID" => "-100123"
             })

    assert Enum.map(parsed.targets, & &1.platform) == ["telegram"]
    assert hd(parsed.targets).default_target == "telegram:-100123"

    assert {:error, {:unsupported_platform, "slack"}} =
             ScriptSend.parse_args(["--list", "slack"])
  end

  test "lists known Telegram targets from the BEAM store" do
    :ok =
      TelegramKnownTargetStore.put({"default", -100_123, 77}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "group",
        peer_id: "-100123",
        thread_id: "77",
        chat_title: "Lemon Ops",
        topic_name: "Deploys",
        updated_at_ms: 200
      })

    :ok =
      TelegramKnownTargetStore.put({"default", 456, nil}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "dm",
        chat_display_name: "Ada",
        updated_at_ms: 100
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--list", "telegram"])
    assert [%{known_targets: [topic, dm], known_target_count: 2}] = parsed.targets
    refute hd(parsed.targets).known_targets_truncated

    assert topic.target == "telegram:-100123:77"
    assert topic.label == "Lemon Ops / Deploys"
    assert topic.source == "telegram_known_targets"
    assert topic.aliases == ["telegram:#Lemon Ops:Deploys", "telegram:-100123:Deploys"]

    assert dm.target == "telegram:456"
    assert dm.label == "Ada"
    assert dm.aliases == ["telegram:#Ada"]
  end

  test "lists known Discord targets from the BEAM store" do
    :ok =
      DiscordKnownTargetStore.put({"default", 123_456, 789}, %{
        channel_id: "discord",
        account_id: "default",
        peer_kind: "group",
        peer_id: "123456",
        thread_id: "789",
        channel_name: "ops",
        thread_name: "deploys",
        updated_at_ms: 200
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--list", "discord"])
    assert [%{known_targets: [target], known_target_count: 1}] = parsed.targets

    assert target.target == "discord:123456:789"
    assert target.label == "ops / deploys"
    assert target.source == "discord_known_targets"
    assert target.aliases == ["discord:#ops:deploys", "discord:123456:deploys"]
  end

  test "filters known targets by account for list mode" do
    :ok =
      TelegramKnownTargetStore.put({"default", -100_123, nil}, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: "group",
        peer_id: "-100123",
        chat_title: "Default Ops",
        updated_at_ms: 200
      })

    :ok =
      TelegramKnownTargetStore.put({"work", -100_999, nil}, %{
        channel_id: "telegram",
        account_id: "work",
        peer_kind: "group",
        peer_id: "-100999",
        chat_title: "Work Ops",
        updated_at_ms: 300
      })

    assert {:ok, parsed} = ScriptSend.parse_args(["--account", "work", "--list", "telegram"])

    assert [%{account_id: "work", known_targets: [target], known_target_count: 1}] =
             parsed.targets

    assert target.account_id == "work"
    assert target.target == "telegram:-100999"
  end

  test "returns usage for help mode" do
    assert {:ok, %{help: true}} = ScriptSend.parse_args(["--help"])
    assert {:ok, %{help: usage}} = ScriptSend.run(["--help"])
    assert usage =~ "mix lemon.send --to telegram:<chat_id>"
  end

  test "run returns supported targets without delivering for list mode" do
    assert {:ok, %{targets: targets}} =
             ScriptSend.run(["--list"],
               env: %{"LEMON_TELEGRAM_DEFAULT_CHAT_ID" => "-100123"}
             )

    assert Enum.find(targets, &(&1.platform == "telegram")).default_target ==
             "telegram:-100123"
  end

  defp clear_known_targets do
    TelegramKnownTargetStore.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(:telegram_known_targets, key)
    end)

    DiscordKnownTargetStore.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(:discord_known_targets, key)
    end)
  end

  defp temp_file!(prefix, content) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.txt")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
