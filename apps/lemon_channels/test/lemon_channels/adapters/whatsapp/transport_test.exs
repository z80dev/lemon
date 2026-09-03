defmodule LemonChannels.Adapters.WhatsApp.TransportTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.{ModelPolicyAdapter, Transport}
  alias LemonChannels.ModelPolicy
  alias LemonCore.{RouterBridge, RunRequest}

  defmodule WhatsAppTestRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def submit(%RunRequest{} = request) do
      send(:persistent_term.get({__MODULE__, :pid}), {:submitted, request})

      :persistent_term.get(
        {__MODULE__, :submit_result},
        {:ok, "run-#{System.unique_integer([:positive])}"}
      )
    end

    def abort(session_key, reason) do
      send(:persistent_term.get({__MODULE__, :pid}), {:aborted, session_key, reason})
      :persistent_term.get({__MODULE__, :abort_result}, :ok)
    end
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"
  @jid "15551234567@s.whatsapp.net"

  setup do
    stop_transport()

    old_gateway_config = Application.get_env(:lemon_gateway, @gateway_config_key)
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    missing_bridge = Path.join(System.tmp_dir!(), "missing_whatsapp_bridge.mjs")

    :persistent_term.put({WhatsAppTestRouter, :pid}, self())
    :ok = RouterBridge.configure(router: WhatsAppTestRouter, run_orchestrator: WhatsAppTestRouter)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_whatsapp: true,
      bindings: [
        %{
          transport: :whatsapp,
          chat_id: @jid,
          project: "whatsapp-project",
          agent_id: "whatsapp-agent",
          queue_mode: :steer
        }
      ],
      projects: %{"whatsapp-project" => %{root: "/tmp/whatsapp-project"}},
      whatsapp: %{bridge_script: missing_bridge, dm_mode: :open}
    })

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({WhatsAppTestRouter, :pid})
      :persistent_term.erase({WhatsAppTestRouter, :submit_result})
      :persistent_term.erase({WhatsAppTestRouter, :abort_result})
      ModelPolicy.clear(ModelPolicyAdapter.build_route("default", @jid, nil))
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_config)
    end)

    :ok
  end

  test "preserves WhatsApp model and thinking preferences in the native request" do
    :ok =
      ModelPolicyAdapter.put_default_model_preference(
        "default",
        @jid,
        nil,
        "openai:gpt-4o-mini"
      )

    :ok = ModelPolicyAdapter.put_default_thinking_preference("default", @jid, nil, "high")

    {:ok, pid} = Transport.start_link()
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})

    send(pid, {
      :whatsapp_bridge_event,
      %{
        "type" => "message",
        "jid" => @jid,
        "sender_jid" => @jid,
        "message_id" => "whatsapp-native-preferences",
        "text" => "/ask honor native preferences"
      }
    })

    assert_receive {:submitted, %RunRequest{} = request}, 1_000
    assert request.model == "openai:gpt-4o-mini"
    assert request.meta.thinking_level == "high"
  end

  test "submits a native request from the configured binding" do
    {:ok, pid} = Transport.start_link()
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})

    send(pid, {
      :whatsapp_bridge_event,
      %{
        "type" => "message",
        "jid" => @jid,
        "sender_jid" => @jid,
        "message_id" => "whatsapp-native-only",
        "text" => "/ask route this natively"
      }
    })

    assert_receive {:submitted, %RunRequest{} = request}, 1_000

    assert request.agent_id == "whatsapp-agent"
    assert request.queue_mode == :steer
    assert request.cwd == Path.expand("/tmp/whatsapp-project")
  end

  test "definite submission failure sends no typing signal and permits redelivery" do
    :persistent_term.put({WhatsAppTestRouter, :submit_result}, {:error, :unavailable})
    {:ok, pid} = Transport.start_link()
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})
    port_server = :sys.get_state(pid).port_server
    :erlang.trace(port_server, true, [:receive])

    event =
      {:whatsapp_bridge_event,
       %{
         "type" => "message",
         "jid" => @jid,
         "sender_jid" => @jid,
         "message_id" => "whatsapp-retryable-rejection",
         "text" => "/ask retry this"
       }}

    send(pid, event)
    assert_receive {:submitted, %RunRequest{prompt: "/ask retry this"}}, 1_000

    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "send_text", "text" => failure_text}}}},
                   1_000

    assert failure_text =~ "couldn't queue"
    refute failure_text =~ "unavailable"

    refute_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "typing"}}}},
                   100

    :persistent_term.put({WhatsAppTestRouter, :submit_result}, {:ok, "run-redelivered"})
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})
    send(pid, event)

    assert_receive {:submitted, %RunRequest{prompt: "/ask retry this"}}, 1_000

    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "typing", "jid" => @jid}}}},
                   1_000
  end

  test "ambiguous submission keeps dedupe while reporting uncertainty" do
    :persistent_term.put({WhatsAppTestRouter, :submit_result}, {:error, :outcome_unknown})
    {:ok, pid} = Transport.start_link()
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})
    port_server = :sys.get_state(pid).port_server
    :erlang.trace(port_server, true, [:receive])

    event =
      {:whatsapp_bridge_event,
       %{
         "type" => "message",
         "jid" => @jid,
         "sender_jid" => @jid,
         "message_id" => "whatsapp-ambiguous",
         "text" => "/ask maybe accepted"
       }}

    send(pid, event)
    assert_receive {:submitted, %RunRequest{prompt: "/ask maybe accepted"}}, 1_000

    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "send_text", "text" => uncertainty_text}}}},
                   1_000

    assert uncertainty_text =~ "couldn't confirm"

    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})
    send(pid, event)
    refute_receive {:submitted, %RunRequest{prompt: "/ask maybe accepted"}}, 200
  end

  test "failed /cancel preserves transport state and never claims cancellation" do
    :persistent_term.put({WhatsAppTestRouter, :abort_result}, {:error, :unavailable})
    {:ok, pid} = Transport.start_link()
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})
    port_server = :sys.get_state(pid).port_server
    :erlang.trace(port_server, true, [:receive])

    send(pid, {
      :whatsapp_bridge_event,
      %{
        "type" => "message",
        "jid" => @jid,
        "sender_jid" => @jid,
        "message_id" => "whatsapp-cancel-rejection",
        "text" => "/cancel"
      }
    })

    assert_receive {:aborted, _session_key, :user_requested}, 1_000

    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "send_text", "text" => failure_text}}}},
                   1_000

    assert failure_text =~ "couldn't cancel"
    refute failure_text =~ "Cancelling current run"

    state = :sys.get_state(pid)
    assert state.pending_new == %{}
    assert state.buffers == %{}
  end

  defp stop_transport do
    case Process.whereis(Transport) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
