defmodule LemonCore.Doctor.ExtensionDiagnosticsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.ExtensionDiagnostics

  test "reports disabled extension execution policy without loading code" do
    previous = System.get_env("LEMON_EXTENSIONS_ENABLED")
    System.put_env("LEMON_EXTENSIONS_ENABLED", "false")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("LEMON_EXTENSIONS_ENABLED")
        value -> System.put_env("LEMON_EXTENSIONS_ENABLED", value)
      end
    end)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_disabled_test_#{System.unique_integer([:positive])}"
      )

    extension_dir = Path.join([tmp_dir, ".lemon", "extensions"])
    File.mkdir_p!(extension_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(
      Path.join([tmp_dir, ".lemon", "config.toml"]),
      """
      [runtime.extensions]
      enabled = false
      auto_load_default_paths = true
      """
    )

    File.write!(
      Path.join(extension_dir, "lemon_extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "disabled-private-extension",
        version: "1.0.0",
        hosts: [%{type: "beam"}]
      })
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.execution.enabled == false
    assert status.host_runtime.hosts["beam"].status == "disabled"
    assert status.cleanup.loads_extension_code == false
    refute inspect(status) =~ "disabled-private-extension"
  end

  test "a project's .lemon/extensions is not a default extension directory" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "extension_diagnostics_project_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    before = ExtensionDiagnostics.status(project_dir: tmp_dir)

    extension_dir = Path.join([tmp_dir, ".lemon", "extensions"])
    File.mkdir_p!(extension_dir)
    File.write!(Path.join(extension_dir, "project_ext.ex"), "defmodule ProjectExt do end\n")

    File.write!(
      Path.join(extension_dir, "lemon_extension.json"),
      Jason.encode!(%{schema_version: 1, name: "project-ext", version: "1.0.0"})
    )

    status = ExtensionDiagnostics.status(project_dir: tmp_dir)

    assert status.existing_directory_count == before.existing_directory_count
    assert status.extension_file_count == before.extension_file_count
    assert status.manifest_count == before.manifest_count
    assert status.execution.default_directory_count == 1
  end
end
