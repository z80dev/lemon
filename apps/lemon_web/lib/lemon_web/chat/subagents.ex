defmodule LemonWeb.Chat.Subagents do
  @moduledoc """
  Read-only, content-free projection of the session's child runs for the chat
  inspector's Subagents tab.

  The only source is the `children` collection of the shared
  `sessions.snapshot` authority, so the pane keeps no second task store. Only
  safe identifiers, parent links and an enumerated status enter the view: no
  task descriptions, prompts, answers, working directories or metadata. The
  tree is capped at 50 nodes and eight levels, including cycle protection.
  """

  alias LemonMemory.Safety

  @max_nodes 50
  @max_depth 8
  @statuses ~w(queued running completed error failed killed cancelled canceled timeout aborted lost tracking_lost)

  @doc "Projects the snapshot's `children` collection; anything but `ok` is unavailable."
  def from_recovery(%{"status" => "ok", "items" => items} = projection) when is_list(items) do
    truncated? = projection["truncated"] == true or length(items) > @max_nodes
    items = Enum.take(items, @max_nodes)
    parents = Map.new(items, &{&1["runId"], &1["parentRunId"]})

    nodes =
      Enum.flat_map(items, fn row ->
        case identifier(row["runId"]) do
          nil ->
            []

          id ->
            [
              %{
                id: id,
                dom_id:
                  "subagent-" <> Base.url_encode64(:crypto.hash(:sha256, id), padding: false),
                parent_id: identifier(row["parentRunId"]),
                task_id: identifier(row["taskId"]),
                depth: depth(id, parents, %{}, 0),
                label: "Child agent",
                status: status(row["status"])
              }
            ]
        end
      end)

    %{
      status: :available,
      nodes: nodes,
      truncated?: truncated?,
      active_count: Enum.count(nodes, &(&1.status in ["queued", "running", "tracking_lost"]))
    }
  end

  def from_recovery(_), do: %{status: :unavailable, nodes: [], truncated?: false, active_count: 0}

  defp depth(id, parents, seen, depth) do
    parent = parents[id]

    if depth < @max_depth - 1 and is_binary(parent) and Map.has_key?(parents, parent) and
         not Map.has_key?(seen, parent),
       do: depth(parent, parents, Map.put(seen, id, true), depth + 1),
       else: depth
  end

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..256 do
    {safe, _} = Safety.redact_for_operator(value, max_bytes: 256)
    if safe == value and Regex.match?(~r/\A[A-Za-z0-9_:.@-]+\z/, value), do: value, else: nil
  end

  defp identifier(_), do: nil

  defp status(value) when is_atom(value), do: status(Atom.to_string(value))
  defp status(value) when value in @statuses, do: value
  defp status(_), do: "unknown"
end
