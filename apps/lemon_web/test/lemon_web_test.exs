defmodule LemonWebTest do
  @moduledoc """
  Basic tests for the LemonWeb application.
  """
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  setup do
    keys = [:setup_readiness_fun, :submit_run_fun, :abort_run_fun]
    previous = Map.new(keys, &{&1, Application.get_env(:lemon_web, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    :ok
  end

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

  test "bundled favicon is served instead of producing a first-load router error" do
    conn = get(build_conn(), "/favicon.svg")
    assert response(conn, 200) =~ ~s|<svg xmlns="http://www.w3.org/2000/svg"|
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

  test "session live blocks submit when upload persistence fails" do
    previous = Application.get_env(:lemon_web, :upload_persist_fun)

    Application.put_env(:lemon_web, :upload_persist_fun, fn _socket ->
      {:error, [%{name: "receipt.pdf", error: "permission denied"}]}
    end)

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_web, :upload_persist_fun, previous)
      else
        Application.delete_env(:lemon_web, :upload_persist_fun)
      end
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        uploads: %{files: %{entries: []}},
        messages: [],
        session_key: "agent:web:browser",
        agent_id: "default",
        last_run_id: nil
      }
    }

    assert {:noreply, socket} =
             LemonWeb.SessionLive.handle_event("submit", %{"chat" => %{"prompt" => ""}}, socket)

    assert socket.assigns.submit_error == "Upload failed: receipt.pdf: permission denied"
    assert socket.assigns.messages == []
    refute Map.has_key?(socket.assigns, :prompt)
  end

  test "browser explains incomplete setup and fails closed before persistence" do
    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness_state(false) end)

    Application.put_env(:lemon_web, :submit_run_fun, fn _request ->
      raise "submit must not run while setup is incomplete"
    end)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Finish setup before chatting"
    assert html =~ "lemon setup"
    assert html =~ "Secure secret storage"
    assert html =~ "Provider and model"
    assert has_element?(view, "#chat_prompt[disabled]")
    assert has_element?(view, "#chat-form button[type=submit][disabled]")

    rendered = render_submit(view, "submit", %{"chat" => %{"prompt" => "hello"}})
    assert rendered =~ "Finish setup before chatting"
    refute rendered =~ ">hello<"
  end

  test "ready browser submits and can stop the active run" do
    parent = self()
    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness_state(true) end)

    Application.put_env(:lemon_web, :submit_run_fun, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run-web-1"}
    end)

    Application.put_env(:lemon_web, :abort_run_fun, fn run_id, reason ->
      send(parent, {:aborted, run_id, reason})
      :ok
    end)

    {:ok, view, html} = live(build_conn(), "/")

    assert html =~ "Ready"
    refute has_element?(view, "#setup-readiness")
    refute has_element?(view, "#chat_prompt[disabled]")

    rendered = render_submit(view, "submit", %{"chat" => %{"prompt" => "hello"}})

    assert_receive {:submitted, %{prompt: "hello", meta: %{source: :lemon_web}}}
    assert rendered =~ "Stop"

    rendered = render_click(view, "stop-run")
    assert_receive {:aborted, "run-web-1", :user_requested}
    assert rendered =~ "Stop requested."
    assert rendered =~ "Stopping"
  end

  test "readiness can refresh without restarting the Web UI" do
    {:ok, readiness_agent} = Agent.start_link(fn -> readiness_state(false) end)

    Application.put_env(:lemon_web, :setup_readiness_fun, fn ->
      Agent.get(readiness_agent, & &1)
    end)

    {:ok, view, _html} = live(build_conn(), "/")
    assert has_element?(view, "#setup-readiness")

    Agent.update(readiness_agent, fn _ -> readiness_state(true) end)
    rendered = render_click(view, "refresh-setup")

    refute rendered =~ "Finish setup before chatting"
    assert rendered =~ "Ready"
    refute has_element?(view, "#chat_prompt[disabled]")
  end

  test "static LiveView entrypoint uses vendored Phoenix assets" do
    static_root = Path.expand("../priv/static/assets", __DIR__)
    app_js = File.read!(Path.join(static_root, "app.js"))

    assert app_js =~ ~s|from "/assets/vendor/phoenix.mjs"|
    assert app_js =~ ~s|from "/assets/vendor/phoenix_live_view.esm.js"|
    refute app_js =~ "cdn.jsdelivr.net"
    assert File.exists?(Path.join(static_root, "vendor/phoenix.mjs"))
    assert File.exists?(Path.join(static_root, "vendor/phoenix_live_view.esm.js"))

    umbrella_root = Path.expand("../../..", __DIR__)

    assert File.read!(Path.join(static_root, "vendor/phoenix.mjs")) ==
             File.read!(Path.join(umbrella_root, "deps/phoenix/priv/static/phoenix.mjs"))

    assert File.read!(Path.join(static_root, "vendor/phoenix_live_view.esm.js")) ==
             File.read!(
               Path.join(
                 umbrella_root,
                 "deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js"
               )
             )

    app_css = File.read!(Path.join(static_root, "app.css"))
    assert app_css =~ ".min-h-screen"

    root_layout =
      Path.expand("../lib/lemon_web/components/layouts/root.html.heex", __DIR__)
      |> File.read!()

    assert root_layout =~ ~s|href={~p"/assets/app.css"}|
    assert root_layout =~ "Skip to main content"
    refute root_layout =~ "cdn.tailwindcss.com"
  end

  defp readiness_state(ready?) do
    %{
      config: %{complete: ready?, path: "/tmp/lemon-config.toml"},
      secrets: %{complete: ready?, source: if(ready?, do: :env, else: nil)},
      provider: %{
        complete: ready?,
        provider: if(ready?, do: "openai", else: nil),
        model: if(ready?, do: "openai:gpt-5", else: nil),
        credential_ready: ready?,
        reason: if(ready?, do: nil, else: :missing_default_provider)
      }
    }
  end
end
