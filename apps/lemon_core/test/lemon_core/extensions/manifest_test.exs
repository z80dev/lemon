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

  test "rejects the retired wasm host type" do
    tmp_dir = tmp_dir()
    manifest_path = Path.join(tmp_dir, "extension.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{schema_version: 1, name: "wasm-ext", version: "1.0.0", host: "wasm"})
    )

    validation = Manifest.validate_file(manifest_path)

    refute validation.valid?
    assert "host is not supported" in validation.errors
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "lemon_manifest_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
