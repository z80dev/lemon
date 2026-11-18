defmodule LemonControlPlane.Methods.DoctorRunTest do
  use ExUnit.Case, async: false

  @admin_ctx %{auth: %{role: :operator, scopes: [:read, :admin]}}

  alias LemonControlPlane.Methods.{DoctorRun, Registry}
  alias LemonCore.Doctor.{Check, Report}

  setup do
    previous = Application.fetch_env(:lemon_control_plane, :doctor_report_fun)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_control_plane, :doctor_report_fun, value)
        :error -> Application.delete_env(:lemon_control_plane, :doctor_report_fun)
      end
    end)

    :ok
  end

  test "is a registered, read-scoped async method" do
    assert DoctorRun.name() == "doctor.run"
    assert DoctorRun.scopes() == [:read]
    assert DoctorRun.dispatch_mode() == :async
    assert "doctor.run" in Registry.list_methods()
    assert Registry.dispatch_mode("doctor.run") == :async
  end

  test "an HTTPS origin is validated and canonicalized before shared doctor evaluation" do
    parent = self()

    Application.put_env(:lemon_control_plane, :doctor_report_fun, fn opts ->
      send(parent, {:doctor_opts, opts})
      Report.from_checks([])
    end)

    assert {:ok, result} = DoctorRun.handle(%{"botPublicUrl" => "https://BOT.example:443/"}, %{})
    assert_receive {:doctor_opts, [runtime: :local, bot_public_url: "https://bot.example"]}
    assert result["botPublicOrigin"] == "https://bot.example"

    for value <- [
          "http://bot.example",
          "https://u:p@bot.example",
          "https://bot.example/path",
          "https://bot.example?x",
          "https://bot.example#x",
          "https://bot.example:",
          "https://bad host"
        ] do
      assert {:error, _} = DoctorRun.handle(%{"botPublicUrl" => value}, %{})
    end

    refute_received {:doctor_opts, _}
  end

  test "projects a bounded report with paths and secrets redacted" do
    parent = self()

    checks =
      [
        Check.pass(
          "config.global_exists",
          "Global config found: /Users/someone/.lemon/config.toml"
        ),
        Check.warn(
          "secrets.master_key",
          "Could not verify api_key=sk-live-should-not-leak in ~/.lemon/secrets",
          "Check (/var/lib/lemon/store) permissions; light/dark stays"
        ),
        Check.fail("providers.default", "No default provider is set.", "Run `lemon setup`."),
        Check.skip("runtime.control_port", "Not running")
      ] ++ for(i <- 1..70, do: Check.pass("filler.#{i}", "ok"))

    Application.put_env(:lemon_control_plane, :doctor_report_fun, fn opts ->
      send(parent, {:doctor_opts, opts})
      Report.from_checks(checks)
    end)

    assert {:ok, result} = DoctorRun.handle(%{}, @admin_ctx)
    assert_receive {:doctor_opts, [runtime: :local]}

    assert result["overall"] == "fail"
    assert result["counts"] == %{"pass" => 71, "warn" => 1, "fail" => 1, "skip" => 1}
    assert length(result["checks"]) == 64
    assert result["truncated"] == true
    assert result["cleanup"]["writesSupportBundle"] == false

    [config, secrets, providers | _] = result["checks"]

    assert config == %{
             "name" => "config.global_exists",
             "status" => "pass",
             "message" => "Global config found: [path]",
             "remediation" => nil
           }

    assert secrets["status"] == "warn"
    refute secrets["message"] =~ "sk-live-should-not-leak"
    refute secrets["message"] =~ ".lemon/secrets"
    assert secrets["remediation"] =~ "[path]"
    assert secrets["remediation"] =~ "light/dark stays"
    refute inspect(result) =~ "/Users/someone"
    refute inspect(result) =~ "/var/lib/lemon"
    assert providers["remediation"] == "Run `lemon setup`."
  end

  test "truncates long messages" do
    Application.put_env(:lemon_control_plane, :doctor_report_fun, fn _opts ->
      Report.from_checks([Check.warn("long", String.duplicate("é", 600))])
    end)

    assert {:ok, %{"checks" => [check]}} = DoctorRun.handle(%{}, @admin_ctx)
    assert byte_size(check["message"]) <= 484
    assert String.valid?(check["message"])
    assert String.ends_with?(check["message"], "…")
  end

  @tag :tmp_dir
  test "read scope gets fixed guidance, never invalid private config values", %{tmp_dir: root} do
    Application.delete_env(:lemon_control_plane, :doctor_report_fun)
    config = Path.join(root, "config.toml")

    # The TOML parser echoes the offending line, which reaches doctor output both
    # as `config.global_valid` text and as the channels check's exception remediation.
    File.write!(config, "[agent]\nmodel = OPAQUE_TLS_7Q2X9 merger closes Friday\n")

    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(previous_paths || [], :global_config, config)
    )

    on_exit(fn ->
      if is_nil(previous_paths),
        do: Application.delete_env(:lemon_core, :paths),
        else: Application.put_env(:lemon_core, :paths, previous_paths)
    end)

    read_ctx = %{auth: %{role: :operator, scopes: [:read]}}
    assert {:ok, read} = Registry.dispatch("doctor.run", %{}, read_ctx)
    encoded = Jason.encode!(read)
    refute encoded =~ "OPAQUE_TLS_7Q2X9"
    refute encoded =~ "merger closes Friday"
    assert read["detailsWithheld"] == true

    assert %{"status" => "fail", "message" => "Check failed.", "remediation" => remediation} =
             Enum.find(read["checks"], &(&1["name"] == "config.global_valid"))

    assert remediation =~ "operator.admin"

    assert {:ok, full} = Registry.dispatch("doctor.run", %{}, @admin_ctx)
    assert full["detailsWithheld"] == false
    global = Enum.find(full["checks"], &(&1["name"] == "config.global_valid"))
    assert global["message"] =~ "OPAQUE_TLS_7Q2X9"
  end
end
