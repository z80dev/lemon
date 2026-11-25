defmodule LemonAutomation.CronDeliveryTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronDelivery, CronJob}

  setup do
    previous = Application.get_env(:lemon_core, :gateway_test_config)

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_core, :gateway_test_config, previous)
      else
        Application.delete_env(:lemon_core, :gateway_test_config)
      end
    end)

    :ok
  end

  describe "validate/1" do
    test "normalizes the default and opt-out forms" do
      assert {:ok, nil} = CronDelivery.validate(nil)
      assert {:ok, nil} = CronDelivery.validate("  ")
      assert {:ok, nil} = CronDelivery.validate("auto")
      assert {:ok, "none"} = CronDelivery.validate("NONE")
    end

    test "accepts telegram and discord targets and rejects anything else" do
      assert {:ok, "telegram:123"} = CronDelivery.validate("telegram:123")
      assert {:ok, "telegram:-100123:7"} = CronDelivery.validate("telegram:-100123:7")
      assert {:ok, "discord:998877"} = CronDelivery.validate("discord:998877")

      for bad <- ["sms:+1555", "telegram:abc", "telegram:1:x", "telegram", 42] do
        assert {:error, message} = CronDelivery.validate(bad)
        assert message =~ "deliver_to must"
      end
    end
  end

  describe "target/2" do
    test "an unpaired install has nowhere to deliver non-chat jobs" do
      configure(%{enable_telegram: false})
      assert :none = CronDelivery.target(job(), "agent:default:main")
    end

    test "non-chat sessions go to the first allowed Telegram chat" do
      configure(%{enable_telegram: true, telegram: %{allowed_chat_ids: [-100_555, 42]}})

      assert {:ok,
              %{
                channel_id: "telegram",
                account_id: "default",
                peer: %{kind: :group, id: "-100555", thread_id: nil}
              }} = CronDelivery.target(job(), "agent:default:main")

      assert {:ok, %{peer: %{id: "-100555"}}} = CronDelivery.target(nil, "tui-20260927")
    end

    test "Discord's default channel is the owner chat when Telegram is not configured" do
      configure(%{
        enable_telegram: false,
        telegram: %{allowed_chat_ids: [42]},
        enable_discord: true,
        discord: %{default_channel_id: 7_777, default_account_id: "work"}
      })

      assert {:ok,
              %{channel_id: "discord", account_id: "work", peer: %{id: "7777", thread_id: nil}}} =
               CronDelivery.target(job(), "agent:default:main")
    end

    test "a chat-originated job goes back to its chat and topic, not the owner" do
      configure(%{enable_telegram: true, telegram: %{allowed_chat_ids: [42]}})

      session_key = "agent:default:telegram:default:group:-100999:thread:5:sub:abc"

      assert {:ok,
              %{channel_id: "telegram", peer: %{kind: :group, id: "-100999", thread_id: "5"}}} =
               CronDelivery.target(job(), session_key)
    end

    test "a chat session with hashed routing components never targets the digest" do
      configure(%{enable_telegram: true, telegram: %{allowed_chat_ids: [42]}})

      session_key =
        LemonCore.SessionKey.channel_peer(%{
          agent_id: "default",
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: "-100999",
          thread_id: "a:b"
        })

      result = CronDelivery.target(job(), session_key)

      refute match?({:ok, %{peer: %{id: "-100999"}}}, result),
             "expected no origin delivery, got #{inspect(result)}"

      refute inspect(result) =~ "~sha256-"
    end

    test "explicit deliver_to wins and none opts out" do
      configure(%{enable_telegram: true, telegram: %{allowed_chat_ids: [42]}})
      chat_session = "agent:default:telegram:default:dm:42"

      assert {:ok, %{channel_id: "discord", peer: %{id: "55", thread_id: "66"}}} =
               CronDelivery.target(job(deliver_to: "discord:55:66"), chat_session)

      assert :none = CronDelivery.target(job(deliver_to: "none"), chat_session)
    end

    test "operator command jobs stay quiet unless they name a target" do
      configure(%{enable_telegram: true, telegram: %{allowed_chat_ids: [42]}})
      command_job = job(prompt: nil, command: "backup.sh")

      assert :none = CronDelivery.target(command_job, nil)

      assert {:ok, %{peer: %{id: "42"}}} =
               CronDelivery.target(%{command_job | deliver_to: "telegram:42"}, nil)
    end
  end

  defp configure(config) do
    Application.put_env(
      :lemon_core,
      :gateway_test_config,
      Map.put(config, :max_concurrent_runs, 1)
    )
  end

  defp job(attrs \\ []) do
    CronJob.new(
      Map.merge(
        %{name: "job", schedule: "0 9 * * *", agent_id: "default", prompt: "p"},
        Map.new(attrs)
      )
    )
  end
end
