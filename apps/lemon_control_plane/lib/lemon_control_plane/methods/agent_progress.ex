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
       "snapshot" => snapshot
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
