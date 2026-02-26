defmodule LemonControlPlane.Methods.AgentRoutingMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    AgentDirectoryList,
    AgentEndpointsDelete,
    AgentEndpointsList,
    AgentEndpointsSet,
    AgentInboxSend,
    AgentTargetsList
  }

  alias LemonCore.{SessionKey, Store}

  defmodule InboxSubmitterStub do
    def submit(request) do
      if pid = Process.get(:agent_routing_methods_test_pid) do
        send(pid, {:submitted_request, request})
      end

      {:ok, "run_cp_agent_inbox_stub"}
    end
  end

  setup do
    previous_submitter = Application.get_env(:lemon_router, :agent_inbox_submitter)
    Application.put_env(:lemon_router, :agent_inbox_submitter, InboxSubmitterStub)
    Process.put(:agent_routing_methods_test_pid, self())

    on_exit(fn ->
      case previous_submitter do
        nil -> Application.delete_env(:lemon_router, :agent_inbox_submitter)
        value -> Application.put_env(:lemon_router, :agent_inbox_submitter, value)
      end

      Process.delete(:agent_routing_methods_test_pid)
    end)

    :ok
  end

  test "agent.inbox.send routes to telegram shorthand and captures fanout routes" do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_inbox_#{token}"

    params = %{
      "agentId" => agent_id,
      "prompt" => "hello from control plane",
      "sessionTag" => "latest",
      "to" => "tg:-100445566/99",
      "deliverTo" => ["tg:123", "tg:456"]
    }

    assert {:ok, result} = AgentInboxSend.handle(params, %{})
    assert result["runId"] == "run_cp_agent_inbox_stub"
    assert result["selector"] == "latest"
    assert result["fanoutCount"] == 2

    assert_receive {:submitted_request, request}, 500
    assert request.agent_id == agent_id
    assert request.queue_mode == :followup
    assert request.meta[:agent_inbox_message] == true
    assert request.meta[:agent_inbox_followup] == true

    assert %{
             kind: :channel_peer,
             channel_id: "telegram",
             account_id: "default",
             peer_kind: :group,
             peer_id: "-100445566",
             thread_id: "99"
           } = SessionKey.parse(request.session_key)

    assert length(request.meta[:fanout_routes]) == 2
  end

  test "agent.inbox.send allows queueMode override" do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_inbox_collect_#{token}"

    params = %{
      "agentId" => agent_id,
      "prompt" => "collect this now",
      "queueMode" => "collect"
    }

    assert {:ok, _result} = AgentInboxSend.handle(params, %{})

    assert_receive {:submitted_request, request}, 500
    assert request.queue_mode == :collect
    assert request.meta[:agent_inbox_followup] == false
    assert request.meta[:agent_inbox][:queue_mode] == :collect
  end

  test "agent.endpoints.set/list/delete manages alias lifecycle" do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_endpoints_#{token}"

    assert {:ok, %{"endpoint" => endpoint}} =
             AgentEndpointsSet.handle(
               %{
                 "agentId" => agent_id,
                 "name" => "Ops Room",
                 "target" => "tg:-100123400/77",
                 "description" => "Ops updates"
               },
               %{}
             )

    assert endpoint["agentId"] == agent_id
    assert endpoint["name"] == "ops-room"
    assert endpoint["target"] == "tg:-100123400/77"
    assert endpoint["route"]["channelId"] == "telegram"
    assert endpoint["route"]["peerKind"] == "group"
    assert endpoint["route"]["peerId"] == "-100123400"
    assert endpoint["route"]["threadId"] == "77"

    assert {:ok, %{"endpoints" => endpoints}} =
             AgentEndpointsList.handle(%{"agentId" => agent_id}, %{})

    assert Enum.any?(endpoints, &(&1["name"] == "ops-room"))

    assert {:ok, %{"ok" => true, "agentId" => ^agent_id, "name" => "ops-room"}} =
             AgentEndpointsDelete.handle(%{"agentId" => agent_id, "name" => "ops-room"}, %{})

    assert {:ok, %{"endpoints" => after_delete}} =
             AgentEndpointsList.handle(%{"agentId" => agent_id}, %{})

    refute Enum.any?(after_delete, &(&1["name"] == "ops-room"))
  end

  test "agent.directory.list returns filtered agent/session entries" do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_directory_#{token}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: agent_id,
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "9988"
      })

    :ok =
      Store.put(:sessions_index, session_key, %{
        session_key: session_key,
        agent_id: agent_id,
        origin: :channel,
        run_count: 1,
        created_at_ms: 1_000,
        updated_at_ms: 2_000
      })

    on_exit(fn ->
      Store.delete(:sessions_index, session_key)
    end)

    assert {:ok, result} =
             AgentDirectoryList.handle(
               %{"agentId" => agent_id, "includeSessions" => true, "limit" => 10},
               %{}
             )

    assert Enum.any?(result["agents"], &(&1["agentId"] == agent_id))
    assert Enum.any?(result["sessions"], &(&1["sessionKey"] == session_key))

    assert {:ok, no_sessions} =
             AgentDirectoryList.handle(
               %{"agentId" => agent_id, "includeSessions" => false},
               %{}
             )

    assert no_sessions["sessions"] == []
  end

  test "agent.targets.list returns known telegram targets with copyable routing strings" do
    token = System.unique_integer([:positive, :monotonic])
    account_id = "default"
    chat_id = -100_700_000 - token
    topic_id = 42
    key = {account_id, chat_id, topic_id}

    :ok =
      Store.put(:telegram_known_targets, key, %{
        channel_id: "telegram",
        account_id: account_id,
        peer_kind: :group,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id),
        chat_title: "Release Room",
        topic_name: "Shipit",
        updated_at_ms: 10_000
      })

    on_exit(fn ->
      Store.delete(:telegram_known_targets, key)
    end)

    assert {:ok, result} =
             AgentTargetsList.handle(
               %{"channelId" => "telegram", "query" => "shipit"},
               %{}
             )

    assert result["channelId"] == "telegram"

    target =
      Enum.find(
        result["targets"],
        &(&1["peerId"] == Integer.to_string(chat_id) and
            &1["threadId"] == Integer.to_string(topic_id))
      )

    assert is_map(target)
    assert target["target"] == "tg:#{chat_id}/#{topic_id}"
    assert target["label"] =~ "Release Room"
    assert target["label"] =~ "Shipit"
  end
end
