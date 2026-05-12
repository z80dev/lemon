defmodule LemonCore.Doctor.SupportBundleTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.{Check, Report, SupportBundle}

  test "writes a zip containing diagnostics and metadata" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    bundle_path = Path.join(tmp_dir, "support.zip")
    report = Report.from_checks([Check.pass("runtime.boot", "ok")])

    assert {:ok, ^bundle_path} = SupportBundle.write(report, bundle_path: bundle_path)
    assert File.exists?(bundle_path)

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])
    names = Enum.map(entries, fn {name, _content} -> List.to_string(name) end)

    assert "README.txt" in names
    assert "manifest.json" in names
    assert "doctor_report.json" in names
    assert "environment.json" in names
    assert "config/global_config.toml" in names
    assert "config/project_config.toml" in names

    {_, manifest_json} = Enum.find(entries, fn {name, _content} -> name == ~c"manifest.json" end)
    manifest = manifest_json |> IO.iodata_to_binary() |> Jason.decode!()

    assert manifest["lemon_version"] == "0.1.0"
    assert manifest["runtime_mode"] in ["source-dev", "release-runtime"]
    assert is_map(manifest["git"])
    assert is_binary(manifest["elixir"])
    assert is_binary(manifest["otp"])
  end

  test "redacts sensitive config assignments and inline tokens" do
    text = """
    model = "claude"
    api_key = "sk-ant-real-secret"
    bot_token = "123:abc"
    wallet_key = "0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    note = "Bearer abc.def"
    """

    redacted = SupportBundle.redact_text(text)

    assert redacted =~ ~s(model = "claude")
    assert redacted =~ ~s(api_key = "[redacted]")
    assert redacted =~ ~s(bot_token = "[redacted]")
    assert redacted =~ ~s(wallet_key = "[redacted]")
    assert redacted =~ "Bearer [redacted]"
    refute redacted =~ "sk-ant-real-secret"
    refute redacted =~ "123:abc"
    refute redacted =~ "0123456789abcdef"
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_support_bundle_test_#{System.unique_integer([:positive])}"
    )
  end
end
