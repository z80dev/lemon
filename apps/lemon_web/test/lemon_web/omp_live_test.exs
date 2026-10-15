defmodule LemonWeb.OmpLiveTest do
  # Drives the real `omp.*` control-plane handlers against lemon_omp's fake
  # `omp` executable (test/support/fake_omp), so every flow is hermetic: no
  # real omp, credentials or network.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  @endpoint LemonWeb.Endpoint
  @fake_omp Path.expand("../../../lemon_omp/test/support/fake_omp", __DIR__)
  @omp_env_keys [:executable, :agent_dir, :command_timeout_ms, :ready_timeout_ms]
  @async_timeout 8_000

  setup :configure_operator_token

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-web-omp-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(workspace)
    File.mkdir_p!(agent_dir)

    previous_app = Map.new(@omp_env_keys, &{&1, Application.fetch_env(:lemon_omp, &1)})
    previous_bin = System.get_env("LEMON_OMP_BIN")
    System.delete_env("LEMON_OMP_BIN")

    Application.put_env(:lemon_omp, :executable, @fake_omp)
    Application.put_env(:lemon_omp, :agent_dir, agent_dir)
    Application.put_env(:lemon_omp, :command_timeout_ms, 2_000)
    Application.put_env(:lemon_omp, :ready_timeout_ms, 5_000)

    on_exit(fn ->
      for session <- LemonOmp.list(include_ended: false, limit: 100) do
        LemonOmp.close(session["id"])
      end

      Enum.each(previous_app, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_omp, key, value)
        {key, :error} -> Application.delete_env(:lemon_omp, key)
      end)

      if previous_bin, do: System.put_env("LEMON_OMP_BIN", previous_bin)
      File.rm_rf!(root)
    end)

    {:ok, workspace: workspace, agent_dir: agent_dir}
  end

  describe "availability" do
    test "omp not installed shows an explicit empty state and disables actions", %{conn: conn} do
      Application.put_env(:lemon_omp, :executable, "/nonexistent/lemon-web-test/omp")

      {:ok, view, html} = live(conn, "/omp")
      assert html =~ "Checking omp"

      html = render_async(view, @async_timeout)
      assert html =~ "omp is not installed"
      assert html =~ "LEMON_OMP_BIN"
      assert has_element?(view, "#omp-status-badge", "Not installed")
      assert has_element?(view, "#omp-open-start[disabled]")
      assert has_element?(view, "#omp-open-resume[disabled]")

      # The keyboard path is refused server-side too.
      render_hook(view, "open_start", %{})
      refute has_element?(view, "#omp-start-dialog")
      assert render(view) =~ "omp is not installed on the Lemon runtime."
    end

    test "status header reports version and live capacity", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      assert has_element?(view, "#omp-status-badge", "omp 0.0.0-fake (test double)")
      assert has_element?(view, "#omp-live-badge", ~r/0\/\d+ live/)
      assert has_element?(view, "#omp-open-start:not([disabled])")
    end
  end

  describe "list and detail" do
    test "lists sessions and shows the full detail snapshot", %{conn: conn, workspace: workspace} do
      id = start_session!(workspace, "Summarize the repo")
      settled = await_status(id, "idle")
      assert settled["result"] == "Done: Summarize the repo"

      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      assert has_element?(view, "#omp-row-#{id}", "Summarize the repo")
      assert has_element?(view, "#omp-row-#{id}", "idle · completed")
      assert has_element?(view, "#omp-row-#{id}", "fake/fake-model")
      assert has_element?(view, "#omp-row-#{id}", Path.basename(workspace))

      view |> element("#omp-row-#{id} a") |> render_click()
      assert_patch(view, "/omp/#{id}")

      assert has_element?(view, "#omp-detail-title", "Summarize the repo")
      assert has_element?(view, "#omp-detail-status", "idle")
      assert has_element?(view, "#omp-output .md", "Done: Summarize the repo")
      assert has_element?(view, "#omp-output h3", "Result")
      assert has_element?(view, "#omp-todos", "1/2")
      assert has_element?(view, "#omp-todos", "Write tests")
      assert has_element?(view, "#omp-usage")
      assert has_element?(view, "#omp-info", workspace)
      assert has_element?(view, "#omp-composer")
      assert render(view) =~ "todo"
    end

    test "an unknown id is an explicit not-found state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/omp/omp_000000000000")
      render_async(view, @async_timeout)
      assert render(view) =~ "Session not found"
    end

    test "omp output renders as sanitized markdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      session =
        wire("omp_aaaaaaaaaaaa", %{
          "status" => "idle",
          "result" => "## Done\n\n<script>alert(1)</script>\n\n- **bold** item"
        })

      broadcast("settled", session)
      render(view)
      view |> element("#omp-row-omp_aaaaaaaaaaaa a") |> render_click()

      html = view |> element("#omp-output-body") |> render()
      assert html =~ "<h2>Done</h2>"
      assert html =~ "<strong>bold</strong>"
      refute html =~ "<script>"
    end
  end

  describe "live updates" do
    test "omp.session events upsert, order and never rewind newer snapshots", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/omp/omp_bbbbbbbbbbbb")
      render_async(view, @async_timeout)
      assert render(view) =~ "Session not found"

      now = System.system_time(:millisecond)

      broadcast(
        "updated",
        wire("omp_bbbbbbbbbbbb", %{
          "title" => "Port the parser",
          "status" => "running",
          "activity" => "Running bash — mix test",
          "updatedAt" => now,
          "activeTools" => [
            %{"id" => "t1", "name" => "bash", "intent" => "mix test", "startedAt" => now}
          ],
          "subagents" => [
            %{
              "id" => "sa1",
              "agent" => "explore",
              "status" => "running",
              "description" => "Map callers"
            }
          ],
          "declinedPrompts" => 2
        })
      )

      assert eventually(fn -> has_element?(view, "#omp-activity", "Running bash — mix test") end)
      assert has_element?(view, "#omp-detail-title", "Port the parser")
      assert has_element?(view, "#omp-subagents", "Map callers")
      assert has_element?(view, "#omp-declined", "2 interactive question")
      assert has_element?(view, "#omp-cancel-turn")

      # An older snapshot (an event racing a newer one) is ignored.
      broadcast(
        "updated",
        wire("omp_bbbbbbbbbbbb", %{
          "title" => "Stale",
          "status" => "idle",
          "updatedAt" => now - 5_000
        })
      )

      render(view)
      refute has_element?(view, "#omp-detail-title", "Stale")

      broadcast(
        "exited",
        wire("omp_bbbbbbbbbbbb", %{
          "title" => "Port the parser",
          "status" => "failed",
          "error" => "omp failed to start: boom",
          "exit" => %{"code" => 3, "reason" => "exit_status"},
          "endedAt" => now + 1_000,
          "updatedAt" => now + 1_000
        })
      )

      assert eventually(fn -> has_element?(view, "#omp-detail-status", "failed") end)
      assert has_element?(view, "#omp-detail-error", "boom")
      assert has_element?(view, "#omp-exit", "code 3")
      assert has_element?(view, "#omp-ended-note")
      refute has_element?(view, "#omp-composer")
      refute has_element?(view, "#omp-cancel-turn")
    end

    test "a session started elsewhere appears without a reload", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      id = start_session!(workspace, "From the CLI")
      assert eventually(fn -> has_element?(view, "#omp-row-#{id}", "From the CLI") end)
      assert eventually(fn -> has_element?(view, "#omp-row-#{id}", "idle · completed") end)
    end
  end

  describe "actions" do
    test "start, steer, follow-up, cancel and close through the UI", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      view |> element("#omp-open-start") |> render_click()
      assert has_element?(view, "#omp-start-dialog")

      pending_html =
        view
        |> form("#omp-start-form",
          start: %{prompt: "HOLD the parser work", cwd: workspace, thinking: "low"}
        )
        |> render_submit()

      render_async(view, @async_timeout)

      # The real start can finish before a later LiveView query. Its event reply
      # is the causal snapshot of the pending state, even after completion.
      assert pending_html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#omp-start-submit[aria-busy]")
             |> Enum.count() == 1

      [session] = LemonOmp.list(include_ended: false)
      id = session["id"]
      assert session["thinking"] == "low"
      assert_patch(view, "/omp/#{id}")
      refute has_element?(view, "#omp-start-dialog")
      assert render(view) =~ "Started omp session #{id}."

      assert eventually(fn -> has_element?(view, "#omp-detail-status", "running") end)

      # Follow-up while the turn runs is queued.
      view
      |> form("#omp-composer", compose: %{mode: "followUp", text: "then run the linter"})
      |> render_submit()

      render_async(view, @async_timeout)
      assert render(view) =~ "Follow-up accepted by #{id}."

      # Steer completes the held turn in the fake.
      view
      |> form("#omp-composer", compose: %{mode: "steer", text: "focus on errors"})
      |> render_submit()

      render_async(view, @async_timeout)
      assert render(view) =~ "Steer accepted by #{id}."
      assert eventually(fn -> has_element?(view, "#omp-detail-status", "idle") end)
      assert has_element?(view, "#omp-output .md", "Steered: focus on errors")

      # A new held turn, cancelled with the button.
      view
      |> form("#omp-composer", compose: %{mode: "steer", text: "HOLD again"})
      |> render_submit()

      render_async(view, @async_timeout)
      assert eventually(fn -> has_element?(view, "#omp-cancel-turn") end)

      view |> element("#omp-cancel-turn") |> render_click()
      render_async(view, @async_timeout)
      assert render(view) =~ "Cancelled the running turn of #{id}."
      assert eventually(fn -> has_element?(view, "#omp-detail-status", "idle") end)
      assert has_element?(view, "#omp-detail-#{id}", "last turn aborted")

      # Close goes through the preview dialog.
      view |> element("#omp-close-session") |> render_click()
      assert has_element?(view, "#omp-close-confirm", id)
      assert LemonOmp.list(include_ended: false) != []

      view |> form("#omp-close-confirm-form") |> render_submit()
      render_async(view, @async_timeout)

      assert render(view) =~ "Closed #{id}."
      assert eventually(fn -> has_element?(view, "#omp-detail-status", "closed") end)
      assert LemonOmp.list(include_ended: false) == []
      assert has_element?(view, "#omp-resume-session")
    end

    test "closing requires confirming the server-held preview", %{
      conn: conn,
      workspace: workspace
    } do
      id = start_session!(workspace, "HOLD for close")
      await_status(id, "running")

      {:ok, view, _html} = live(conn, "/omp/#{id}")
      render_async(view, @async_timeout)

      # Confirm without a preview is a no-op.
      render_hook(view, "confirm_close", %{})
      assert {:ok, %{"status" => "running"}} = LemonOmp.get(id)

      # The `x` shortcut path previews the selected session.
      render_hook(view, "preview_close", %{})
      assert has_element?(view, "#omp-close-confirm", "A turn is running")

      # Cancelling the dialog keeps the process.
      render_hook(view, "cancel_close", %{})
      refute has_element?(view, "#omp-close-confirm")
      assert {:ok, %{"status" => "running"}} = LemonOmp.get(id)

      render_hook(view, "preview_close", %{})
      view |> form("#omp-close-confirm-form") |> render_submit()
      render_async(view, @async_timeout)
      assert {:ok, %{"status" => "closed"}} = LemonOmp.get(id)
    end

    test "start validation keeps the dialog and reports field errors", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      view |> element("#omp-open-start") |> render_click()

      html =
        view
        |> form("#omp-start-form", start: %{prompt: "  ", cwd: ""})
        |> render_submit()

      assert html =~ "Write a prompt for omp."
      assert html =~ "Choose the workspace omp should run in."

      view
      |> form("#omp-start-form", start: %{prompt: "go", cwd: Path.join(workspace, "missing")})
      |> render_submit()

      html = render_async(view, @async_timeout)
      assert html =~ "cwd must be an existing directory."
      assert has_element?(view, "#omp-start-dialog")
      assert LemonOmp.list(include_ended: false) == []
    end

    test "an unconfirmed message is reported and never retried", %{
      conn: conn,
      workspace: workspace
    } do
      Application.put_env(:lemon_omp, :command_timeout_ms, 300)
      id = start_session!(workspace, "MUTE after this")
      await_status(id, "running")

      {:ok, view, _html} = live(conn, "/omp/#{id}")
      render_async(view, @async_timeout)

      view
      |> form("#omp-composer", compose: %{mode: "steer", text: "are you there"})
      |> render_submit()

      html = render_async(view, @async_timeout)
      assert html =~ "Steer not confirmed"
      assert html =~ "It was not retried."
      assert has_element?(view, "#omp-unconfirmed")
      # The draft is kept for review rather than silently resent.
      assert has_element?(view, "#omp-composer-input", "are you there")

      Process.sleep(500)

      steers =
        workspace
        |> Path.join(".fake_omp.log")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.count(&(&1 =~ ~s("type":"steer")))

      assert steers == 1
    end

    test "keyboard actions without a selection explain themselves", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      render_hook(view, "cancel_turn", %{})
      assert render(view) =~ "Select an omp session to cancel."

      render_hook(view, "compose_mode", %{"mode" => "steer"})
      assert render(view) =~ "Select an omp session to steer."
    end

    test "discover stored sessions and resume one", %{
      conn: conn,
      workspace: workspace,
      agent_dir: agent_dir
    } do
      omp_session_id = "01a137c9-4e60-73f4-a776-ece03008a9fe"
      write_session_file(agent_dir, workspace, omp_session_id)

      {:ok, view, _html} = live(conn, "/omp")
      render_async(view, @async_timeout)

      view |> element("#omp-open-resume") |> render_click()
      view |> form("#omp-discover-form", discover: %{cwd: workspace}) |> render_submit()
      render_async(view, @async_timeout)

      assert has_element?(view, "#omp-discovered-#{omp_session_id}", "Fix the flaky test")

      view
      |> element("#omp-discovered-#{omp_session_id} button", "Resume")
      |> render_click()

      view |> form("#omp-resume-form", resume: %{message: ""}) |> render_submit()
      render_async(view, @async_timeout)

      [session] = LemonOmp.list(include_ended: false)
      assert_patch(view, "/omp/#{session["id"]}")

      assert eventually(fn ->
               match?({:ok, %{"ompSessionId" => ^omp_session_id}}, LemonOmp.get(session["id"]))
             end)

      assert render(view) =~ "Resumed as #{session["id"]}."

      args = workspace |> Path.join(".fake_omp.args") |> File.read!()
      assert args =~ "--resume #{omp_session_id}"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_session!(workspace, prompt) do
    {:ok, %{"session" => %{"id" => id}}} =
      LemonWeb.Rpc.call("omp.sessions.start", %{"prompt" => prompt, "cwd" => workspace})

    id
  end

  defp await_status(id, status, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fn ->
      {:ok, session} = LemonOmp.get(id)
      session
    end)
    |> Enum.reduce_while(nil, fn session, _acc ->
      cond do
        session["status"] == status ->
          {:halt, session}

        System.monotonic_time(:millisecond) > deadline ->
          flunk("#{id} stayed #{session["status"]}")

        true ->
          Process.sleep(20) && {:cont, nil}
      end
    end)
  end

  defp eventually(fun, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    Stream.repeatedly(fun)
    |> Enum.reduce_while(false, fn result, _acc ->
      cond do
        result -> {:halt, true}
        System.monotonic_time(:millisecond) > deadline -> {:halt, false}
        true -> Process.sleep(25) && {:cont, false}
      end
    end)
  end

  defp broadcast(reason, session) do
    LemonCore.Bus.broadcast(
      "omp",
      LemonCore.Event.new(:omp_session, %{"reason" => reason, "session" => session})
    )
  end

  defp wire(id, overrides) do
    now = System.system_time(:millisecond)

    Map.merge(
      %{
        "id" => id,
        "ompSessionId" => nil,
        "title" => "Synthetic #{id}",
        "cwd" => "/tmp/workspace",
        "model" => "fake/fake-model",
        "thinking" => nil,
        "owner" => %{"kind" => "operator"},
        "status" => "running",
        "lastTurn" => nil,
        "activity" => nil,
        "startedAt" => now - 10_000,
        "updatedAt" => now,
        "endedAt" => nil,
        "turns" => 1,
        "toolCalls" => 0,
        "activeTools" => [],
        "recentTools" => [],
        "todos" => [],
        "subagents" => [],
        "usage" => %{
          "input" => 0,
          "output" => 0,
          "cacheRead" => 0,
          "cacheWrite" => 0,
          "totalTokens" => 0,
          "cost" => 0.0
        },
        "contextPercent" => nil,
        "lastText" => nil,
        "result" => nil,
        "error" => nil,
        "declinedPrompts" => 0,
        "exit" => nil
      },
      overrides
    )
  end

  # omp's on-disk layout: `<agent_dir>/sessions/<encoded cwd>/<ts>_<uuid>.jsonl`.
  defp write_session_file(agent_dir, cwd, omp_session_id) do
    encoded = "--" <> (cwd |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    dir = Path.join([agent_dir, "sessions", encoded])
    File.mkdir_p!(dir)

    lines = [
      %{"type" => "title", "v" => 1, "title" => "Fix the flaky test"},
      %{
        "type" => "session",
        "id" => omp_session_id,
        "cwd" => cwd,
        "timestamp" => "2026-10-13T00:00:00.000Z"
      },
      %{
        "type" => "message",
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
      }
    ]

    File.write!(
      Path.join(dir, "2026-10-13T00-00-00-000Z_#{omp_session_id}.jsonl"),
      Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n"
    )
  end
end
