defmodule LemonControlPlane.Methods.AgentProgress do
  @moduledoc """
  Handler for `agent.progress`.

  Returns a long-running harness progress snapshot for a coding-agent session,
  and records an introspection event so operators can audit progress checks.
  """

  @behaviour LemonControlPlane.Method

  alias CodingAgent.Progress
  alias LemonCore.Introspection

  @impl true
  def name, do: "agent.progress"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    session_id = get_param(params, "sessionId")
    cwd = get_param(params, "cwd") |> normalize_cwd()

    snapshot = Progress.snapshot(session_id, cwd)

    Introspection.record(
      :agent_progress_snapshot,
      %{
        session_id: session_id,
        cwd: cwd,
        overall_percentage: snapshot[:overall_percentage] || 0
      },
      introspection_opts(params)
    )

    {:ok,
     %{
       "sessionId" => session_id,
       "cwd" => cwd,
       "snapshot" => snapshot,
       "summary" => summary(session_id, cwd, snapshot)
     }}
  rescue
    e ->
      {:error,
       {
         :internal_error,
         "Failed to build agent progress snapshot",
         Exception.message(e)
       }}
  end

  defp summary(session_id, cwd, snapshot) do
    todos = get_snapshot_map(snapshot, :todos)
    features = get_snapshot_map(snapshot, :features)
    checkpoints = get_snapshot_map(snapshot, :checkpoints)
    next_actions = get_snapshot_map(snapshot, :next_actions)

    %{
      "sessionId" => session_id,
      "cwd" => cwd,
      "overallPercentage" => get_snapshot_value(snapshot, :overall_percentage, 0),
      "todos" => progress_counts(todos),
      "features" => progress_counts(features),
      "hasFeatures" => features != %{},
      "checkpoints" => %{
        "count" => get_snapshot_value(checkpoints, :count, 0),
        "hasNewest" => not is_nil(get_snapshot_value(checkpoints, :newest, nil)),
        "hasOldest" => not is_nil(get_snapshot_value(checkpoints, :oldest, nil))
      },
      "nextActionCounts" => %{
        "todos" => length(get_snapshot_value(next_actions, :todos, [])),
        "features" => length(get_snapshot_value(next_actions, :features, []))
      },
      "cleanup" => %{
        "includesNextActionContent" => false,
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp progress_counts(progress) do
    %{
      "total" => get_snapshot_value(progress, :total, 0),
      "completed" => get_snapshot_value(progress, :completed, 0),
      "inProgress" => get_snapshot_value(progress, :in_progress, 0),
      "pending" => get_snapshot_value(progress, :pending, 0),
      "percentage" => get_snapshot_value(progress, :percentage, 0)
    }
  end

  defp get_snapshot_map(map, key) do
    case get_snapshot_value(map, key, %{}) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp get_snapshot_value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_snapshot_value(_map, _key, default), do: default

  defp introspection_opts(params) do
    []
    |> maybe_put_opt(:run_id, get_param(params, "runId"))
    |> maybe_put_opt(:session_key, get_param(params, "sessionKey"))
    |> maybe_put_opt(:agent_id, get_param(params, "agentId"))
    |> Keyword.put(:engine, "lemon")
    |> Keyword.put(:provenance, :direct)
  end

  defp normalize_cwd(nil), do: "."

  defp normalize_cwd(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: ".", else: trimmed
  end

  defp normalize_cwd(_), do: "."

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
