defmodule LemonWeb.WorkManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  alias LemonAutomation.{CronManager, GoalLoopManager, KanbanDispatcher}
  alias LemonWeb.CronText

  setup :configure_operator_token

  setup do
    old = Application.get_env(:lemon_web, :work_service_fun)
    state = start_supervised!({Agent, fn -> fixture() end})

    Application.put_env(:lemon_web, :work_service_fun, fn module, function, args ->
      service(state, module, function, args)
    end)

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_web, :work_service_fun, old),
        else: Application.delete_env(:lemon_web, :work_service_fun)
    end)

    %{state: state}
  end

  test "route requires operator login and never forwards a query token" do
    conn = get(build_conn(), "/automation?tab=cron&token=leaked-token")
    location = redirected_to(conn, 302)
    assert URI.decode_query(URI.parse(location).query) == %{"return_to" => "/automation?tab=cron"}
    refute location =~ "leaked-token"

    clear_operator_token()
    assert get(build_conn(), "/automation") |> response(503) =~ "operator token"
  end

  test "connected refresh updates bounded cards and excludes private data from socket state", %{
    conn: conn,
    state: state
  } do
    {:ok, view, html} = live(conn, "/automation")
    assert html =~ "Safe board"
    assert has_element?(view, "#work-card-task_demo")
    assert has_element?(view, "a[href='/chat/#{URI.encode_www_form("agent:default:main")}']")
    refute_private(html)
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))

    Agent.update(state, &put_in(&1.card.title, "Updated card"))
    send(view.pid, :work_tick)
    assert render(view) =~ "Updated card"
    render_click(view, "tab", %{"tab" => "goals"})
    assert_patch(view, "/automation?tab=goals")
    assert has_element?(view, "#work-goal-goal_demo")
    refute_private(render(view))
    render_click(view, "tab", %{"tab" => "cron"})
    assert has_element?(view, "#work-cron-cron_demo", "Every hour")
    render_click(view, "open-runs", %{"id" => "cron_demo"})
    assert has_element?(view, "#work-runs-drawer #work-run-run_demo")
    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "cron and goal bus events trigger a debounced refresh", %{conn: conn, state: state} do
    {:ok, view, _} = live(conn, "/automation?tab=cron")
    assert has_element?(view, "#work-cron-cron_demo", "Safe cron")
    Agent.update(state, &put_in(&1.job.name, "Renamed cron"))

    LemonAutomation.Events.emit_job_updated(Agent.get(state, & &1.job))
    Process.sleep(350)
    assert has_element?(view, "#work-cron-cron_demo", "Renamed cron")
  end

  test "legacy TUI goal remains visible without unsafe controls or a false transcript", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, fn data ->
      data
      |> put_in([:goal, :session_key], "tui-20261013T062900")
      |> put_in([:goal, :status], "paused")
    end)

    {:ok, view, _} = live(conn, "/automation")
    render_click(view, "tab", %{"tab" => "goals"})
    assert has_element?(view, "#work-goal-goal_demo")
    assert render(view) =~ "paused"
    refute has_element?(view, "#work-goal-goal_demo a[href^='/chat/']")
    refute has_element?(view, "#work-goal-goal_demo button:not([disabled])")
  end

  test "goal cards show bounded budget progress and loop state", %{conn: conn, state: state} do
    Agent.update(state, fn data ->
      Map.update!(
        data,
        :goal,
        &Map.merge(&1, %{
          budget: %{"max_continuations" => 8},
          meta: %{
            "goalLoop" => %{
              "status" => "finished",
              "verdictCount" => 3,
              "lastVerdict" => %{"action" => "blocked", "reason" => "PRIVATE_RESULT"}
            }
          }
        })
      )
    end)

    {:ok, view, _} = live(conn, "/automation?tab=goals")
    assert has_element?(view, "#work-goal-goal_demo", "2 / 8 continuations")
    assert has_element?(view, "#work-goal-goal_demo [role=meter][aria-valuenow='25']")
    assert has_element?(view, "#work-goal-goal_demo", "last verdict: blocked")
    refute_private(render(view))
  end

  test "board columns keep configured workflow order and safe custom status labels", %{
    conn: conn,
    state: state
  } do
    Agent.update(state, fn data ->
      data
      |> put_in([:board, :columns], ["backlog", "shipping", "done", "/private/work"])
      |> put_in([:card, :status], "shipping")
    end)

    {:ok, view, _} = live(conn, "/automation")

    columns =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#work-board-board_demo section")
      |> LazyHTML.attribute("aria-label")

    assert Enum.take(columns, 3) == ["backlog", "shipping", "done"]
    assert has_element?(view, "section[aria-label=shipping] #work-card-task_demo")
    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "reviewed cards expose safe commit and PR links without private review data", %{
    conn: conn,
    state: state
  } do
    workflow = %{
      "phase" => "completed",
      "branch" => "lemon-kanban/task_demo",
      "commitSha" => String.duplicate("a", 40),
      "prUrl" => "https://github.com/lemon/work/pull/12",
      "reviewSessionKey" => "agent:default:main:sub:review_demo",
      "review" => %{"approved" => true, "findings" => "PRIVATE_RESULT"},
      "cwd" => "/private/work",
      "codingOutput" => "PRIVATE_RESULT"
    }

    Agent.update(
      state,
      &Map.update!(&1, :card, fn card -> Map.put(card, :meta, %{"codingWorkflow" => workflow}) end)
    )

    {:ok, view, html} = live(conn, "/automation")
    assert html =~ "Independent review approved"
    assert html =~ "aaaaaaaaaaaa"

    assert has_element?(
             view,
             "a[href='https://github.com/lemon/work/pull/12']",
             "Open pull request"
           )

    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
    Agent.update(state, &put_in(&1.card.meta["codingWorkflow"]["prUrl"], "javascript:alert(1)"))
    send(view.pid, :work_tick)
    refute render(view) =~ "javascript:"
    refute has_element?(view, "a", "Open pull request")

    Agent.update(
      state,
      &put_in(
        &1.card.meta["codingWorkflow"]["prUrl"],
        "https://github.com:65536/lemon/work/pull/12"
      )
    )

    send(view.pid, :work_tick)
    refute render(view) =~ "github.com:65536"
    refute has_element?(view, "a", "Open pull request")
  end

  test "terminal failures, retries and transcript links survive the content-free projection", %{
    conn: conn,
    state: state
  } do
    run_session = "agent:default:web:browser:unknown:cron_run_demo"

    Agent.update(state, fn data ->
      data
      |> Map.update!(
        :card,
        &Map.put(&1, :meta, %{
          "kanbanRun" => %{"status" => "failed", "output" => "PRIVATE_RESULT"},
          "lastFailure" => %{"reason" => "PRIVATE_RESULT"},
          "kanbanLease" => %{"attempt" => 3}
        })
      )
      |> Map.update!(
        :goal,
        &Map.put(&1, :meta, %{
          "lastResult" => %{"status" => "failed", "output" => "PRIVATE_RESULT"}
        })
      )
      |> Map.update!(:run, &%{&1 | meta: %{router_session_key: run_session, retry_attempt: 2}})
    end)

    {:ok, view, _} = live(conn, "/automation")
    assert has_element?(view, "#work-card-task_demo", "failed")
    assert has_element?(view, "#work-card-task_demo", "needs retry")
    assert has_element?(view, "#work-card-task_demo", "attempt 3")
    render_click(view, "tab", %{"tab" => "goals"})
    assert has_element?(view, "#work-goal-goal_demo", "failed")
    render_click(view, "tab", %{"tab" => "cron"})
    render_click(view, "open-runs", %{"id" => "cron_demo"})
    assert has_element?(view, "#work-run-run_demo", "Retry 2")

    assert has_element?(
             view,
             ~s|#work-run-run_demo a[href="/chat/#{URI.encode_www_form(run_session)}"]|
           )

    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "owned ambiguous board runs remain visibly reconciling instead of idle", %{
    conn: conn,
    state: state
  } do
    Application.put_env(:lemon_web, :work_service_fun, fn
      KanbanDispatcher, :status, _ ->
        {:ok,
         %{
           running: false,
           control_revision: "held_revision",
           dispatcher: nil,
           reconciling_count: 1
         }}

      module, function, args ->
        service(state, module, function, args)
    end)

    {:ok, view, _} = live(conn, "/automation")
    assert has_element?(view, "#work-board-board_demo", "reconciling")
    refute has_element?(view, "#work-boards-board_demo-start")
    refute has_element?(view, "#work-boards-board_demo-stop")
  end

  test "all controls use exact service targets and bounded goal settings", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = live(conn, "/automation")
    preview(view, "boards", "board_demo", "start")

    assert has_element?(
             view,
             "#work-confirm-dialog",
             "Starts this board with one concurrent worker"
           )

    assert Agent.get(state, & &1.calls) == []
    render_click(view, "confirm")
    assert has_element?(view, "#work-boards-board_demo-stop")
    preview(view, "boards", "board_demo", "stop")
    render_click(view, "confirm")
    assert has_element?(view, "#work-boards-board_demo-start")

    render_click(view, "tab", %{"tab" => "goals"})
    preview(view, "goals", "goal_demo", "start")
    render_click(view, "confirm")

    assert {GoalLoopManager, :start_loop, ["agent:default:main", opts]} =
             Agent.get(state, &Enum.find(&1.calls, fn {_, fun, _} -> fun == :start_loop end))

    assert opts[:max_ticks] == 3
    assert opts[:auto] == false
    preview(view, "goals", "goal_demo", "stop")
    render_click(view, "confirm")
    preview(view, "goals", "goal_demo", "pause")
    render_click(view, "confirm")
    assert has_element?(view, "#work-goals-goal_demo-resume")
    preview(view, "goals", "goal_demo", "resume")
    render_click(view, "confirm")

    render_click(view, "tab", %{"tab" => "cron"})
    preview(view, "cron", "cron_demo", "pause")
    render_click(view, "confirm")
    assert has_element?(view, "#work-cron-cron_demo-resume")
    preview(view, "cron", "cron_demo", "resume")
    render_click(view, "confirm")

    assert has_element?(view, "#work-row-abort-run_demo")

    render_click(view, "preview", %{
      "kind" => "cron",
      "id" => "cron_demo",
      "action" => "abort",
      "run" => "run_demo"
    })

    render_click(view, "confirm")

    assert {CronManager, :abort_run, ["run_demo", revision]} =
             Agent.get(state, &List.last(&1.calls))

    assert byte_size(revision) == 64
    preview(view, "cron", "cron_demo", "run")
    render_click(view, "confirm")
    assert {CronManager, :run_now, ["cron_demo", _]} = Agent.get(state, &List.last(&1.calls))
  end

  test "remove is previewed, revision bound and refused while a run is active", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = live(conn, "/automation?tab=cron")
    refute has_element?(view, "#work-cron-cron_demo-remove")
    preview(view, "cron", "cron_demo", "remove")
    assert Agent.get(state, & &1.calls) == []

    Agent.update(state, &put_in(&1.run.status, :completed))
    send(view.pid, :work_tick)
    assert has_element?(view, "#work-cron-cron_demo-remove")
    preview(view, "cron", "cron_demo", "remove")
    assert has_element?(view, "#work-confirm-dialog", "cannot be undone")
    Agent.update(state, &put_in(&1.job.name, "Changed elsewhere"))
    assert render_click(view, "confirm") =~ "State changed since preview"
    assert Agent.get(state, & &1.calls) == []

    preview(view, "cron", "cron_demo", "remove")
    render_click(view, "confirm")

    assert {CronManager, :remove, ["cron_demo", revision]} =
             Agent.get(state, &List.last(&1.calls))

    assert byte_size(revision) == 64
    assert has_element?(view, "#work-empty")
  end

  test "stopping a run from the drawer keeps the drawer open after confirmation", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = live(conn, "/automation?tab=cron")
    render_click(view, "open-runs", %{"id" => "cron_demo"})

    render_click(view, "preview", %{
      "kind" => "cron",
      "id" => "cron_demo",
      "action" => "abort",
      "run" => "run_demo"
    })

    refute has_element?(view, "#work-runs-drawer")
    render_click(view, "close-runs")
    render_click(view, "confirm")
    assert {CronManager, :abort_run, ["run_demo", _]} = Agent.get(state, &List.last(&1.calls))
    assert has_element?(view, "#work-runs-drawer #work-run-run_demo", "aborted")
  end

  test "stale preview and forged targets never reach mutation", %{conn: conn, state: state} do
    {:ok, view, _} = live(conn, "/automation")
    assert render_click(view, "confirm") =~ "Preview the exact action"
    preview(view, "boards", "missing", "start")
    assert Agent.get(state, & &1.calls) == []
    preview(view, "boards", "board_demo", "start")
    Agent.update(state, &Map.put(&1, :revision, "changed"))
    assert render_click(view, "confirm") =~ "State changed since preview"
    assert Agent.get(state, & &1.calls) == []

    render_click(view, "tab", %{"tab" => "cron"})

    render_click(view, "preview", %{
      "kind" => "cron",
      "id" => "cron_demo",
      "action" => "abort",
      "run" => "run_demo"
    })

    Agent.update(state, &put_in(&1.run.id, "run_replacement"))
    assert render_click(view, "confirm") =~ "State changed since preview"
    assert Agent.get(state, & &1.calls) == []
  end

  test "initial and live lookup failures are unavailable, not idle", %{conn: conn, state: state} do
    Agent.update(state, &Map.put(&1, :unavailable, true))
    {:ok, view, html} = live(conn, "/automation")
    assert html =~ "Service unavailable"
    refute has_element?(view, "#work-empty")
    Agent.update(state, &Map.put(&1, :unavailable, false))
    render_click(view, "refresh")
    assert render(view) =~ "Safe board"
    Agent.update(state, &Map.put(&1, :runtime_unavailable, true))
    render_click(view, "refresh")
    assert render(view) =~ "unavailable"
    assert has_element?(view, "#work-card-task_demo")
    assert render(view) =~ "Last known dispatcher: idle"
    refute has_element?(view, "#work-boards-board_demo-start")
    preview(view, "boards", "board_demo", "start")
    assert Agent.get(state, & &1.calls) == []
    Agent.update(state, &Map.put(&1, :unavailable, true))
    render_click(view, "refresh")
    assert render(view) =~ "Service unavailable"
    assert has_element?(view, "#work-card-task_demo")
  end

  test "unknown mutation outcomes are honest and not repeated", %{conn: conn, state: state} do
    {:ok, view, _} = live(conn, "/automation")
    Agent.update(state, &Map.put(&1, :unknown, true))
    preview(view, "boards", "board_demo", "start")
    assert render_click(view, "confirm") =~ "Outcome unknown"
    preview(view, "boards", "board_demo", "start")
    render_click(view, "confirm")
    assert length(Agent.get(state, & &1.calls)) == 1
    assert has_element?(view, "#work-boards-board_demo-start[disabled]")
  end

  test "create cron validates, previews the schedule and never retains the prompt", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = live(conn, "/automation?tab=cron")
    render_click(view, "new-cron")
    assert has_element?(view, "#cron-form-modal")
    assert has_element?(view, "#cron-schedule-preview", "Daily at 09:00")
    render_click(view, "schedule-preset", %{"preset" => "every 15m"})
    assert has_element?(view, "#cron-schedule-preview", "Every 15 minutes")
    assert has_element?(view, "#cron-schedule[value='every 15m']")

    html =
      render_change(view, "validate-cron", %{
        "cron" => form(%{"schedule" => "weekdays at 09:30", "prompt" => "PRIVATE_PROMPT"})
      })

    assert html =~ "Weekdays at 09:30"
    assert html =~ "30 9 * * 1-5"
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))

    html =
      render_submit(view, "save-cron", %{
        "cron" => form(%{"name" => "", "schedule" => "every 7m", "prompt" => "PRIVATE_PROMPT"})
      })

    assert html =~ "Enter a name."
    assert html =~ "Minute interval must evenly divide 60"
    assert Agent.get(state, & &1.calls) == []

    render_submit(view, "save-cron", %{
      "cron" => form(%{"name" => "Daily digest", "prompt" => "PRIVATE_PROMPT"})
    })

    assert {CronManager, :add, [attrs]} = Agent.get(state, &List.last(&1.calls))
    assert attrs.name == "Daily digest"
    assert attrs.schedule == "0 9 * * *"
    assert attrs.agent_id == "default"
    assert attrs.session_key == "agent:default:main"
    assert attrs.prompt == "PRIVATE_PROMPT"
    assert attrs.timeout_ms == 300_000
    refute has_element?(view, "#cron-form-modal")
    assert render(view) =~ "Cron job created"
    refute_private(render(view))
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "edit cron sends only changed fields bound to the opened revision", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = live(conn, "/automation?tab=cron")
    render_click(view, "edit-cron", %{"id" => "cron_demo"})
    assert has_element?(view, "#cron-form-modal", "Edit cron job")
    assert has_element?(view, "#cron-schedule-preview", "Every hour")
    refute render(view) =~ "PRIVATE_PROMPT"

    [name] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#cron-name")
      |> LazyHTML.attribute("value")

    render_submit(view, "save-cron", %{
      "cron" => %{
        "name" => name,
        "schedule" => "0 * * * *",
        "timezone" => "UTC",
        "timeout_minutes" => "5",
        "enabled" => "true",
        "prompt" => ""
      }
    })

    assert render(view) =~ "Nothing changed"
    assert Agent.get(state, & &1.calls) == []

    render_click(view, "edit-cron", %{"id" => "cron_demo"})
    Agent.update(state, &put_in(&1.job.name, "Changed elsewhere"))

    html =
      render_submit(view, "save-cron", %{
        "cron" => %{
          "schedule" => "daily at 6am",
          "timezone" => "local",
          "timeout_minutes" => "5",
          "enabled" => "true",
          "name" => "Changed elsewhere"
        }
      })

    assert html =~ "State changed since preview"
    assert Agent.get(state, & &1.calls) == []

    render_click(view, "close-cron-form")
    render_click(view, "edit-cron", %{"id" => "cron_demo"})

    render_submit(view, "save-cron", %{
      "cron" => %{
        "name" => "Changed elsewhere",
        "schedule" => "daily at 6am",
        "timezone" => "local",
        "timeout_minutes" => "5",
        "enabled" => "true",
        "prompt" => "New PRIVATE_PROMPT"
      }
    })

    assert {CronManager, :update, ["cron_demo", patch, revision]} =
             Agent.get(state, &List.last(&1.calls))

    assert patch == %{schedule: "0 6 * * *", timezone: "local", prompt: "New PRIVATE_PROMPT"}
    assert byte_size(revision) == 64
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "new goal validates input and writes the objective without retaining it", %{
    conn: conn,
    state: state
  } do
    {:ok, view, _} = live(conn, "/automation?tab=goals")
    render_click(view, "new-goal")
    assert has_element?(view, "#goal-form-modal", "already has a goal")

    html =
      render_submit(view, "save-goal", %{
        "goal" => %{"session" => "not a key", "objective" => "", "max_continuations" => "0"}
      })

    assert html =~ "Enter a valid session key"
    assert html =~ "Describe the goal."
    assert html =~ "Use a number from 1 to 1000."
    assert Agent.get(state, & &1.calls) == []

    render_submit(view, "save-goal", %{
      "goal" => %{
        "session" => "agent:ops:main",
        "objective" => "PRIVATE_OBJECTIVE",
        "max_continuations" => "12"
      }
    })

    assert {GoalLoopManager, :set_goal, ["agent:ops:main", "PRIVATE_OBJECTIVE", opts]} =
             Agent.get(state, &List.last(&1.calls))

    assert opts[:budget] == %{"max_continuations" => 12}
    assert render(view) =~ "Goal set"
    refute_private(inspect(:sys.get_state(view.pid), limit: :infinity))
  end

  test "filter narrows the active tab by safe labels", %{conn: conn} do
    {:ok, view, _} = live(conn, "/automation?tab=cron")
    render_change(view, "filter", %{"filter" => "nothing-matches"})
    refute has_element?(view, "#work-cron-cron_demo")
    assert render(view) =~ "Nothing matches"
    render_change(view, "filter", %{"filter" => "safe cron"})
    assert has_element?(view, "#work-cron-cron_demo")
  end

  test "real dispatcher starts and stops only the previewed invocation", %{conn: conn} do
    {:ok, board} = KanbanStore.create_board("Web controlled empty board")
    dispatcher = start_supervised!({KanbanDispatcher, name: __MODULE__.Dispatcher})
    on_exit(fn -> KanbanStore.clear_board(board.id) end)

    Application.put_env(:lemon_web, :work_service_fun, fn
      KanbanStore, :list_boards, _ ->
        {:ok, [KanbanStore.get_board(board.id)]}

      KanbanStore, :list_tasks, args ->
        apply(KanbanStore, :list_tasks, args)

      GoalStore, :list, _ ->
        {:ok, []}

      CronManager, :list, _ ->
        []

      KanbanDispatcher, :status, [id] ->
        KanbanDispatcher.status(id, name: dispatcher)

      KanbanDispatcher, fun, [id, opts] ->
        apply(KanbanDispatcher, fun, [id, Keyword.put(opts, :name, dispatcher)])
    end)

    {:ok, view, _} = live(conn, "/automation")
    preview(view, "boards", board.id, "start")
    render_click(view, "confirm")

    assert {:ok, %{running: true, control_revision: revision}} =
             KanbanDispatcher.status(board.id, name: dispatcher)

    preview(view, "boards", board.id, "stop")
    render_click(view, "confirm")
    assert {:ok, %{running: false}} = KanbanDispatcher.status(board.id, name: dispatcher)

    assert {:error, :stale} =
             KanbanDispatcher.stop_board(board.id, name: dispatcher, expected_revision: revision)

    {:ok, _} = KanbanDispatcher.start_board(board.id, name: dispatcher)

    assert {:error, :stale} =
             KanbanDispatcher.stop_board(board.id, name: dispatcher, expected_revision: revision)

    assert {:ok, %{running: true}} = KanbanDispatcher.status(board.id, name: dispatcher)
    KanbanDispatcher.stop_board(board.id, name: dispatcher)
  end

  test "cron schedules are described in plain language" do
    assert CronText.describe("* * * * *") == "Every minute"
    assert CronText.describe("*/15 * * * *") == "Every 15 minutes"
    assert CronText.describe("0 * * * *") == "Every hour"
    assert CronText.describe("30 */2 * * *") == "Every 2 hours at :30"
    assert CronText.describe("0 9 * * *") == "Daily at 09:00"
    assert CronText.describe("30 9 * * 1-5") == "Weekdays at 09:30"
    assert CronText.describe("0 8 * * 1") == "Every Monday at 08:00"
    assert CronText.describe("0 0 1 * *") == "Monthly on the 1st at 00:00"
    assert CronText.describe("0 0 1 1 *") == "Yearly on January 1 at 00:00"
    assert CronText.describe("0,30 * * * *") == "Every hour at :00, :30"
    assert CronText.describe("5 4 1-7 * 2") == "Custom schedule"
    assert CronText.describe("Custom schedule") == "Custom schedule"
  end

  defp preview(view, kind, id, action),
    do: render_click(view, "preview", %{"kind" => kind, "id" => id, "action" => action})

  defp form(overrides) do
    Map.merge(
      %{
        "name" => "Digest",
        "schedule" => "daily at 9am",
        "timezone" => "UTC",
        "agent" => "default",
        "timeout_minutes" => "5",
        "enabled" => "true",
        "prompt" => ""
      },
      overrides
    )
  end

  defp refute_private(text) do
    for secret <- [
          "PRIVATE_OBJECTIVE",
          "PRIVATE_PROMPT",
          "PRIVATE_RESULT",
          "/private/work",
          "relative/private.txt",
          "supersecretvalue",
          "PRIVATE_ENV"
        ] do
      refute text =~ secret
    end
  end

  defp fixture do
    %{
      board: %{
        id: "board_demo",
        name: "Safe board /private/work token=supersecretvalue",
        status: "active",
        columns: ~w(todo doing review done),
        workspace: "/private/work"
      },
      card: %{
        id: "task_demo",
        title: "Safe card relative/private.txt",
        status: "todo",
        description: "PRIVATE_PROMPT",
        session_key: "agent:default:main"
      },
      goal: %{
        id: "goal_demo",
        session_key: "agent:default:main",
        status: "active",
        objective: "PRIVATE_OBJECTIVE",
        cwd: "/private/work",
        continuation_count: 2
      },
      job:
        struct(LemonAutomation.CronJob, %{
          id: "cron_demo",
          name: "Safe cron /private/work",
          enabled: true,
          session_key: "agent:default:main",
          agent_id: "default",
          schedule: "0 * * * *",
          timezone: "UTC",
          timeout_ms: 300_000,
          next_run_at_ms: nil,
          prompt: "PRIVATE_PROMPT",
          env: %{"PRIVATE_ENV" => "supersecretvalue"}
        }),
      run:
        struct(LemonAutomation.CronRun, %{
          id: "run_demo",
          job_id: "cron_demo",
          status: :running,
          triggered_by: :manual,
          duration_ms: nil,
          output: "PRIVATE_RESULT",
          meta: %{}
        }),
      board_running: false,
      goal_running: false,
      revision: "initial",
      calls: [],
      unavailable: false,
      runtime_unavailable: false,
      unknown: false
    }
  end

  defp service(pid, module, function, args) do
    state = Agent.get(pid, & &1)
    if state.unavailable, do: exit({:service_unavailable, "/private/work"})

    case {module, function, args} do
      {KanbanStore, :list_boards, _} ->
        {:ok, [state.board]}

      {KanbanStore, :list_tasks, _} ->
        {:ok, [state.card]}

      {GoalStore, :list, _} ->
        {:ok, [state.goal]}

      {CronManager, :list, _} ->
        if state.job, do: [state.job], else: []

      {CronManager, :runs, _} ->
        {:ok, [state.run]}

      {KanbanDispatcher, :status, _} ->
        runtime(state, :board_running, :dispatcher)

      {GoalLoopManager, :status, _} ->
        runtime(state, :goal_running, :loop)

      _ ->
        Agent.update(
          pid,
          &Map.update!(&1, :calls, fn calls -> calls ++ [{module, function, args}] end)
        )

        cond do
          state.unknown ->
            {:error, :outcome_unknown}

          function == :add ->
            {:ok, %{id: "cron_new"}}

          true ->
            Agent.update(pid, &mutate(&1, function, args))
            {:ok, %{}}
        end
    end
  end

  defp runtime(%{runtime_unavailable: true}, _, _), do: {:error, :unavailable}

  defp runtime(state, field, key) do
    {:ok,
     %{
       key => %{status: "running", running_count: 0},
       :running => state[field],
       :control_revision => state.revision
     }}
  end

  defp mutate(state, :start_board, _),
    do: %{state | board_running: true, revision: "board_started"}

  defp mutate(state, :stop_board, _),
    do: %{state | board_running: false, revision: "board_stopped"}

  defp mutate(state, :start_loop, _), do: %{state | goal_running: true, revision: "goal_started"}
  defp mutate(state, :stop_loop, _), do: %{state | goal_running: false, revision: "goal_stopped"}

  defp mutate(state, :transition_goal, [_, action, _]),
    do: put_in(state.goal.status, if(action == :pause, do: "paused", else: "active"))

  defp mutate(state, :update, [_, attrs, _]), do: %{state | job: struct(state.job, attrs)}
  defp mutate(state, :remove, _), do: %{state | job: nil}
  defp mutate(state, :abort_run, _), do: put_in(state.run.status, :aborted)
  defp mutate(state, :run_now, _), do: put_in(state.run.status, :running)
  defp mutate(state, :set_goal, _), do: state
end
