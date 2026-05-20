defmodule LemonCore.Extensions.ManifestTest do
  use ExUnit.Case, async: true

  alias LemonCore.Extensions.Manifest

  test "discovers and validates extension manifests without loading extension code" do
    tmp_dir = tmp_dir()
    extension_dir = Path.join(tmp_dir, "example_extension")
    File.mkdir_p!(extension_dir)

    manifest_path = Path.join(extension_dir, "lemon_extension.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        schema_version: 1,
        name: "example-extension",
        version: "1.0.0",
        capabilities: ["tools", "memory_provider"],
        providers: [%{type: "memory", name: "team-memory"}],
        hosts: [%{type: "beam"}],
        distribution: %{source: "git", url: "https://example.invalid/ext.git"},
        audit: %{status: "pending"}
      })
    )

    assert Manifest.discover(tmp_dir) == [manifest_path]

    validation = Manifest.validate_file(manifest_path)

    assert validation.valid?
    assert validation.path == manifest_path
    assert validation.path_hash
    assert validation.capabilities == ["tools", "memory_provider"]
    assert validation.provider_types == ["memory"]
    assert validation.host_types == ["beam"]
    assert validation.distribution_sources == ["git"]
    assert validation.audit_statuses == ["pending"]
    assert validation.errors == []
  end

  test "rejects malformed manifests with actionable errors" do
    tmp_dir = tmp_dir()
    manifest_path = Path.join(tmp_dir, "extension.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        name: "Bad Name",
        capabilities: ["tools", 1],
        providers: [%{type: "unsupported", name: ""}],
        host: %{type: "native"},
        distribution: %{source: "torrent"},
        audit: %{status: "mystery"}
      })
    )

    validation = Manifest.validate_file(manifest_path)

    refute validation.valid?
    assert "version must be a non-empty string" in validation.errors
    assert "schema_version must be present" in validation.errors
    assert "name has invalid characters" in validation.errors
    assert "capabilities must contain strings" in validation.errors
    assert "providers[0].type is not supported" in validation.errors
    assert "providers[0].name must be a non-empty string" in validation.errors
    assert "host.type is not supported" in validation.errors
    assert "distribution.source is not supported" in validation.errors
    assert "audit.status is not supported" in validation.errors
  end

  test "validates embedded manifest maps for registry audits" do
    validation =
      Manifest.validate_map(%{
        "schema_version" => 1,
        "name" => "registry-extension",
        "version" => "1.0.0",
        "capabilities" => ["tools"],
        "host" => "wasm",
        "distribution" => "registry",
        "audit" => "passed"
      })

    assert validation.valid?
    assert validation.capabilities == ["tools"]
    assert validation.host_types == ["wasm"]
    assert validation.distribution_sources == ["registry"]
    assert validation.audit_statuses == ["passed"]
  end

  test "audits registry install and update candidates without loading code" do
    tmp_dir = tmp_dir()
    current_path = Path.join(tmp_dir, "current-registry.json")
    candidate_path = Path.join(tmp_dir, "candidate-registry.json")

    current = %{
      schema_version: 1,
      extensions: [
        registry_entry("safe-extension", "1.0.0", "passed"),
        registry_entry("blocked-extension", "1.0.0", "blocked")
      ]
    }

    candidate = %{
      schema_version: 1,
      extensions: [
        registry_entry("safe-extension", "1.1.0", "passed"),
        registry_entry("blocked-extension", "1.1.0", "blocked"),
        registry_entry("pending-extension", "1.0.0", "pending")
      ]
    }

    File.write!(current_path, Jason.encode!(current))
    File.write!(candidate_path, Jason.encode!(candidate))

    audit = LemonCore.Extensions.RegistryAudit.validate_file(candidate_path)

    update_audit =
      LemonCore.Extensions.RegistryAudit.validate_update_files(current_path, candidate_path)

    assert audit.valid?
    assert audit.entry_count == 3
    assert audit.installable_count == 1
    assert audit.blocked_count == 2
    assert audit.source_counts["registry"] == 3
    assert audit.audit_status_counts["passed"] == 1
    assert audit.audit_status_counts["blocked"] == 1
    assert audit.cleanup.loads_extension_code == false
    assert update_audit.update_candidate_count == 1
    assert update_audit.blocked_update_count == 1
    refute inspect(update_audit) =~ "safe-extension"
    refute inspect(update_audit) =~ "https://registry.example.invalid"
  end

  defp registry_entry(name, version, audit_status) do
    %{
      manifest: %{
        schema_version: 1,
        name: name,
        version: version,
        capabilities: ["tools"],
        host: "beam"
      },
      distribution: %{
        source: "registry",
        url: "https://registry.example.invalid/#{name}-#{version}.tar.gz"
      },
      audit: %{status: audit_status}
    }
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "lemon_manifest_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
