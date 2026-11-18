defmodule LemonWeb.ShellLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonCore.{Bus, Event, Events, RunStore, SessionLifecycle}
  alias LemonWeb.ShellLive
  alias LemonWeb.ShellLive.{Palette, RunEvents}

  setup :configure_operator_token

  setup do
    previous = Application.get_env(:lemon_web, :memory_lifecycle_fun)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_web, :memory_lifecycle_fun, previous),
        else: Application.delete_env(:lemon_web, :memory_lifecycle_fun)
    end)

    :ok
  end

  defp shell(%{conn: conn}) do
    {:ok, view, _html} = live_isolated(conn, ShellLive)
    view
  end

  defp open_palette(view, params \\ %{}) do
    render_hook(
      view,
      "palette:open",
      Map.merge(%{"recent" => [], "chat" => false, "path" => "/sessions"}, params)
    )

    render_async(view)
  end

  defp unique, do: System.unique_integer([:positive, :monotonic])

  defp seed_session(key, prompt, answer, title) do
    run_id = "run-shell-#{unique()}"

    :ok =
      RunStore.finalize(run_id, %{
        session_key: key,
        agent_id: key |> String.split(":") |> Enum.at(1),
        origin: :web,
        engine: "test-engine",
        prompt: prompt,
        completed: %{ok: true, answer: answer}
      })

    assert eventually(fn -> SessionLifecycle.get(key) != nil end)
    if title, do: {:ok, _} = SessionLifecycle.patch(key, %{title: title})
    on_exit(fn -> LemonWeb.TestSupport.SessionCleanup.delete(key) end)
  end

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  describe "mounting" do
    test "the app layout renders the sticky shell on every page", %{conn: conn} do
      Application.put_env(:lemon_web, :memory_lifecycle_fun, fn _action, _args ->
        {:ok,
         %{
           items: [],
           count: 0,
           truncated: false,
           filters: %{query: "", scope: "all", kind: "all", agent: "", workspace_digest: ""},
           limits: %{}
         }}
      end)

      # Legacy page markup still repeats `main-content` until its owner migrates.
      {:ok, view, html} = live(conn, "/memory", on_error: :warn)
      assert html =~ ~s(id="lemon-shell")
      assert html =~ ~s(data-phx-sticky)
      assert shell = find_live_child(view, "lemon-shell")
      assert render(shell) =~ "Command palette"
    end

    test "requires operator auth on the connected mount" do
      clear_operator_token()

      assert {:error, {:redirect, %{to: "/login"}}} =
               live_isolated(build_conn(), ShellLive, session: %{})
    end
  end

  describe "palette" do
    test "empty query lists recent picks, actions and navigation", context do
      view = shell(context)

      html =
        open_palette(view, %{
          "recent" => [%{"id" => "nav:models", "label" => "Models"}, %{"id" => "bogus"}]
        })

      assert html =~ "Recent"
      assert html =~ "Go to"
      assert html =~ "Actions"
      assert html =~ "Toggle theme"
      assert html =~ "Sign out"
      # Chat-only actions stay hidden off a chat workspace.
      refute html =~ "Toggle plan mode"
      assert has_element?(view, ~s([data-recent-id="nav:models"][data-href="/models"]))
      assert has_element?(view, ~s(#palette-opt-0[aria-selected="true"]))
      assert has_element?(view, ~s(#palette-input[aria-activedescendant="palette-opt-0"]))
    end

    test "fuzzy query ranks navigation and actions", context do
      view = shell(context)
      open_palette(view)

      html = render_change(view, "palette:query", %{"q" => "autom"})
      render_async(view)

      assert has_element?(view, ~s(#palette-opt-0[data-href="/automation"]))
      refute html =~ ~s(data-href="/models")

      # Keywords match too: "cron" lives in Automation's keywords.
      render_change(view, "palette:query", %{"q" => "cron"})
      assert has_element?(view, ~s([data-palette-item][data-href="/automation"]))

      render_hook(view, "palette:active", %{"index" => 0})
      assert has_element?(view, ~s(#palette-opt-0[aria-selected="true"]))
    end

    test "chat workspace adds chat actions and split targets", context do
      view = shell(context)
      key = "agent:shell_split_#{unique()}:main"
      other = "agent:shell_other_#{unique()}:main"
      seed_session(other, "deploy the thing", "done", "Other session")

      html = open_palette(view, %{"chat" => true, "path" => "/chat/#{key}"})

      assert html =~ "Toggle plan mode"
      assert html =~ "Toggle inspector"
      assert has_element?(view, ~s([data-kind="chat"][data-action="model-picker"]))
      # The chat's own new-session action replaces the global one.
      refute has_element?(view, ~s([data-recent-id="action:new-session"]))

      assert has_element?(
               view,
               ~s([data-recent-id="session:#{other}"][data-split-href="#{Palette.chat_path(key)}?split=#{URI.encode_www_form(other)}"])
             )
    end

    test "sessions are listed recent first and searchable by title", context do
      view = shell(context)
      key = "agent:shell_title_#{unique()}:main"
      seed_session(key, "hello", "hi", "Quarterly zebra report")

      html = open_palette(view)
      assert html =~ "Sessions"

      render_change(view, "palette:query", %{"q" => "zebra report"})
      html = render_async(view)
      assert html =~ "Quarterly zebra report"

      assert has_element?(
               view,
               ~s([data-recent-id="session:#{key}"][data-href="#{Palette.chat_path(key)}"])
             )
    end

    test "search mode finds session content, memory and reports unavailable sources", context do
      view = shell(context)
      needle = "platypus#{unique()}"
      key = "agent:shell_search_#{unique()}:main"
      seed_session(key, "please investigate #{needle} today", "found it", "Investigation")

      test_pid = self()

      Application.put_env(:lemon_web, :memory_lifecycle_fun, fn :list, [filters] ->
        send(test_pid, {:memory_filters, filters})

        {:ok,
         %{
           items: [
             %{
               id: "mem_1",
               excerpt: "Remember the #{needle} rollout",
               kind: "run",
               agent: "default",
               ingested_at_ms: System.system_time(:millisecond)
             }
           ]
         }}
      end)

      open_palette(view)
      render_change(view, "palette:query", %{"q" => "/" <> needle})
      html = render_async(view)

      assert html =~ "Everywhere"
      assert html =~ "Investigation"
      assert html =~ "Remember the #{needle} rollout"
      assert_received {:memory_filters, %{"query" => ^needle, "limit" => 8}}

      assert has_element?(
               view,
               ~s([data-recent-id="memory:mem_1"][data-href="/memory?query=#{needle}"])
             )

      # Tab toggles back to commands; a failing source renders an explicit state.
      Application.put_env(:lemon_web, :memory_lifecycle_fun, fn :list, _ ->
        {:error, :memory_unavailable}
      end)

      render_hook(view, "palette:mode", %{"q" => needle})
      refute render(view) =~ "Everywhere"
      render_hook(view, "palette:mode", %{"q" => needle})
      html = render_async(view)
      assert html =~ "Memory search is unavailable."
    end

    test "search mode asks for more input below two characters", context do
      view = shell(context)
      open_palette(view)
      html = render_change(view, "palette:query", %{"q" => "/a"})
      assert html =~ "Type at least 2 characters"
    end
  end

  describe "shortcut help" do
    test "renders registered shortcuts grouped, sanitized and bounded", context do
      view = shell(context)

      html =
        render_hook(view, "shortcuts:open", %{
          "shortcuts" => [
            %{
              "id" => "help",
              "keys" => "?",
              "description" => "Show keyboard shortcuts",
              "group" => "General"
            },
            %{
              "id" => "nav-c",
              "keys" => "g c",
              "description" => "Go to Chat",
              "group" => "Navigation"
            },
            %{"id" => "bad", "keys" => "x", "description" => nil},
            "garbage"
          ]
        })

      assert html =~ "Keyboard shortcuts"
      assert html =~ "Go to Chat"
      assert html =~ "then"
      assert html =~ "Command palette"
      refute html =~ "garbage"

      groups =
        ShellLive.shortcut_groups([%{"keys" => "a", "description" => String.duplicate("d", 500)}])

      assert [{"General", [%{description: description}]}, {"Command palette", _}] = groups
      assert String.length(description) <= 90
    end
  end

  describe "notifications" do
    defp approval_event(key, id) do
      Event.new(
        :approval_requested,
        Events.ApprovalRequested.new(%{
          approval_id: id,
          pending:
            Events.ApprovalPending.new(%{
              id: id,
              run_id: "run-#{id}",
              session_key: key,
              tool: "bash"
            })
        })
      )
    end

    defp completed_event(run_id, key, ok, cancelled \\ false) do
      Event.new(
        :run_completed,
        Events.RunCompleted.new(%{
          completed:
            Events.Completion.new(%{ok: ok, answer: "done", meta: %{cancelled: cancelled}}),
          duration_ms: 4_200
        }),
        %{run_id: run_id, session_key: key}
      )
    end

    defp start_run(view, run_id, key) do
      Bus.broadcast(
        RunEvents.topic(),
        {:lemon_web_run, :started, %{run_id: run_id, session_key: key, ok: nil, duration_ms: nil}}
      )

      render(view)
    end

    test "run completion on another page toasts, records and pushes a desktop alert", context do
      view = shell(context)
      key = "agent:shell_notify_#{unique()}:main"
      seed_session(key, "work", "done", "Background build")
      run_id = "run-notify-#{unique()}"
      render_hook(view, "location", %{"path" => "/sessions", "visible" => true})

      start_run(view, run_id, key)
      Bus.broadcast(Bus.run_topic(run_id), completed_event(run_id, key, true))

      html = render(view)
      assert html =~ "Run finished"
      assert html =~ "Background build"
      assert html =~ "took 4.2s"
      assert has_element?(view, ~s(#shell-bell[aria-label="Notifications, 1 unread"]))
      assert_push_event(view, "lemon:notify", %{title: "Run finished", href: href})
      assert href == Palette.chat_path(key)

      # A duplicate terminal event for the same run is ignored.
      Bus.broadcast(Bus.run_topic(run_id), completed_event(run_id, key, true))
      assert has_element?(view, ~s(#shell-bell[aria-label="Notifications, 1 unread"]))

      html = render_click(view, "panel:toggle", %{})
      assert html =~ "notifications-panel"
      assert has_element?(view, ~s(#shell-bell[aria-label="Notifications"]))
    end

    test "failed and cancelled runs are labelled; subagent sessions are skipped", context do
      view = shell(context)
      key = "agent:shell_fail_#{unique()}:main"

      failed = "run-fail-#{unique()}"
      start_run(view, failed, key)
      Bus.broadcast(Bus.run_topic(failed), completed_event(failed, key, false))
      assert render(view) =~ "Run failed"

      stopped = "run-stop-#{unique()}"
      start_run(view, stopped, key)
      Bus.broadcast(Bus.run_topic(stopped), completed_event(stopped, key, false, true))
      assert render(view) =~ "Run stopped"

      sub_key = key <> ":sub:task1"
      sub = "run-sub-#{unique()}"
      start_run(view, sub, sub_key)
      Bus.broadcast(Bus.run_topic(sub), completed_event(sub, sub_key, true))
      refute render(view) =~ "Run finished"
    end

    test "telemetry stop without a bus completion still notifies", context do
      view = shell(context)
      key = "agent:shell_telemetry_#{unique()}:main"
      run_id = "run-telemetry-#{unique()}"

      :telemetry.execute([:lemon, :run, :start], %{ts_ms: 1}, %{run_id: run_id, session_key: key})
      render(view)
      :telemetry.execute([:lemon, :run, :stop], %{duration_ms: 900, ok: true}, %{run_id: run_id})

      assert eventually(fn -> render(view) =~ "Run finished" end, 600)
    end

    test "the session open in the foreground is not notified", context do
      view = shell(context)
      key = "agent:shell_fg_#{unique()}:main"
      run_id = "run-fg-#{unique()}"

      render_hook(view, "location", %{
        "path" => "/chat/#{URI.encode_www_form(key)}",
        "visible" => true
      })

      start_run(view, run_id, key)
      Bus.broadcast(Bus.run_topic(run_id), completed_event(run_id, key, true))
      Bus.broadcast("exec_approvals", approval_event(key, "ap-fg-#{unique()}"))
      html = render(view)
      refute html =~ "Run finished"
      refute html =~ "Approval needed"
      refute_push_event(view, "lemon:notify", _)

      # The split pane counts as foreground too.
      other = "agent:shell_bg_#{unique()}:main"

      render_hook(view, "location", %{
        "path" => "/chat/x?split=#{URI.encode_www_form(other)}",
        "visible" => true
      })

      Bus.broadcast("exec_approvals", approval_event(other, "ap-split-#{unique()}"))
      refute render(view) =~ "Approval needed"

      # A hidden tab is not foreground: notify (desktop alert while hidden).
      render_hook(view, "location", %{
        "path" => "/chat/#{URI.encode_www_form(key)}",
        "visible" => false
      })

      id = "ap-hidden-#{unique()}"
      Bus.broadcast("exec_approvals", approval_event(key, id))
      assert render(view) =~ "Approval needed: bash"
      assert_push_event(view, "lemon:notify", %{title: "Approval needed: bash"})

      # Resolution removes the pending approval toast.
      Bus.broadcast(
        "exec_approvals",
        Event.new(
          :approval_resolved,
          Events.ApprovalResolved.new(%{
            approval_id: id,
            decision: :approve_once,
            pending: Events.ApprovalPending.new(%{id: id, session_key: key, tool: "bash"})
          })
        )
      )

      refute has_element?(view, "#toast-approval-#{id}")
    end

    test "preferences gate toasts and alerts but keep bell history", context do
      view = shell(context)

      render_hook(view, "notify:init", %{
        "prefs" => %{"runs" => true, "approvals" => false},
        "permission" => "granted"
      })

      key = "agent:shell_prefs_#{unique()}:main"
      Bus.broadcast("exec_approvals", approval_event(key, "ap-pref-#{unique()}"))

      render(view)
      refute has_element?(view, "#shell-toasts [id^=toast-]")
      refute_push_event(view, "lemon:notify", _)
      assert has_element?(view, ~s(#shell-bell[aria-label="Notifications, 1 unread"]))

      render_click(view, "notify:pref", %{"kind" => "approvals"})
      assert_push_event(view, "lemon:notify-prefs", %{approvals: true, runs: true})
      Bus.broadcast("exec_approvals", approval_event(key, "ap-pref2-#{unique()}"))
      assert render(view) =~ "Approval needed: bash"
    end

    test "history is bounded to 20 entries", context do
      view = shell(context)
      key = "agent:shell_bound_#{unique()}:main"

      for i <- 1..25,
          do: Bus.broadcast("exec_approvals", approval_event(key, "ap-bound-#{i}-#{unique()}"))

      render(view)
      html = render_click(view, "panel:open", %{})
      # 20 history rows; opening the panel dismisses the (3) toasts.
      assert length(Regex.scan(~r/Approval needed: bash/, html)) == 20
      refute has_element?(view, "#shell-toasts [id^=toast-]")
    end
  end

  describe "helpers" do
    test "parse_location extracts the chat and split keys" do
      assert %{chat: "agent:a:main", split: "agent:b:main", visible: true} =
               ShellLive.parse_location("/chat/agent%3Aa%3Amain?split=agent%3Ab%3Amain", true)

      assert %{chat: nil, split: nil} = ShellLive.parse_location("/sessions?split=x", true)
    end

    test "fuzzy scoring prefers prefixes and tight subsequences" do
      assert Palette.score("ses", "Sessions") > Palette.score("ses", "Usage sessions")
      assert Palette.score("nss", "New session") != nil
      assert Palette.score("zz", "Sessions") == nil
      assert Palette.parse_query("/ deploy ", :all) == {:search, "deploy"}
      assert Palette.parse_query("deploy", :search) == {:search, "deploy"}
      assert Palette.clean("a\nb\u0000c") == "a b c"
    end
  end
end
