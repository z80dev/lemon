defmodule LemonWeb.ManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import LemonWeb.Test.OperatorAuth
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias LemonCore.{RunStore, SessionLifecycle, Store}
  alias Phoenix.LiveView.Channel

  @day_ms 86_400_000

  defmodule ForkProvider do
    @moduledoc false
    def session_fork(source, cwd, destination) do
      case Application.get_env(:lemon_web, :fork_test_parent) do
        pid when is_pid(pid) -> send(pid, {:fork, source, cwd, destination})
        _ -> :ok
      end

      Application.get_env(:lemon_web, :fork_test_result, :ok)
    end
  end

  setup :configure_operator_token

  setup do
    keys = [:active_runs_fun, :fork_test_parent, :fork_test_result]
    previous = Map.new(keys, &{&1, Application.fetch_env(:lemon_web, &1)})
    provider = Application.fetch_env(:lemon_core, :agent_runtime_provider)

    Application.put_env(:lemon_web, :active_runs_fun, fn -> {:ok, []} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_web, key, value)
        {key, :error} -> Application.delete_env(:lemon_web, key)
      end)

      case provider do
        {:ok, value} -> Application.put_env(:lemon_core, :agent_runtime_provider, value)
        :error -> Application.delete_env(:lemon_core, :agent_runtime_provider)
      end
    end)

    :ok
  end

  describe "access" do
    test "session pages and exports require operator auth" do
      conn = get(build_conn(), "/sessions")
      assert redirected_to(conn, 302) =~ "/login"

      conn = get(build_conn(), "/sessions/agent:web_auth:main/export/json")
      assert redirected_to(conn, 302) =~ "/login"
    end

    test "the page renders in the app shell without legacy management links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sessions")

      assert html =~ "Sessions"
      assert html =~ ~s(id="session-search")
      refute html =~ "/manage"
      refute html =~ "management-"
    end
  end

  describe "working now" do
    test "live work links to chat and moves into the session list without a refresh click", %{
      conn: conn
    } do
      suffix = unique_suffix()
      session_key = "agent:web_live_#{suffix}:main"
      run_id = "run_web_live_#{suffix}"
      private = "/private/repo-#{suffix}"
      secret = "live-secret-#{suffix}"

      {:ok, state} =
        Agent.start_link(fn ->
          {:ok,
           [
             %{
               run_id: run_id,
               session_key: session_key,
               agent_id: secret,
               started_at_ms: System.system_time(:millisecond),
               cwd: private,
               prompt: secret
             }
           ]}
        end)

      Application.put_env(:lemon_web, :active_runs_fun, fn -> Agent.get(state, & &1) end)
      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(session_key) end)

      {:ok, view, html} = live(conn, "/sessions")

      assert has_element?(view, ~s|#active-work a[href="#{chat_path(session_key)}"]|)
      refute html =~ private
      refute html =~ secret

      seed_session(session_key, run_id, "Build a useful feature", "Finished")
      send(view.pid, :refresh_live_work)
      assert has_element?(view, ~s|#session-list [data-key="#{session_key}"]|, "Running")

      Agent.update(state, fn _ -> {:ok, []} end)
      send(view.pid, :refresh_live_work)
      render(view)

      refute has_element?(view, ~s|#active-work a[href="#{chat_path(session_key)}"]|)

      assert has_element?(
               view,
               ~s|#session-list a[data-open-chat][href="#{chat_path(session_key)}"]|
             )
    end

    test "a failed lookup preserves the last known run without exposing failure payloads", %{
      conn: conn
    } do
      suffix = unique_suffix()
      session_key = "agent:web_unavailable_#{suffix}:main"
      run_id = "run_web_unavailable_#{suffix}"

      {:ok, state} =
        Agent.start_link(fn -> {:ok, [%{run_id: run_id, session_key: session_key}]} end)

      Application.put_env(:lemon_web, :active_runs_fun, fn -> Agent.get(state, & &1) end)
      {:ok, view, _} = live(conn, "/sessions")

      Agent.update(state, fn _ -> {:error, %{secret: "hidden-secret", path: "/private/repo"}} end)
      send(view.pid, :refresh_live_work)
      html = render(view)

      assert has_element?(view, ~s|#active-work a[href="#{chat_path(session_key)}"]|)
      assert has_element?(view, "#active-work", "Unavailable")
      assert html =~ "Last known work is preserved"
      refute html =~ "hidden-secret"
      refute html =~ "/private/repo"

      Agent.update(state, fn _ -> {:ok, []} end)
      send(view.pid, :refresh_live_work)
      render(view)

      refute has_element?(view, ~s|#active-work a[href="#{chat_path(session_key)}"]|)
      refute has_element?(view, "#active-work", "Unavailable")
    end

    test "the live work projection is bounded and rejects malformed run targets", %{conn: conn} do
      runs =
        for index <- 1..45 do
          %{
            run_id: "run_bounded_#{index}",
            session_key: "agent:web_bounded:main",
            started_at_ms: index
          }
        end

      invalid = %{
        run_id: "/private/repo",
        session_key: "agent:web_bounded:main",
        started_at_ms: 100
      }

      Application.put_env(:lemon_web, :active_runs_fun, fn -> {:ok, [invalid | runs]} end)

      {:ok, view, html} = live(conn, "/sessions")

      assert has_element?(view, "#active-work", "40 active")
      assert has_element?(view, "#active-work", "run_bounded_45")
      refute has_element?(view, "#active-work", "run_bounded_5 ")
      refute html =~ "/private/repo"
    end
  end

  describe "search and filters" do
    test "query searches prompts and answers, and status/pinned/agent filters narrow the list", %{
      conn: conn
    } do
      suffix = unique_suffix()
      agent = "web_filter_#{suffix}"
      alpha = "agent:#{agent}:alpha"
      beta = "agent:#{agent}:beta"
      gamma = "agent:#{agent}:gamma"

      on_exit(fn ->
        Enum.each([alpha, beta, gamma], &LemonWeb.TestSupport.SessionCleanup.delete/1)
      end)

      seed_session(alpha, "run-alpha-#{suffix}", "deploy the zeppelin-#{suffix}", "ok")
      seed_session(beta, "run-beta-#{suffix}", "triage", "answer mentions zeppelin-#{suffix}")
      seed_session(gamma, "run-gamma-#{suffix}", "unrelated", "unrelated")
      assert {:ok, _} = SessionLifecycle.patch(beta, %{pinned: true})
      assert {:ok, _} = SessionLifecycle.patch(gamma, %{archived: true})

      {:ok, view, _html} = live(conn, "/sessions?agent=#{agent}")
      assert row?(view, alpha) and row?(view, beta)
      refute row?(view, gamma)

      view |> form("#session-filters", %{q: "zeppelin-#{suffix}"}) |> render_change()
      assert_patch(view, "/sessions?q=zeppelin-#{suffix}&agent=#{agent}")
      assert row?(view, alpha) and row?(view, beta)
      refute row?(view, gamma)
      assert has_element?(view, "#session-count", "Showing 2 of 2 matching")

      view |> element("#pinned-filter") |> render_click()
      assert row?(view, beta)
      refute row?(view, alpha)

      {:ok, view, _html} = live(conn, "/sessions?status=archived&agent=#{agent}")
      assert row?(view, gamma)
      refute row?(view, alpha)

      {:ok, view, _html} = live(conn, "/sessions?status=all&agent=#{agent}&sort=title&dir=asc")
      assert row?(view, alpha) and row?(view, beta) and row?(view, gamma)
      assert has_element?(view, ~s|th[aria-sort="ascending"]|, "Session")

      {:ok, view, _html} = live(conn, "/sessions?q=no-such-session-#{suffix}")
      assert render(view) =~ "No sessions match"
    end
  end

  describe "metadata" do
    test "rename inline, pin, archive, and bulk unarchive patch durable metadata", %{conn: conn} do
      suffix = unique_suffix()
      agent = "web_meta_#{suffix}"
      key = "agent:#{agent}:main"
      other = "agent:#{agent}:other"
      on_exit(fn -> Enum.each([key, other], &LemonWeb.TestSupport.SessionCleanup.delete/1) end)

      seed_session(key, "run-meta-#{suffix}", "hello", "world")
      seed_session(other, "run-meta-other-#{suffix}", "hello", "world")

      {:ok, view, _html} = live(conn, "/sessions?agent=#{agent}")

      render_click(view, "start-rename", %{"key" => key})
      assert has_element?(view, "#rename-#{dom_id(key)}-title")

      rendered =
        view
        |> form("#rename-#{dom_id(key)}", %{title: "Release triage"})
        |> render_submit()

      assert rendered =~ "Session renamed"
      assert rendered =~ "Release triage"
      assert SessionLifecycle.get(key).title == "Release triage"

      too_long = String.duplicate("x", 161)
      render_click(view, "start-rename", %{"key" => key})

      rendered =
        render_submit(view, "rename", %{"key" => key, "title" => too_long})

      assert rendered =~ "160 characters"
      assert SessionLifecycle.get(key).title == "Release triage"
      render_click(view, "cancel-rename")

      assert render_click(view, "set-flag", %{
               "key" => key,
               "field" => "pinned",
               "value" => "true"
             }) =~ "Session pinned"

      assert SessionLifecycle.get(key).pinned

      render_click(view, "set-flag", %{"key" => key, "field" => "archived", "value" => "true"})
      assert SessionLifecycle.get(key).archived
      refute row?(view, key)

      render_click(view, "set-flag", %{"key" => other, "field" => "archived", "value" => "true"})

      {:ok, view, _html} = live(conn, "/sessions?status=archived&agent=#{agent}")
      render_click(view, "toggle-select-all")
      assert has_element?(view, "#bulk-bar", "2 selected")

      rendered = view |> element("#bulk-bar button", "Unarchive") |> render_click()
      assert rendered =~ "Unarchived 2 sessions"
      refute SessionLifecycle.get(key).archived
      refute SessionLifecycle.get(other).archived
    end
  end

  describe "inspection" do
    test "detail view is redacted, links to chat, and reports missing sessions", %{conn: conn} do
      suffix = unique_suffix()
      session_key = "agent:web_admin_#{suffix}:main"
      run_id = "run-web-admin-#{suffix}"
      secret = "browser-secret-#{suffix}"
      private_path = "/private/session-repo-#{suffix}"

      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(session_key) end)

      seed_session(
        session_key,
        run_id,
        "api_key=#{secret} launch checklist",
        "Bearer #{secret}",
        [
          %{
            __event__: :action_event,
            action: %{
              id: "tool-1",
              title: "Inspect repository",
              kind: :shell,
              detail: %{token: secret, cwd: private_path}
            },
            phase: :started
          },
          %{
            __event__: :action_event,
            action: %{
              id: "tool-1",
              title: "Inspect repository",
              kind: :shell,
              detail: %{token: secret, cwd: private_path}
            },
            phase: :completed,
            ok: true,
            message: "token=#{secret}"
          }
        ]
      )

      assert {:ok, _session} =
               SessionLifecycle.patch(session_key, %{
                 title: "Launch room #{private_path} api_key=#{secret}"
               })

      {:ok, view, html} = live(conn, "/sessions/#{session_key}")

      assert html =~ "Launch room"
      assert html =~ "Inspect repository"
      refute html =~ secret
      refute html =~ private_path
      refute formatted_state(view) =~ secret
      refute formatted_state(view) =~ private_path

      # Both phases of one invocation collapse into a single completed row.
      assert view |> element("#run-history") |> render() |> count("<details") == 1
      assert has_element?(view, "#run-history details", "completed")
      assert has_element?(view, ~s|a[href="#{chat_path(session_key)}"]|, "Open in chat")
      assert has_element?(view, ~s|a[href="/sessions/#{encode(session_key)}/export/json"]|)

      {:ok, _view, missing} = live(conn, "/sessions/agent:web_missing_#{suffix}:main")
      assert missing =~ "Session not found"
    end
  end

  describe "fork" do
    test "fork calls sessions.fork with the resolved workspace and opens the child in chat", %{
      conn: conn
    } do
      suffix = unique_suffix()
      source = "agent:web_fork_#{suffix}:main"
      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(source) end)
      seed_session(source, "run-fork-#{suffix}", "fork me", "ok")

      Application.put_env(:lemon_core, :agent_runtime_provider, ForkProvider)
      Application.put_env(:lemon_web, :fork_test_parent, self())

      {:ok, view, _html} = live(conn, "/sessions/#{source}")
      view |> element("button", "Fork") |> render_click()

      assert_receive {:fork, ^source, cwd, child}, 2_000
      assert is_binary(cwd) and cwd != ""
      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(child) end)

      {path, flash} = assert_redirect(view, 2_000)
      assert path == chat_path(child)
      assert flash["info"] =~ "Forked"
      assert SessionLifecycle.get(child)
      assert LemonWeb.SessionCwd.recorded(child) == {:ok, cwd}
    end

    test "an uncertain fork outcome is reported and never retried", %{conn: conn} do
      suffix = unique_suffix()
      source = "agent:web_fork_unknown_#{suffix}:main"
      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(source) end)
      seed_session(source, "run-fork-unknown-#{suffix}", "fork me", "ok")

      Application.put_env(:lemon_core, :agent_runtime_provider, ForkProvider)
      Application.put_env(:lemon_web, :fork_test_parent, self())
      Application.put_env(:lemon_web, :fork_test_result, {:error, :outcome_unknown})

      {:ok, view, _html} = live(conn, "/sessions/#{source}")
      render_click(view, "fork", %{"key" => source})

      assert_receive {:fork, ^source, _cwd, _child}, 2_000
      assert render_async(view) =~ "fork outcome is uncertain"
      refute_receive {:fork, _, _, _}, 200
    end
  end

  describe "exports" do
    test "redacted downloads omit secrets and unsupported formats fail safely", %{conn: conn} do
      suffix = unique_suffix()
      session_key = "agent:web_export_#{suffix}:main"
      secret = "export-secret-#{suffix}"

      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(session_key) end)
      seed_session(session_key, "run-web-export-#{suffix}", "token=#{secret}", "Bearer #{secret}")

      json = get(conn, "/sessions/#{session_key}/export/json")
      body = response(json, 200)
      assert get_resp_header(json, "content-type") |> hd() =~ "application/json"
      assert get_resp_header(json, "content-disposition") |> hd() =~ "attachment"
      assert Jason.decode!(body)["redacted"] == true
      refute body =~ secret
      refute body =~ "rawEvents"

      markdown = get(conn, "/sessions/#{session_key}/export/markdown")
      assert get_resp_header(markdown, "content-type") |> hd() =~ "text/markdown"
      refute response(markdown, 200) =~ secret

      assert get(conn, "/sessions/#{session_key}/export/html") |> response(400) ==
               "Unsupported export format"

      assert get(conn, "/sessions/agent:web_export_missing_#{suffix}:main/export/json")
             |> response(404) == "Session not found"
    end
  end

  describe "delete" do
    test "delete is bound to the exact previewed session and refuses stale or busy targets", %{
      conn: conn
    } do
      suffix = unique_suffix()
      agent = "web_delete_#{suffix}"
      key = "agent:#{agent}:main"
      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(key) end)
      seed_session(key, "run-delete-#{suffix}", "delete me", "ok")

      {:ok, view, _html} = live(conn, "/sessions?agent=#{agent}")

      assert render_click(view, "confirm-delete") =~ "Preview the exact session"

      preview = render_click(view, "preview-delete", %{"key" => key})
      assert preview =~ "Delete this session?"
      assert has_element?(view, "#delete-dialog", key)

      # A metadata change after the preview invalidates the binding.
      assert {:ok, _} = SessionLifecycle.patch(key, %{title: "Changed elsewhere"})
      assert render_submit(view, "confirm-delete", %{}) =~ "changed after the preview"
      assert SessionLifecycle.get(key)
      refute has_element?(view, "#delete-dialog")

      # A running session is refused.
      Application.put_env(:lemon_web, :active_runs_fun, fn ->
        {:ok, [%{run_id: "run_busy_#{suffix}", session_key: key, started_at_ms: 1}]}
      end)

      render_click(view, "preview-delete", %{"key" => key})
      assert render_submit(view, "confirm-delete", %{}) =~ "The session is running"
      assert SessionLifecycle.get(key)

      # Unknown run status fails closed.
      Application.put_env(:lemon_web, :active_runs_fun, fn -> {:error, :down} end)
      render_click(view, "preview-delete", %{"key" => key})
      assert render_submit(view, "confirm-delete", %{}) =~ "could not be confirmed idle"
      assert SessionLifecycle.get(key)

      Application.put_env(:lemon_web, :active_runs_fun, fn -> {:ok, []} end)
      render_click(view, "preview-delete", %{"key" => key})
      rendered = view |> form("#delete-dialog-form") |> render_submit()
      assert rendered =~ "Session deleted"
      assert SessionLifecycle.get(key) == nil
      refute row?(view, key)
    end

    test "deleting from the detail view returns to the list", %{conn: conn} do
      suffix = unique_suffix()
      key = "agent:web_delete_detail_#{suffix}:main"
      on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(key) end)
      seed_session(key, "run-delete-detail-#{suffix}", "delete me", "ok")

      {:ok, view, _html} = live(conn, "/sessions/#{key}")
      render_click(view, "preview-delete", %{"key" => key})
      view |> form("#delete-dialog-form") |> render_submit()

      assert_patch(view, "/sessions")
      assert SessionLifecycle.get(key) == nil
    end
  end

  describe "prune" do
    test "prune requires an exact preview, refuses a stale candidate set, and deletes only previewed sessions",
         %{conn: conn} do
      suffix = unique_suffix()
      stale = "agent:web_prune_#{suffix}:main"
      late = "agent:web_prune_late_#{suffix}:main"
      fresh = "agent:web_prune_fresh_#{suffix}:main"
      pinned = "agent:web_prune_pinned_#{suffix}:main"
      ancient = System.system_time(:millisecond) - 3_700 * @day_ms

      on_exit(fn ->
        Enum.each([stale, late, fresh, pinned], &LemonWeb.TestSupport.SessionCleanup.delete/1)
      end)

      seed_session(stale, "run-prune-#{suffix}", "old", "done", [], ancient)
      seed_session(late, "run-prune-late-#{suffix}", "old", "done", [], ancient)
      seed_session(pinned, "run-prune-pinned-#{suffix}", "old", "done", [], ancient)
      seed_session(fresh, "run-prune-fresh-#{suffix}", "new", "done")
      assert {:ok, _} = SessionLifecycle.patch(stale, %{archived: true})
      assert {:ok, _} = SessionLifecycle.patch(fresh, %{archived: true})
      assert {:ok, _} = SessionLifecycle.patch(pinned, %{archived: true, pinned: true})

      {:ok, view, _html} = live(conn, "/sessions")

      render_click(view, "open-prune")
      assert has_element?(view, "#prune-dialog")
      assert render_click(view, "prune-confirm") =~ "Preview the exact candidate set"
      assert has_element?(view, "#prune-confirm[disabled]")

      rendered =
        view
        |> form("#prune-form", prune: %{days: "3650"})
        |> render_submit()

      assert has_element?(view, "#prune-preview", stale)
      assert has_element?(view, "#prune-preview strong", "1")
      assert rendered =~ "exact candidate"
      refute has_element?(view, "#prune-preview", fresh)
      refute has_element?(view, "#prune-preview", late)
      refute has_element?(view, "#prune-preview", pinned)

      # The candidate set changes after the preview: archive another old session.
      assert {:ok, _} = SessionLifecycle.patch(late, %{archived: true})

      refused = render_click(view, "prune-confirm")
      assert refused =~ "candidate set changed"
      refute has_element?(view, "#prune-preview")
      assert SessionLifecycle.get(stale)
      assert SessionLifecycle.get(late)

      view |> form("#prune-form", prune: %{days: "3650"}) |> render_submit()
      assert has_element?(view, "#prune-preview", stale)
      assert has_element?(view, "#prune-preview", late)

      # Editing the policy discards the preview.
      render_change(view, "prune-edit", %{"prune" => %{"days" => "3000"}})
      refute has_element?(view, "#prune-preview")
      view |> form("#prune-form", prune: %{days: "3650"}) |> render_submit()

      rendered = render_click(view, "prune-confirm")
      assert rendered =~ "Pruned 2 sessions"
      assert SessionLifecycle.get(stale) == nil
      assert SessionLifecycle.get(late) == nil
      assert SessionLifecycle.get(fresh)
      assert SessionLifecycle.get(pinned)
      refute has_element?(view, "#prune-dialog")
    end

    test "invalid thresholds are rejected before any preview", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sessions")
      render_click(view, "open-prune")

      rendered = render_submit(view, "prune-preview", %{"prune" => %{"days" => "0"}})
      assert rendered =~ "Choose a threshold from 1 to 3650 days"
      refute has_element?(view, "#prune-preview")
    end
  end

  defp row?(view, key), do: has_element?(view, ~s|#session-list [data-key="#{key}"]|)

  defp chat_path(key), do: "/chat/" <> encode(key)

  defp encode(key), do: URI.encode(key, &URI.char_unreserved?/1)

  defp count(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  defp dom_id(value) do
    :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false) |> binary_part(0, 12)
  end

  defp formatted_state(view) do
    state = :sys.get_state(view.pid)
    Channel.format_status(:terminate, [[], state]) |> inspect(limit: :infinity)
  end

  defp seed_session(session_key, run_id, prompt, answer, events \\ [], updated_at_ms \\ nil) do
    Enum.each(events, &RunStore.append_event(run_id, &1))

    :ok =
      RunStore.finalize(run_id, %{
        session_key: session_key,
        agent_id: session_key |> String.split(":") |> Enum.at(1),
        origin: :web,
        engine: "test-engine",
        prompt: prompt,
        completed: %{ok: true, answer: answer}
      })

    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)

    if is_integer(updated_at_ms) do
      row = SessionLifecycle.get(session_key)

      :ok =
        Store.put(:sessions_index, session_key, %{
          session_key: session_key,
          agent_id: row.agent_id,
          origin: row.origin,
          created_at_ms: updated_at_ms,
          updated_at_ms: updated_at_ms,
          run_count: row.run_count
        })
    end

    :ok
  end

  defp unique_suffix, do: System.unique_integer([:positive, :monotonic])

  defp eventually(fun, attempts \\ 600)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
