defmodule LemonControlPlane.Methods.TerminalBackendsStatus do
  @moduledoc """
  Handler for `terminal.backends.status`.

  Returns redacted metadata for registered terminal/process execution backends.
  This is read-only and does not expose commands, environment values, or process
  output.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "terminal.backends.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    project_dir = params["projectDir"] || params["project_dir"] || File.cwd!()

    backends =
      LemonCore.TerminalBackends.list()
      |> Enum.map(&stringify_keys/1)

    payload = %{
      "backends" => backends,
      "count" => length(backends),
      "defaultBackend" => "local",
      "policy" => stringify_keys(LemonCore.TerminalBackendPolicy.diagnostics()),
      "liveProof" => live_proof(project_dir),
      "cleanup" => %{
        "includesCommands" => false,
        "includesEnvironment" => false,
        "includesProcessOutput" => false,
        "includesRawProofDetails" => false
      }
    }

    {:ok, Map.put(payload, "summary", summary(payload))}
  end

  defp summary(payload) do
    policy = Map.get(payload, "policy", %{})
    live_proof = Map.get(payload, "liveProof", %{})

    %{
      "action" => name(),
      "backendCount" => Map.get(payload, "count", 0),
      "availableBackendCount" =>
        Enum.count(Map.get(payload, "backends", []), &(&1["available"] == true)),
      "defaultBackend" => Map.get(payload, "defaultBackend"),
      "allowlistConfigured" => Map.get(policy, "backend_allowlist_configured") == true,
      "allowedBackendCount" => length(Map.get(policy, "allowed_backends", [])),
      "approvalRequiredBackendCount" => length(Map.get(policy, "approval_required_backends", [])),
      "liveProofStatus" => Map.get(live_proof, "status"),
      "liveProofCompletedCount" => Map.get(live_proof, "completedCount", 0),
      "liveProofMissingCount" => Map.get(live_proof, "missingCount", 0),
      "dockerHardeningReturned" =>
        map_size(get_in(live_proof, ["terminalHardening", "docker"]) || %{}) > 0,
      "cleanup" => Map.get(payload, "cleanup", %{})
    }
  end

  defp live_proof(project_dir) do
    proofs = LemonCore.Doctor.ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)
    recent_proof = latest_terminal_proof(Map.get(proofs, :recent_proofs, []))
    backend_statuses = backend_statuses(Map.get(proofs, :latest_checks, []))

    %{
      "status" => live_proof_status(backend_statuses),
      "completedCount" => Enum.count(backend_statuses, &(&1["status"] == "completed")),
      "failedCount" => Enum.count(backend_statuses, &(&1["status"] == "failed")),
      "skippedCount" => Enum.count(backend_statuses, &(&1["status"] == "skipped")),
      "missingCount" => Enum.count(backend_statuses, &(&1["status"] == "missing")),
      "backendStatuses" => backend_statuses,
      "proofObject" => recent_proof && Map.get(recent_proof, :proof_object),
      "generatedAt" => recent_proof && Map.get(recent_proof, :generated_at),
      "modifiedAt" => recent_proof && Map.get(recent_proof, :modified_at),
      "fileHash" => recent_proof && Map.get(recent_proof, :file_hash),
      "proofHash" => recent_proof && Map.get(recent_proof, :proof_hash),
      "terminalHardening" =>
        format_terminal_hardening(recent_proof && Map.get(recent_proof, :terminal_hardening))
    }
  rescue
    _ ->
      %{
        "status" => "unavailable",
        "completedCount" => 0,
        "failedCount" => 0,
        "skippedCount" => 0,
        "missingCount" => 4,
        "backendStatuses" => backend_statuses([]),
        "terminalHardening" => %{}
      }
  end

  defp latest_terminal_proof(proofs) do
    Enum.find(proofs, fn proof ->
      "terminal_backend" in List.wrap(Map.get(proof, :proof_scopes))
    end)
  end

  defp backend_statuses(checks) do
    [
      {"local", "local"},
      {"local_pty", "local PTY"},
      {"docker", "Docker"},
      {"ssh", "SSH"}
    ]
    |> Enum.map(fn {backend, label} ->
      check_name = "terminal_backend_#{backend}"
      check = Enum.find(checks, &(Map.get(&1, :name) == check_name))

      %{
        "backend" => backend,
        "label" => label,
        "checkName" => check_name,
        "status" => Map.get(check || %{}, :status, "missing")
      }
    end)
  end

  defp live_proof_status(backend_statuses) do
    statuses = Enum.map(backend_statuses, & &1["status"])

    cond do
      Enum.all?(statuses, &(&1 == "completed")) -> "completed"
      "failed" in statuses -> "failed"
      "missing" in statuses -> "missing"
      "skipped" in statuses -> "skipped"
      true -> "unknown"
    end
  end

  defp format_terminal_hardening(%{docker: docker}) when is_map(docker) do
    %{
      "docker" =>
        %{}
        |> maybe_put("readOnlyRootfs", Map.get(docker, :read_only_rootfs))
        |> maybe_put("tmpfsNoexec", Map.get(docker, :tmpfs_noexec))
        |> maybe_put("dropsCapabilities", Map.get(docker, :drops_capabilities))
        |> maybe_put("noNewPrivileges", Map.get(docker, :no_new_privileges))
        |> maybe_put("cgroupMemoryLimit", Map.get(docker, :cgroup_memory_limit))
        |> maybe_put("cgroupCpuQuota", Map.get(docker, :cgroup_cpu_quota))
        |> maybe_put("cgroupPidsLimit", Map.get(docker, :cgroup_pids_limit))
        |> maybe_put("pullPolicy", Map.get(docker, :pull_policy))
        |> maybe_put("network", Map.get(docker, :network))
        |> maybe_put("memory", Map.get(docker, :memory))
        |> maybe_put("cpus", Map.get(docker, :cpus))
        |> maybe_put("pidsLimit", Map.get(docker, :pids_limit))
    }
  end

  defp format_terminal_hardening(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: to_string(value)
  defp stringify_keys(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
