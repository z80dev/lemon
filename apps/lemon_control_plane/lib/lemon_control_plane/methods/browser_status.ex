defmodule LemonControlPlane.Methods.BrowserStatus do
  @moduledoc """
  Handler for browser.status.

  Returns operational status for the local supervised browser driver, recent
  browser artifacts, and paired browser nodes.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.NodeStore

  @impl true
  def name, do: "browser.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    project_dir = params["projectDir"] || params["project_dir"] || File.cwd!()
    limit = params["limit"] || 20

    {:ok,
     %{
       "local" => LemonBrowser.LocalServer.status() |> stringify_keys(),
       "artifactsDir" => LemonBrowser.Artifacts.default_dir(project_dir),
       "recentArtifacts" =>
         LemonBrowser.Artifacts.recent(project_dir: project_dir, limit: limit)
         |> Enum.map(&stringify_keys/1),
       "liveProof" => browser_live_proof(project_dir),
       "nodes" => browser_nodes()
     }}
  end

  defp browser_live_proof(project_dir) do
    status = LemonCore.Doctor.ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)
    proofs = Map.get(status, :recent_proofs, [])
    checks = Map.get(status, :latest_checks, [])

    proof =
      Enum.find(proofs, fn proof ->
        "browser_smoke" in List.wrap(Map.get(proof, :proof_scopes, []))
      end)

    %{
      "status" => live_proof_status(proof),
      "completedCount" => Map.get(proof || %{}, :completed_count, 0),
      "failedCount" => Map.get(proof || %{}, :failed_count, 0),
      "skippedCount" => Map.get(proof || %{}, :skipped_count, 0),
      "proofObject" => Map.get(proof || %{}, :proof_object),
      "generatedAt" => Map.get(proof || %{}, :generated_at),
      "modifiedAt" => Map.get(proof || %{}, :modified_at),
      "fileHash" => Map.get(proof || %{}, :file_hash),
      "proofHash" => Map.get(proof || %{}, :proof_hash),
      "browserProof" => Map.get(proof || %{}, :browser_proof, %{}) |> stringify_keys(),
      "latestChecks" =>
        checks
        |> Enum.filter(&browser_check?/1)
        |> Enum.take(8)
        |> Enum.map(&format_check/1),
      "cleanup" => proof_cleanup()
    }
  rescue
    error ->
      unavailable_live_proof(Exception.message(error))
  catch
    kind, reason ->
      unavailable_live_proof(inspect({kind, reason}))
  end

  defp unavailable_live_proof(error) do
    %{
      "status" => "unknown",
      "completedCount" => 0,
      "failedCount" => 0,
      "skippedCount" => 0,
      "proofObject" => nil,
      "generatedAt" => nil,
      "modifiedAt" => nil,
      "fileHash" => nil,
      "proofHash" => nil,
      "browserProof" => %{},
      "latestChecks" => [],
      "cleanup" => proof_cleanup(),
      "error" => error
    }
  end

  defp live_proof_status(nil), do: "missing"
  defp live_proof_status(%{status: "completed"}), do: "completed"
  defp live_proof_status(%{status: "failed"}), do: "failed"
  defp live_proof_status(%{status: "skipped"}), do: "skipped"
  defp live_proof_status(%{status: status}) when is_binary(status), do: status
  defp live_proof_status(_), do: "unknown"

  defp browser_check?(check) when is_map(check) do
    [
      Map.get(check, :name),
      Map.get(check, :proof_object),
      Map.get(check, :reason_kind)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
    |> String.contains?("browser")
  end

  defp browser_check?(_), do: false

  defp format_check(check) do
    %{
      "name" => Map.get(check, :name),
      "status" => Map.get(check, :status),
      "reasonKind" => Map.get(check, :reason_kind),
      "proofObject" => Map.get(check, :proof_object),
      "generatedAt" => Map.get(check, :generated_at),
      "modifiedAt" => Map.get(check, :modified_at),
      "fileHash" => Map.get(check, :file_hash),
      "proofHash" => Map.get(check, :proof_hash)
    }
  end

  defp proof_cleanup do
    %{
      "includesRawPaths" => false,
      "includesRawFilenames" => false,
      "includesRawProofDetails" => false,
      "includesRawPrompts" => false,
      "includesRawProviderResponses" => false,
      "embedsProofFileContents" => false
    }
  end

  defp browser_nodes do
    NodeStore.list_nodes()
    |> Enum.flat_map(fn
      {_id, node} when is_map(node) ->
        if browser_node?(node), do: [node_summary(node)], else: []

      _ ->
        []
    end)
  end

  defp browser_node?(node) do
    type = field(node, :type)
    type in [:browser, "browser"]
  end

  defp node_summary(node) do
    %{
      "id" => field(node, :id),
      "name" => field(node, :name),
      "status" => field(node, :status),
      "lastSeenAt" => field(node, :last_seen_at) || field(node, :lastSeenAt)
    }
    |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: to_string(value)
  defp stringify_keys(value), do: value

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
