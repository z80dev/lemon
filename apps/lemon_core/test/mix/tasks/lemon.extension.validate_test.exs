defmodule Mix.Tasks.Lemon.Extension.ValidateTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lemon.Extension.Validate

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("lemon.extension.validate")
    Mix.Task.reenable("loadpaths")
    :ok
  end

  test "validates manifests from directories" do
    tmp_dir = tmp_dir()

    File.write!(
      Path.join(tmp_dir, "lemon_extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "valid-extension",
        version: "1.0.0",
        capabilities: ["tools"],
        providers: [%{type: "model", name: "custom-model"}],
        host: %{type: "beam"},
        distribution: %{source: "local"},
        audit: %{status: "passed"}
      })
    )

    output =
      capture_io(fn ->
        assert :ok = Validate.run([tmp_dir])
      end)

    assert output =~ "PASS"
    assert output =~ "capabilities: tools"
    assert output =~ "provider types: model"
  end

  test "raises on invalid manifests" do
    tmp_dir = tmp_dir()

    File.write!(
      Path.join(tmp_dir, "extension.json"),
      Jason.encode!(%{name: "Invalid Name"})
    )

    capture_io(:stderr, fn ->
      assert_raise Mix.Error, "Extension manifest validation failed.", fn ->
        capture_io(fn -> Validate.run([tmp_dir]) end)
      end
    end)
  end

  test "json mode emits validation records" do
    tmp_dir = tmp_dir()

    File.write!(
      Path.join(tmp_dir, ".lemon-extension.json"),
      Jason.encode!(%{
        schema_version: 1,
        name: "json-extension",
        version: "1.0.0"
      })
    )

    output = capture_io(fn -> assert :ok = Validate.run(["--json", tmp_dir]) end)
    decoded = Jason.decode!(output)

    assert [manifest] = decoded["manifests"]
    assert manifest["valid"] == true
    assert manifest["path"] =~ ".lemon-extension.json"
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon_extension_validate_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
