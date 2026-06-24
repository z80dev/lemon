defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false

  test "application starts successfully" do
    assert Application.started_applications()
           |> Enum.any?(fn {app, _, _} -> app == :lemon_web end)
  end

  test "endpoint configuration exists" do
    config = Application.get_env(:lemon_web, LemonWeb.Endpoint)
    assert is_list(config)
    assert config[:url] || config[:http]
    assert config[:adapter] == Bandit.PhoenixAdapter
  end

  test "router is configured" do
    assert Code.ensure_loaded?(LemonWeb.Router)
  end

  test "session live module exists" do
    assert Code.ensure_loaded?(LemonWeb.SessionLive)
  end

  test "session live ignores coalesced output maps" do
    socket = %Phoenix.LiveView.Socket{assigns: %{}}
    message = %{type: :coalesced_output, text: "done", run_id: "run_test"}

    assert {:noreply, ^socket} = LemonWeb.SessionLive.handle_info(message, socket)
  end

  test "session live keeps appended messages in chronological order" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, messages: [], last_run_id: nil}
    }

    run_started =
      LemonCore.Event.new(
        :run_started,
        %{run_id: "run_test", engine: "echo"},
        %{run_id: "run_test"}
      )

    tool_1 = LemonCore.Event.new(:engine_action, %{name: "tool_1"}, %{run_id: "run_test"})
    tool_2 = LemonCore.Event.new(:engine_action, %{name: "tool_2"}, %{run_id: "run_test"})

    assert {:noreply, socket} = LemonWeb.SessionLive.handle_info(run_started, socket)
    assert {:noreply, socket} = LemonWeb.SessionLive.handle_info(tool_1, socket)
    assert {:noreply, socket} = LemonWeb.SessionLive.handle_info(tool_2, socket)

    assert [
             %{kind: :system, content: "Run started (echo)."},
             %{kind: :tool_call, event: %{name: "tool_1"}},
             %{kind: :tool_call, event: %{name: "tool_2"}}
           ] = socket.assigns.messages
  end

  test "static LiveView entrypoint uses vendored Phoenix assets" do
    static_root = Path.expand("../priv/static/assets", __DIR__)
    app_js = File.read!(Path.join(static_root, "app.js"))

    assert app_js =~ ~s|from "/assets/vendor/phoenix.mjs"|
    assert app_js =~ ~s|from "/assets/vendor/phoenix_live_view.esm.js"|
    refute app_js =~ "cdn.jsdelivr.net"
    assert File.exists?(Path.join(static_root, "vendor/phoenix.mjs"))
    assert File.exists?(Path.join(static_root, "vendor/phoenix_live_view.esm.js"))
  end
end
