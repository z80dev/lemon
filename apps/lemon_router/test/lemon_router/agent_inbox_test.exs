defmodule LemonRouter.AgentInboxTest do
  use ExUnit.Case, async: false

  alias LemonCore.{SessionKey, Store}
  alias LemonRouter.AgentInbox

  defmodule SubmitterStub do
    def submit(request) do
      if pid = Process.get(:agent_inbox_test_pid) do
        send(pid, {:submitted_request, request})
      end

      Process.get(:agent_inbox_submit_result, {:ok, "run_inbox_stub"})
    end
  end

  setup do
    previous_submitter = Application.get_env(:lemon_router, :agent_inbox_submitter)
    Application.put_env(:lemon_router, :agent_inbox_submitter, SubmitterStub)

    Process.put(:agent_inbox_test_pid, self())
    Process.delete(:agent_inbox_submit_result)

    on_exit(fn ->
      case previous_submitter do
        nil -> Application.delete_env(:lemon_router, :agent_inbox_submitter)
        value -> Application.put_env(:lemon_router, :agent_inbox_submitter, value)
      end

      Process.delete(:agent_inbox_test_pid)
      Process.delete(:agent_inbox_submit_result)
    end)

    :ok
  end

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
  end

  defp channel_session(agent_id, peer_id, opts \\ []) do
    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :dm,
      peer_id: to_string(peer_id),
      thread_id: opts[:thread_id],
      sub_id: opts[:sub_id]
    })
  end

  test "send/3 with :latest targets the latest active session" do
    token = unique_token()
    agent_id = "inbox_latest_#{token}"
    stale_session = channel_session(agent_id, 111)
    active_session = channel_session(agent_id, 111, sub_id: "active")
    run_id = "run_inbox_latest_#{token}"

    :ok =
      Store.put(:sessions_index, stale_session, %{
        session_key: stale_session,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 2_000,
        run_count: 2
      })

    :ok = Store.put(:runs, run_id, %{events: [], summary: nil, started_at: 9_000})

    assert {:ok, _} =
             Registry.register(LemonRouter.SessionRegistry, active_session, %{run_id: run_id})

    assert {:ok, %{run_id: "run_inbox_stub", session_key: ^active_session, selector: :latest}} =
             AgentInbox.send(agent_id, "status update", session: :latest, source: :test_suite)

    assert_receive {:submitted_request, request}, 500
    assert request.session_key == active_session
    assert request.origin == :channel
    assert request.queue_mode == :followup
    assert request.meta[:channel_id] == "telegram"
    assert request.meta[:agent_inbox_message] == true
    assert request.meta[:agent_inbox_followup] == true
    assert request.meta[:agent_inbox][:selector] == "latest"
    assert request.meta[:agent_inbox][:source] == "test_suite"
    assert request.meta[:agent_inbox][:queue_mode] == :followup
  end

  test "send/3 with :new forks latest route session and preserves destination route" do
    token = unique_token()
    agent_id = "inbox_new_#{token}"
    latest_session = channel_session(agent_id, 222, thread_id: "7", sub_id: "old")

    :ok =
      Store.put(:sessions_index, latest_session, %{
        session_key: latest_session,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 3_000,
        run_count: 5
      })

    assert {:ok, %{session_key: new_session_key, selector: :new}} =
             AgentInbox.send(agent_id, "fresh session please", session: :new)

    assert_receive {:submitted_request, request}, 500
    assert request.session_key == new_session_key
    assert request.origin == :channel
    assert new_session_key != latest_session

    assert %{
             kind: :channel_peer,
             channel_id: "telegram",
             account_id: "default",
             peer_kind: :dm,
             peer_id: "222",
             thread_id: "7",
             sub_id: sub_id
           } = SessionKey.parse(new_session_key)

    assert is_binary(sub_id) and sub_id != "" and sub_id != "old"
    assert request.meta[:agent_inbox][:selector] == "new"
  end

  test "send/3 with explicit session key validates agent ownership" do
    agent_id = "inbox_owner_a"
    other_session = SessionKey.main("inbox_owner_b")

    assert {:error,
            {:session_agent_mismatch, %{expected: "inbox_owner_a", actual: "inbox_owner_b"}}} =
             AgentInbox.send(agent_id, "hello", session: other_session)
  end

  test "send/3 falls back to main session when no prior sessions exist" do
    token = unique_token()
    agent_id = "inbox_main_#{token}"
    expected_main = SessionKey.main(agent_id)

    assert {:ok, %{session_key: ^expected_main, selector: :latest}} =
             AgentInbox.send(agent_id, "boot")

    assert_receive {:submitted_request, request}, 500
    assert request.session_key == expected_main
    assert request.origin == :control_plane
    assert request.queue_mode == :followup
    assert request.meta[:agent_inbox_message] == true
    assert request.meta[:agent_inbox_followup] == true
  end

  test "send/3 resolves telegram shorthand target and uses route-backed session" do
    token = unique_token()
    agent_id = "inbox_tg_target_#{token}"

    assert {:ok, %{session_key: session_key, selector: :latest}} =
             AgentInbox.send(agent_id, "hello tg route", to: "tg:-100200300/55")

    assert %{
             kind: :channel_peer,
             channel_id: "telegram",
             account_id: "default",
             peer_kind: :group,
             peer_id: "-100200300",
             thread_id: "55"
           } = SessionKey.parse(session_key)

    assert_receive {:submitted_request, request}, 500
    assert request.origin == :channel
    assert request.queue_mode == :followup
    assert request.meta[:agent_inbox][:target] == "tg:-100200300/55"
    assert request.meta[:agent_inbox][:queue_mode] == :followup
    assert request.meta[:chat_id] == -100_200_300
    assert request.meta[:topic_id] == 55
  end

  test "send/3 resolves deliver_to fanout targets into meta fanout_routes" do
    token = unique_token()
    agent_id = "inbox_fanout_#{token}"

    assert {:ok, %{session_key: _session_key, fanout_count: 2}} =
             AgentInbox.send(agent_id, "notify", to: "tg:111", deliver_to: ["tg:222", "tg:333"])

    assert_receive {:submitted_request, request}, 500
    assert request.queue_mode == :followup

    fanout_routes = request.meta[:fanout_routes]
    assert is_list(fanout_routes)
    assert length(fanout_routes) == 2

    peer_ids = fanout_routes |> Enum.map(& &1.peer_id) |> Enum.sort()
    assert peer_ids == ["222", "333"]
  end

  test "send/3 allows overriding queue_mode when immediate collect behavior is required" do
    token = unique_token()
    agent_id = "inbox_collect_override_#{token}"

    assert {:ok, %{selector: :latest}} =
             AgentInbox.send(agent_id, "handle as collect", queue_mode: :collect)

    assert_receive {:submitted_request, request}, 500
    assert request.queue_mode == :collect
    assert request.meta[:agent_inbox_message] == true
    assert request.meta[:agent_inbox_followup] == false
    assert request.meta[:agent_inbox][:queue_mode] == :collect
  end
end
