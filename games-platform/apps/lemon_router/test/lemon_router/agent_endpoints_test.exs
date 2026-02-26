defmodule LemonRouter.AgentEndpointsTest do
  use ExUnit.Case, async: false

  alias LemonRouter.AgentEndpoints

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
  end

  test "put/list/get roundtrip for telegram shorthand targets" do
    token = unique_token()
    agent_id = "endpoint_agent_#{token}"
    name = "ops-room"

    assert {:ok, endpoint} =
             AgentEndpoints.put(agent_id, name, "tg:-100123456/42",
               description: "Ops updates"
             )

    assert endpoint.agent_id == agent_id
    assert endpoint.name == name
    assert endpoint.route.channel_id == "telegram"
    assert endpoint.route.peer_kind == :group
    assert endpoint.route.peer_id == "-100123456"
    assert endpoint.route.thread_id == "42"
    assert endpoint.target == "tg:-100123456/42"
    assert endpoint.session_key =~ "agent:#{agent_id}:telegram:default:group:-100123456:thread:42"

    assert {:ok, fetched} = AgentEndpoints.get(agent_id, name)
    assert fetched.id == endpoint.id

    listed = AgentEndpoints.list(agent_id: agent_id)
    assert Enum.any?(listed, &(&1.name == name))
  end

  test "resolve/3 prefers endpoint aliases and also parses telegram shorthand" do
    token = unique_token()
    agent_id = "endpoint_resolve_#{token}"

    assert {:ok, _endpoint} =
             AgentEndpoints.put(agent_id, "primary", %{
               channel_id: "telegram",
               account_id: "default",
               peer_kind: :dm,
               peer_id: "12345"
             })

    assert {:ok, resolved_alias} = AgentEndpoints.resolve(agent_id, "primary")
    assert resolved_alias.endpoint.name == "primary"
    assert resolved_alias.route.peer_id == "12345"

    assert {:ok, resolved_tg} = AgentEndpoints.resolve(agent_id, "tg:-100999/7")
    assert resolved_tg.endpoint == nil
    assert resolved_tg.route.channel_id == "telegram"
    assert resolved_tg.route.peer_kind == :group
    assert resolved_tg.route.peer_id == "-100999"
    assert resolved_tg.route.thread_id == "7"
  end

  test "delete/2 removes endpoint alias" do
    token = unique_token()
    agent_id = "endpoint_delete_#{token}"

    assert {:ok, _endpoint} =
             AgentEndpoints.put(agent_id, "temp", "tg:999")

    assert {:ok, _} = AgentEndpoints.get(agent_id, "temp")
    assert :ok = AgentEndpoints.delete(agent_id, "temp")
    assert {:error, :not_found} = AgentEndpoints.get(agent_id, "temp")
  end
end
