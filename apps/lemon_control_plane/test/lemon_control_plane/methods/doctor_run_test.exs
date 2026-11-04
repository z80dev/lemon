defmodule LemonControlPlane.Methods.DoctorRunTest do
  use ExUnit.Case, async: false

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

    assert {:ok, result} = DoctorRun.handle(%{}, %{})
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

    assert {:ok, %{"checks" => [check]}} = DoctorRun.handle(%{}, %{})
    assert byte_size(check["message"]) <= 484
    assert String.valid?(check["message"])
    assert String.ends_with?(check["message"], "…")
  end
end
