defmodule LemonControlPlane.Methods.NodesSupport do
  @moduledoc false

  # Allowlist projections for execution-node management. Durable node records
  # carry token hashes and pairing requests carry one-time challenge tokens;
  # neither crosses the wire. Capabilities are reported by name only.

  alias LemonControlPlane.Methods.SkillsSupport
  alias LemonControlPlane.NodeStore

  @max_nodes 200
  @max_pairings 50
  @max_capabilities 16

  def field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  def field(_map, _key), do: nil

  def live_nodes do
    LemonCore.NodeRegistry.list()
    |> Map.new(fn node -> {node.id, node} end)
  catch
    :exit, _ -> :unavailable
  end

  def nodes(live, filters) do
    {:ok, rows} = NodeStore.fetch_nodes()

    rows
    |> Enum.flat_map(fn
      {id, node} when is_binary(id) and is_map(node) ->
        if matches?(filters, id, field(node, :name)),
          do: [project_node(id, node, live)],
          else: []

      _ ->
        []
    end)
    |> Enum.sort_by(&{&1["status"] != "online", String.downcase(&1["name"] || "")})
    |> capped(@max_nodes)
  end

  def pairings(now, filters) do
    {:ok, rows} = NodeStore.fetch_pairings()

    rows
    |> Enum.flat_map(fn
      {id, request} when is_binary(id) and is_map(request) ->
        if pending?(request, now) and
             matches?(filters, field(request, :node_id), field(request, :node_name)),
           do: [project_pairing(id, request)],
           else: []

      _ ->
        []
    end)
    |> Enum.sort_by(& &1["createdAtMs"], :desc)
    |> capped(@max_pairings)
  end

  defp matches?(filters, id, name) do
    (not Map.has_key?(filters, "nodeId") or filters["nodeId"] == id) and
      (not Map.has_key?(filters, "name") or filters["name"] == name)
  end

  defp capped(rows, limit), do: {Enum.take(rows, limit), length(rows) > limit}

  defp pending?(request, now) do
    field(request, :status) in [:pending, "pending"] and
      is_integer(field(request, :expires_at_ms)) and field(request, :expires_at_ms) > now
  end

  defp project_node(id, node, live) do
    live_entry = if is_map(live), do: Map.get(live, id)

    status =
      cond do
        live == :unavailable -> "unknown"
        live_entry -> "online"
        true -> "offline"
      end

    %{
      "id" => id,
      "name" => SkillsSupport.text(field(node, :name), 64),
      "type" => SkillsSupport.text(to_text(field(node, :type)), 40),
      "purpose" => SkillsSupport.text(field(node, :purpose), 64),
      "labels" => labels(field(node, :labels)),
      "enrollmentInviteId" => SkillsSupport.text(field(node, :enrollment_invite_id), 128),
      "status" => status,
      "connectedAtMs" => live_entry && live_entry[:connected_at_ms],
      "lastSeenMs" => int(field(node, :last_seen_ms)),
      "pairedAtMs" => int(field(node, :paired_at_ms)),
      "capabilities" => capabilities(field(node, :capabilities)),
      "session" => session_state(id)
    }
  end

  defp project_pairing(id, request) do
    %{
      "pairingId" => id,
      "code" => SkillsSupport.text(to_text(field(request, :code)), 12),
      "nodeName" => SkillsSupport.text(field(request, :node_name), 64),
      "nodeType" => SkillsSupport.text(to_text(field(request, :node_type)), 40),
      "recovery" => is_binary(field(request, :node_id)),
      "createdAtMs" => int(field(request, :created_at_ms)),
      "expiresAtMs" => int(field(request, :expires_at_ms)),
      "capabilities" => capabilities(field(request, :capabilities))
    }
  end

  defp session_state(id) do
    id |> LemonControlPlane.Auth.TokenStore.node_session_state() |> Atom.to_string()
  rescue
    _ -> "unknown"
  end

  defp capabilities(caps) when is_map(caps) do
    caps
    |> Map.keys()
    |> Enum.map(&to_text/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
    |> Enum.take(@max_capabilities)
    |> Enum.map(&SkillsSupport.text(&1, 64))
  end

  defp capabilities(_), do: []

  defp labels(values) when is_map(values) do
    values
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and String.valid?(key) and byte_size(key) in 1..64 and
        String.trim(key) != "" and not String.match?(key, ~r/[\x00-\x1f\x7f]/) and
        is_binary(value) and String.valid?(value) and byte_size(value) <= 256 and
        not String.match?(value, ~r/[\x00-\x1f\x7f]/)
    end)
    |> Enum.sort()
    |> Enum.take(32)
    |> Map.new()
  end

  defp labels(_), do: %{}

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_text(_), do: nil

  defp int(value) when is_integer(value), do: value
  defp int(_), do: nil
end

defmodule LemonControlPlane.Methods.NodesList do
  @moduledoc """
  Handler for the read-only `nodes.list` method: paired execution nodes with
  live online/offline presence, last seen, capability names and session
  credential state, plus pending (unexpired) pairing requests with their
  verification codes. No token, token hash or challenge ever leaves the server.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NodesSupport
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "nodes.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    if valid_filters?(params) do
      list(params)
    else
      {:error, Errors.invalid_request("Invalid exact node name or nodeId filter")}
    end
  end

  defp list(params) do
    now = System.system_time(:millisecond)
    live = NodesSupport.live_nodes()
    {nodes, nodes_truncated?} = NodesSupport.nodes(live, params)
    {pairings, pairings_truncated?} = NodesSupport.pairings(now, params)

    {:ok,
     %{
       "nodes" => nodes,
       "pairings" => pairings,
       "summary" => %{
         "count" => length(nodes),
         "online" => Enum.count(nodes, &(&1["status"] == "online")),
         "pending" => length(pairings),
         "presenceAvailable" => live != :unavailable,
         "truncated" => nodes_truncated? or pairings_truncated?
       }
     }}
  rescue
    _ -> {:error, Errors.unavailable("Node store is unavailable")}
  end

  defp valid_filters?(params) do
    Enum.all?([{"name", 64}, {"nodeId", 128}], fn {key, limit} ->
      not Map.has_key?(params, key) or
        (is_binary(params[key]) and String.valid?(params[key]) and
           byte_size(params[key]) in 1..limit and String.trim(params[key]) != "" and
           not String.match?(params[key], ~r/[\x00-\x1f\x7f]/))
    end)
  end
end

defmodule LemonControlPlane.Methods.NodesRevoke do
  @moduledoc """
  Handler for `nodes.revoke` (admin): invalidates every session credential of
  one durable execution node and disconnects its live connection. The caller
  must echo the node's exact durable name as `confirmName` (bound to the stored
  record, not to client state). The durable identity is kept, so the node can
  only return through a new operator-approved pairing.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Methods.NodesSupport
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "nodes.revoke"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    node_id = params["nodeId"]
    confirm = params["confirmName"]

    cond do
      not (is_binary(node_id) and node_id != "") ->
        {:error, Errors.invalid_request("nodeId is required")}

      not is_binary(confirm) ->
        {:error, Errors.invalid_request("confirmName is required")}

      true ->
        revoke(node_id, confirm)
    end
  end

  defp revoke(node_id, confirm) do
    case NodeStore.get_node(node_id) do
      node when is_map(node) ->
        if NodesSupport.field(node, :name) == confirm do
          do_revoke(node_id)
        else
          {:error, Errors.conflict("Confirmation does not match the node name")}
        end

      _ ->
        {:error, Errors.not_found("Node not found")}
    end
  end

  defp do_revoke(node_id) do
    with {:ok, count} <- TokenStore.revoke_identity("node", node_id),
         generation when is_integer(generation) <- TokenStore.current_node_generation(node_id),
         :ok <- LemonCore.NodeRegistry.revoke_session(node_id, generation) do
      {:ok,
       %{
         "nodeId" => node_id,
         "revoked" => true,
         "revokedSessions" => count,
         "summary" => %{
           "action" => "nodes.revoke",
           "nodeId" => node_id,
           "identityRetained" => true,
           "cleanup" => %{"includesTokens" => false, "includesTokenHashes" => false}
         }
       }}
    else
      _ ->
        {:error, Errors.internal_error("Unable to revoke node credentials")}
    end
  catch
    :exit, _ -> {:error, Errors.unavailable("Node registry is unavailable")}
  end
end
