defmodule LemonWeb.DiagnosticsLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth
  import ExUnit.CaptureLog

  require Logger

  alias LemonControlPlane.Methods.Registry
  alias LemonCore.Doctor.{Check, Report}

  setup :configure_operator_token

  setup do
    previous_doctor = Application.fetch_env(:lemon_control_plane, :doctor_report_fun)
    previous_readiness = Application.fetch_env(:lemon_web, :setup_readiness_fun)

    Application.put_env(:lemon_control_plane, :doctor_report_fun, fn _opts ->
      Report.from_checks([
        Check.pass(
          "config.global_exists",
          "Global config found: /Users/private-person/.lemon/config.toml"
        ),
        Check.warn("usage.status", "Usage summary unavailable", "Run `lemon usage`"),
        Check.fail("providers.default", "No default provider is set.", "Run `lemon setup`.")
      ])
    end)

    Application.put_env(:lemon_web, :setup_readiness_fun, fn ->
      %{
        config: %{complete: true, path: "/Users/private-person/.lemon/config.toml"},
        secrets: %{complete: true, source: :env},
        provider: %{
          complete: false,
          provider: "openai",
          model: "gpt-5",
          credential_ready: false,
          reason: :credential_not_usable
        }
      }
    end)

    on_exit(fn ->
      restore(:lemon_control_plane, :doctor_report_fun, previous_doctor)
      restore(:lemon_web, :setup_readiness_fun, previous_readiness)
    end)

    :ok
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  test "requires operator auth" do
    assert redirected_to(get(build_conn(), "/diagnostics"), 302) =~ "/login"
  end

  test "shows health, versions, readiness, doctor checks and logs without paths", %{conn: conn} do
    marker = "diagnostics-marker-#{System.unique_integer([:positive])}"

    capture_log(fn ->
      Logger.error("#{marker} token=sk-diag-secret at /Users/private-person/x.ex")
    end)

    {:ok, view, _html} = live(conn, "/diagnostics")
    html = render_async(view)

    assert html =~ "Runtime healthy"
    assert has_element?(view, "#versions-card", "Erlang/OTP")
    assert has_element?(view, "#readiness-card", "Action needed")
    assert has_element?(view, "#readiness-card", "Default provider has no usable credential")
    assert has_element?(view, "#doctor-checks", "providers.default")
    assert has_element?(view, "#doctor-card", "1 failed")
    assert has_element?(view, "#log-lines", marker)

    copy = view |> element("#diagnostics-copy") |> render()
    assert copy =~ "doctor: fail"
    assert copy =~ "[fail] providers.default"
    assert copy =~ "setup: config ok"

    html = render(view)
    refute html =~ "private-person"
    refute html =~ "sk-diag-secret"
    refute html =~ ".lemon/config.toml"
  end

  test "log level filter narrows the tail and follow can be paused", %{conn: conn} do
    marker = "diagnostics-level-#{System.unique_integer([:positive])}"
    capture_log(fn -> Logger.warning("#{marker} only a warning") end)

    {:ok, view, _html} = live(conn, "/diagnostics")
    assert has_element?(view, "#log-lines", marker)

    view |> element("button[phx-value-level=error]") |> render_click()
    refute has_element?(view, "#log-lines", marker)

    view |> element("button[phx-value-level=warning]") |> render_click()
    assert has_element?(view, "#log-lines", marker)

    assert view |> element("#logs-follow") |> render_click() =~ "Paused"
  end

  test "unavailable status and doctor are reported explicitly", %{conn: conn} do
    Application.put_env(:lemon_control_plane, :doctor_report_fun, fn _opts ->
      raise "doctor boom"
    end)

    :ok = Registry.unregister("status")
    on_exit(fn -> Registry.register(LemonControlPlane.Methods.Status) end)

    {:ok, view, _html} = live(conn, "/diagnostics")
    html = render_async(view)

    assert has_element?(view, "#status-unavailable")
    assert has_element?(view, "#doctor-unavailable")
    refute html =~ "doctor boom"
  end

  test "null run counts render unknown in the live card and copied diagnostics", %{conn: conn} do
    {:ok, started} = Application.ensure_all_started(:lemon_router)
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)
    :ok = Supervisor.terminate_child(LemonRouter.Supervisor, LemonRouter.RunCountTracker)

    try do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_async(view)
      assert html =~ "unknown today"
      assert html =~ "unknown failed today"
      copy = view |> element("#diagnostics-copy") |> render()
      assert copy =~ "unknown today"
      assert copy =~ "unknown failed today"
    after
      Supervisor.restart_child(LemonRouter.Supervisor, LemonRouter.RunCountTracker)
    end
  end
end
