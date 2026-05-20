{:ok, _} = Application.ensure_all_started(:lemon_core)

alias LemonCore.Extensions.RegistryAudit

now = DateTime.utc_now()
suffix = System.system_time(:millisecond) |> rem(1_000_000_000)
tmp_dir = Path.join(System.tmp_dir!(), "lemon-extension-registry-audit-#{suffix}")
marker_path = Path.join(tmp_dir, "should-not-load.txt")
current_path = Path.join(tmp_dir, "registry-current.json")
candidate_path = Path.join(tmp_dir, "registry-candidate.json")

File.rm_rf!(tmp_dir)
File.mkdir_p!(tmp_dir)

entry = fn name, version, audit_status, source ->
  %{
    manifest: %{
      schema_version: 1,
      name: name,
      version: version,
      capabilities: ["tools"],
      hosts: [%{type: "beam"}]
    },
    distribution: %{
      source: source,
      url: "https://registry.private.invalid/#{name}-#{version}.tar.gz",
      sha256: :crypto.hash(:sha256, "#{name}:#{version}") |> Base.encode16(case: :lower)
    },
    audit: %{status: audit_status}
  }
end

current_registry = %{
  schema_version: 1,
  extensions: [
    entry.("safe-registry-extension", "1.0.0", "passed", "registry"),
    entry.("blocked-registry-extension", "1.0.0", "blocked", "registry")
  ]
}

candidate_registry = %{
  schema_version: 1,
  extensions: [
    entry.("safe-registry-extension", "1.1.0", "passed", "registry"),
    entry.("blocked-registry-extension", "1.1.0", "blocked", "registry"),
    entry.("pending-registry-extension", "1.0.0", "pending", "github"),
    Map.put(entry.("manifest-only-external-extension", "1.0.0", "passed", "archive"), :hosts, [
      %{type: "external"}
    ])
  ],
  ignored_code_probe: """
  File.write!(#{inspect(marker_path)}, "loaded")
  """
}

File.write!(current_path, Jason.encode!(current_registry, pretty: true))
File.write!(candidate_path, Jason.encode!(candidate_registry, pretty: true))

audit = RegistryAudit.validate_file(candidate_path)
update_audit = RegistryAudit.validate_update_files(current_path, candidate_path)

run_check = fn name, fun ->
  status =
    try do
      if fun.(), do: "completed", else: "failed"
    rescue
      _ -> "failed"
    end

  %{name: name, status: status}
end

checks = [
  run_check.("extension_registry_validates_code_free_index", fn ->
    audit.valid? and audit.entry_count == 4 and audit.valid_entry_count == 4 and
      audit.source_counts["registry"] == 2 and audit.source_counts["github"] == 1 and
      audit.source_counts["archive"] == 1
  end),
  run_check.("extension_registry_blocks_unaudited_install", fn ->
    audit.installable_count == 2 and audit.blocked_count == 2 and
      audit.audit_status_counts["passed"] == 2 and audit.audit_status_counts["blocked"] == 1 and
      audit.audit_status_counts["pending"] == 1
  end),
  run_check.("extension_registry_detects_audited_update", fn ->
    update_audit.update_candidate_count == 1 and update_audit.blocked_update_count == 1
  end),
  run_check.("extension_registry_audit_does_not_load_code", fn ->
    audit.cleanup.loads_extension_code == false and
      update_audit.cleanup.loads_extension_code == false and
      not File.exists?(marker_path)
  end),
  run_check.("extension_registry_audit_redacts_sensitive_values", fn ->
    audit_text = inspect(%{audit: audit, update_audit: update_audit})

    not String.contains?(audit_text, tmp_dir) and
      not String.contains?(audit_text, "safe-registry-extension") and
      not String.contains?(audit_text, "blocked-registry-extension") and
      not String.contains?(audit_text, "pending-registry-extension") and
      not String.contains?(audit_text, "registry.private.invalid") and
      not String.contains?(audit_text, "ignored_code_probe") and
      not String.contains?(audit_text, "should-not-load")
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "extension_registry_audit_smoke",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "registry_boundary" => %{
    "validates_manifest_metadata" => audit.valid?,
    "blocks_unaudited_installs" => audit.blocked_count >= 2,
    "detects_update_candidates" => update_audit.update_candidate_count == 1,
    "loads_extension_code" => audit.cleanup.loads_extension_code,
    "installable_count" => audit.installable_count,
    "blocked_count" => audit.blocked_count,
    "update_candidate_count" => update_audit.update_candidate_count,
    "blocked_update_count" => update_audit.blocked_update_count
  },
  "redaction" => %{
    "contains_raw_registry_paths" => false,
    "contains_distribution_urls" => false,
    "contains_package_names" => false,
    "contains_manifest_contents" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/extension-registry-audit-latest.json", json <> "\n")

archive =
  ".lemon/proofs/extension-registry-audit-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")
File.rm_rf!(tmp_dir)

if failed_count == 0 do
  IO.puts("extension registry audit smoke proof passed: #{completed_count} completed")
else
  IO.puts("extension registry audit smoke proof failed: #{failed_count} failed")
  System.halt(1)
end
