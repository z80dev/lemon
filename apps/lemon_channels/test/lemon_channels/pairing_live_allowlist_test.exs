defmodule LemonChannels.PairingLiveAllowlistTest do
  @moduledoc """
  Approval and revocation reach a running Telegram transport through its real
  authorization path, with no restart between messages.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport
  alias LemonChannels.Pairing

  defmodule Router do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(_msg), do: :ok

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, request.prompt})
      end

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end
  end

  defmodule API do
    @updates_key {__MODULE__, :updates}
    @pid_key {__MODULE__, :pid}

    def push(update),
      do: :persistent_term.put(@updates_key, :persistent_term.get(@updates_key, []) ++ [update])

    def register_test(pid), do: :persistent_term.put(@pid_key, pid)

    def get_updates(_token, _offset, _timeout_ms) do
      case :persistent_term.get(@updates_key, []) do
        [next | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [next]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def send_message(_token, chat_id, text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      if pid = :persistent_term.get(@pid_key, nil), do: send(pid, {:send_message, chat_id, text})
      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    def edit_message_text(_token, _chat_id, _message_id, _text, _opts \\ nil),
      do: {:ok, %{"ok" => true}}

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
    def answer_callback_query(_token, _callback_id, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)

    :persistent_term.put({Router, :pid}, self())
    API.register_test(self())
    :ok = LemonCore.RouterBridge.configure(router: Router, run_orchestrator: Router)

    existing = Application.get_env(:lemon_gateway, @gateway_config_key, %{})
    Application.put_env(:lemon_gateway, @gateway_config_key, Map.put(existing, :bindings, []))

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({API, :updates})
      :persistent_term.erase({API, :pid})
      :persistent_term.erase({Router, :pid})

      if old_router_bridge,
        do: Application.put_env(:lemon_core, :router_bridge, old_router_bridge),
        else: Application.delete_env(:lemon_core, :router_bridge)

      if old_gateway_env,
        do: Application.put_env(:lemon_gateway, @gateway_config_key, old_gateway_env),
        else: Application.delete_env(:lemon_gateway, @gateway_config_key)
    end)

    :ok
  end

  test "an approved pairing code lets the sender through on the next message without a restart" do
    chat_id = 910_001
    API.push(message_update(chat_id, "first, before approval"))

    {:ok, pid} =
      start_transport(%{allowed_chat_ids: [chat_id + 1], unauthorized_dm_behavior: "pair"})

    assert_receive {:send_message, ^chat_id, reply}
    assert [_, code] = Regex.run(~r/Pairing code: ([A-HJ-NP-Z2-9]{8})/, reply)
    refute_receive {:inbound, _}, 150

    # Owner approval: consume the code, then apply the chat to the running transport.
    assert {:ok, %{chat_id: chat}} = Pairing.consume("telegram", code)
    assert chat == Integer.to_string(chat_id)
    assert :ok = Pairing.allow("telegram", chat_id)

    API.push(message_update(chat_id, "after approval"))
    assert_receive {:inbound, "after approval"}, 1_000
    assert Process.whereis(Transport) == pid
  end

  test "approval of an unpaired transport takes effect and unknown senders stay rejected" do
    chat_id = 910_002
    {:ok, _pid} = start_transport(%{allowed_chat_ids: nil})

    API.push(message_update(chat_id, "unpaired"))
    refute_receive {:inbound, _}, 250

    assert :ok = Pairing.allow("telegram", chat_id)
    API.push(message_update(chat_id + 1, "stranger"))
    API.push(message_update(chat_id, "paired"))

    assert_receive {:inbound, "paired"}, 1_000
    refute_receive {:inbound, "stranger"}, 250
  end

  test "revocation rejects the sender's next message without a restart" do
    chat_id = 910_003
    {:ok, pid} = start_transport(%{allowed_chat_ids: [chat_id, chat_id + 1]})

    API.push(message_update(chat_id, "before revoke"))
    assert_receive {:inbound, "before revoke"}, 1_000

    assert :ok = Pairing.revoke("telegram", chat_id)
    API.push(message_update(chat_id, "after revoke"))
    refute_receive {:inbound, "after revoke"}, 400

    API.push(message_update(chat_id + 1, "still allowed"))
    assert_receive {:inbound, "still allowed"}, 1_000
    assert Process.whereis(Transport) == pid
  end

  test "revoking the last chat leaves the transport unpaired, not open" do
    chat_id = 910_004
    {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

    assert :ok = Pairing.revoke("telegram", chat_id)
    API.push(message_update(chat_id, "anyone"))
    API.push(message_update(chat_id + 1, "anyone else"))
    refute_receive {:inbound, _}, 400
  end

  test "reports a stopped transport instead of pretending the allowlist applied" do
    assert Pairing.allow("telegram", 910_005) == :not_running
    assert Pairing.revoke("discord", 910_005) == :not_running
  end

  describe "supervised transport restart" do
    # The persisted policy is the canonical gateway config the transport reads on
    # every start; the operator CLI writes it before calling Pairing.allow/revoke.
    defp persist_allowlist(ids) do
      env = Application.get_env(:lemon_gateway, @gateway_config_key, %{})
      telegram = env |> Map.get(:telegram, %{}) |> Map.put(:allowed_chat_ids, ids)
      Application.put_env(:lemon_gateway, @gateway_config_key, Map.put(env, :telegram, telegram))
    end

    defp start_supervised_transport(allowed_chat_ids) do
      token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

      persist_allowlist(allowed_chat_ids)
      env = Application.get_env(:lemon_gateway, @gateway_config_key)

      telegram =
        Map.merge(env.telegram, %{
          bot_token: token,
          api_mod: API,
          poll_interval_ms: 10,
          debounce_ms: 10
        })

      Application.put_env(:lemon_gateway, @gateway_config_key, %{env | telegram: telegram})
      start_supervised!(LemonChannels.Adapters.Telegram.Supervisor)
      Process.whereis(Transport)
    end

    defp restart_transport(old) do
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old, _}, 1_000
      wait_for_new_transport(old, 50)
    end

    defp wait_for_new_transport(old, attempts) do
      case Process.whereis(Transport) do
        pid when is_pid(pid) and pid != old ->
          pid

        _ when attempts > 0 ->
          Process.sleep(20)
          wait_for_new_transport(old, attempts - 1)

        _ ->
          flunk("supervisor did not restart the Telegram transport")
      end
    end

    test "an approval survives a supervised transport restart" do
      chat_id = 910_006
      first = start_supervised_transport([chat_id + 1])

      API.push(message_update(chat_id, "before approval"))
      refute_receive {:inbound, _}, 250

      persist_allowlist([chat_id + 1, chat_id])
      assert :ok = Pairing.allow("telegram", chat_id)
      API.push(message_update(chat_id, "after approval"))
      assert_receive {:inbound, "after approval"}, 1_000

      second = restart_transport(first)
      assert second != first

      API.push(message_update(chat_id, "after restart"))
      assert_receive {:inbound, "after restart"}, 1_000
      API.push(message_update(chat_id + 2, "stranger"))
      refute_receive {:inbound, "stranger"}, 250
    end

    test "a revocation survives a supervised transport restart" do
      chat_id = 910_007
      first = start_supervised_transport([chat_id, chat_id + 1])

      API.push(message_update(chat_id, "before revoke"))
      assert_receive {:inbound, "before revoke"}, 1_000

      persist_allowlist([chat_id + 1])
      assert :ok = Pairing.revoke("telegram", chat_id)
      API.push(message_update(chat_id, "after revoke"))
      refute_receive {:inbound, "after revoke"}, 300

      second = restart_transport(first)
      assert second != first

      API.push(message_update(chat_id, "revoked after restart"))
      refute_receive {:inbound, "revoked after restart"}, 400
      API.push(message_update(chat_id + 1, "still allowed"))
      assert_receive {:inbound, "still allowed"}, 1_000
    end
  end

  defp start_transport(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    Transport.start_link(
      config:
        Map.merge(
          %{bot_token: token, api_mod: API, poll_interval_ms: 10, debounce_ms: 10},
          overrides
        )
    )
  end

  defp message_update(chat_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp stop_transport do
    if pid = Process.whereis(Transport) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end
end
