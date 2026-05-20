defmodule LemonControlPlane.Methods.ReadinessStatus do
  @moduledoc """
  Handler for `readiness.status`.

  Returns the compact launch-readiness summary used by source-wrapper commands
  and support bundles.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Doctor.ReadinessSummary

  @impl true
  def name, do: "readiness.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    project_dir = params["projectDir"] || params["project_dir"] || File.cwd!()
    limit = normalize_limit(params["limit"])

    status =
      ReadinessSummary.status(project_dir: project_dir, limit: limit)
      |> format_value()

    {:ok, Map.put(status, "summary", summary(status, limit))}
  rescue
    error ->
      {:error, {:internal_error, "Failed to build readiness status", Exception.message(error)}}
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 1_000)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> min(parsed, 1_000)
      _ -> 10
    end
  end

  defp normalize_limit(_), do: 10

  defp summary(status, limit) do
    channels = Map.get(status, "channels", %{})
    media_provider = Map.get(status, "mediaProvider", %{})
    proofs = Map.get(status, "proofs", %{})
    proof_gate_summary = Map.get(status, "proofGateSummary", %{})
    unresolved = Map.get(status, "unresolvedGates", [])
    unresolved_reason_kinds = unresolved_reason_kinds(unresolved)

    %{
      "action" => name(),
      "status" => Map.get(status, "status"),
      "limit" => limit,
      "doctorOverall" => get_in(status, ["doctor", "overall"]),
      "channelStatus" => Map.get(channels, "status"),
      "promotedPlatforms" => Map.get(channels, "promotedPlatforms", []),
      "launchGateCount" => Map.get(channels, "gateCount", 0),
      "launchGateBlockedCount" => Map.get(channels, "blockedCount", 0),
      "launchGateWarningCount" => Map.get(channels, "warningCount", 0),
      "mediaProviderStatus" => Map.get(media_provider, "status"),
      "proofCount" => Map.get(proofs, "proofCount", 0),
      "proofGateStatus" => Map.get(proof_gate_summary, "status"),
      "proofGateCount" => Map.get(proof_gate_summary, "gateCount", 0),
      "proofGatePassedCount" => Map.get(proof_gate_summary, "passedCount", 0),
      "proofGateBlockedCount" => Map.get(proof_gate_summary, "blockedCount", 0),
      "proofGateWarningCount" => Map.get(proof_gate_summary, "warningCount", 0),
      "proofGateStatuses" => Map.get(proof_gate_summary, "statuses", %{}),
      "unresolvedGateCount" => length(unresolved),
      "unresolvedGateReasonKindCount" => length(unresolved_reason_kinds),
      "unresolvedGateReasonKinds" => unresolved_reason_kinds,
      "cleanup" => Map.get(status, "cleanup", %{})
    }
  end

  defp unresolved_reason_kinds(unresolved) do
    unresolved
    |> Enum.flat_map(fn gate ->
      [Map.get(gate, "reasonKind") | List.wrap(Map.get(gate, "reasonKinds", []))]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp format_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {format_key(key), format_value(item)} end)
    |> Map.new()
  end

  defp format_value(value) when is_list(value), do: Enum.map(value, &format_value/1)
  defp format_value(value), do: value

  defp format_key(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> camelize()
  end

  defp format_key(key) when is_binary(key), do: camelize(key)

  defp camelize(key) do
    case String.split(key, "_") do
      [] ->
        key

      [first | rest] ->
        first <> Enum.map_join(rest, "", &String.capitalize/1)
    end
  end
end
