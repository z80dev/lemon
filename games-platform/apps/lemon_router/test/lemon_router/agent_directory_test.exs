defmodule LemonRouter.AgentDirectoryTest do
  use ExUnit.Case, async: false

  alias LemonCore.{SessionKey, Store}
  alias LemonRouter.AgentDirectory

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
  end

  defp base_session_key(agent_id, peer_id, opts \\ []) do
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

  test "latest_session/2 prefers active sessions over index-only sessions" do
    token = unique_token()
    agent_id = "dir_active_#{token}"

    indexed_session = base_session_key(agent_id, 101)
    active_session = base_session_key(agent_id, 101, sub_id: "inflight")
    run_id = "run_dir_active_#{token}"

    :ok =
      Store.put(:sessions_index, indexed_session, %{
        session_key: indexed_session,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 2_000,
        run_count: 3
      })

    :ok = Store.put(:runs, run_id, %{events: [], summary: nil, started_at: 9_000})

    assert {:ok, _} =
             Registry.register(LemonRouter.SessionRegistry, active_session, %{run_id: run_id})

    assert {:ok, session} = AgentDirectory.latest_session(agent_id)
    assert session.session_key == active_session
    assert session.active? == true
    assert session.run_id == run_id
  end

  test "latest_route_session/2 ignores non-routable main sessions" do
    token = unique_token()
    agent_id = "dir_route_#{token}"
    main_session = SessionKey.main(agent_id)
    route_session = base_session_key(agent_id, 202)

    :ok =
      Store.put(:sessions_index, main_session, %{
        session_key: main_session,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 10_000,
        run_count: 2
      })

    :ok =
      Store.put(:sessions_index, route_session, %{
        session_key: route_session,
        agent_id: agent_id,
        created_at_ms: 2_000,
        updated_at_ms: 5_000,
        run_count: 1
      })

    assert {:ok, session} = AgentDirectory.latest_route_session(agent_id)
    assert session.session_key == route_session
    assert session.kind == :channel_peer
  end

  test "list_sessions/1 supports route filtering" do
    token = unique_token()
    agent_id = "dir_filter_#{token}"

    matching_session = base_session_key(agent_id, 303)
    non_matching_session = base_session_key(agent_id, 404)

    :ok =
      Store.put(:sessions_index, matching_session, %{
        session_key: matching_session,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 2_000,
        run_count: 1
      })

    :ok =
      Store.put(:sessions_index, non_matching_session, %{
        session_key: non_matching_session,
        agent_id: agent_id,
        created_at_ms: 1_500,
        updated_at_ms: 2_500,
        run_count: 1
      })

    sessions =
      AgentDirectory.list_sessions(
        agent_id: agent_id,
        route: %{channel_id: "telegram", peer_id: "303"}
      )

    assert Enum.any?(sessions, &(&1.session_key == matching_session))
    refute Enum.any?(sessions, &(&1.session_key == non_matching_session))
  end

  test "list_agents/1 exposes discoverability metadata" do
    token = unique_token()
    agent_id = "dir_agents_#{token}"
    session_key = base_session_key(agent_id, 505)

    :ok =
      Store.put(:sessions_index, session_key, %{
        session_key: session_key,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 3_000,
        run_count: 4
      })

    agents = AgentDirectory.list_agents()
    entry = Enum.find(agents, &(&1.agent_id == agent_id))

    assert is_map(entry)
    assert entry.latest_session_key == session_key
    assert entry.session_count >= 1
    assert entry.route_count >= 1
  end

  test "list_targets/1 exposes friendly telegram target labels for alias setup" do
    token = unique_token()
    agent_id = "dir_targets_#{token}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: agent_id,
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: "-100606",
        thread_id: "88"
      })

    :ok =
      Store.put(:sessions_index, session_key, %{
        session_key: session_key,
        agent_id: agent_id,
        created_at_ms: 1_000,
        updated_at_ms: 3_000,
        run_count: 2
      })

    key = {"default", -100_606, 88}

    :ok =
      Store.put(:telegram_known_targets, key, %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: "-100606",
        thread_id: "88",
        chat_title: "Ops Room",
        topic_name: "Deployments",
        updated_at_ms: 4_000
      })

    targets = AgentDirectory.list_targets(channel_id: "telegram", query: "deploy")

    entry =
      Enum.find(
        targets,
        &(&1.target == "tg:-100606/88")
      )

    assert is_map(entry)
    assert entry.label =~ "Ops Room"
    assert entry.label =~ "Deployments"
    assert entry.session_count >= 1
    assert agent_id in entry.agent_ids
  end
end
