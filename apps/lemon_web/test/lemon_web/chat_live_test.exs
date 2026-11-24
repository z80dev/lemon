defmodule LemonWeb.ChatLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonCore.{Event, ExecApprovals, ExecApprovalStore}
  alias LemonWeb.Chat.PaneLive

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend
    def init(_), do: {:ok, %{}}
    def put(_, _, _, _), do: {:error, :sqlite_busy}
    def put_new(_, _, _, _), do: {:error, :sqlite_busy}
    def get(_, _, _), do: {:error, :sqlite_busy}
    def delete(_, _, _), do: {:error, :sqlite_busy}
    def list(_, _), do: {:error, {:sqlite_busy, "private-backend-detail"}}
  end

  setup :configure_operator_token

  setup do
    previous =
      Map.new(
        [:chat_rpc_stub, :setup_readiness_fun, :upload_persist_fun],
        &{&1, Application.get_env(:lemon_web, &1)}
      )

    test_pid = self()
    {:ok, stubs} = Agent.start_link(fn -> %{} end)

    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness(true) end)

    Application.put_env(:lemon_web, :chat_rpc_stub, fn method, params ->
      send(test_pid, {:rpc, method, params})

      case Agent.get(stubs, &Map.get(&1, method)) do
        nil -> default_stub(method, params)
        fun when is_function(fun, 1) -> fun.(params)
        result -> result
      end
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)
    end)

    %{stub: fn method, result -> Agent.update(stubs, &Map.put(&1, method, result)) end}
  end

  # Methods the pane calls on mount; everything else reaches the real registry.
  defp default_stub("sessions.active", %{"sessionKey" => key}),
    do: {:ok, %{"sessionKey" => key, "runId" => nil}}

  defp default_stub("chat.history", _), do: {:ok, %{"messages" => []}}

  # A live idle owner whose event stream has not moved yet (live batches
  # start at seq 1 of "stream-1"), reporting the session's real pending
  # approvals the way `sessions.snapshot` projects them.
  defp default_stub("sessions.snapshot", %{"sessionKey" => key}) do
    {:ok, pending} = ExecApprovalStore.fetch_pending_list()

    items =
      for {_id, approval} <- Enum.sort_by(pending, &elem(&1, 0)),
          Map.get(approval, :session_key) == key,
          do: LemonControlPlane.Methods.ExecApprovalsGet.format_pending(approval)

    {:ok,
     key
     |> recovery_snapshot(nil, "idle", [])
     |> put_in(["snapshot", "approvals", "items"], items)}
  end

  defp default_stub("sessions.events", _),
    do: {:error, {:unavailable, "Replay fixture is not configured", nil}}

  defp default_stub("sessions.plan", %{"sessionKey" => key}),
    do:
      {:ok,
       %{"sessionKey" => key, "plan" => %{"mode" => "code", "path" => nil, "content" => nil}}}

  defp default_stub("sessions.context", _),
    do: {:error, {:unavailable, "Context is unavailable", nil}}

  defp default_stub(_method, _params), do: :passthrough

  test "model and compaction failures show next steps without raw terms" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, compacting: true}}

    for result <- [
          {:ok, {:error, {:unavailable, "PRIVATE_FAILURE", nil}}},
          {:exit, :PRIVATE_FAILURE}
        ] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, models} = PaneLive.handle_async(:models, result, socket)

          assert models.assigns.models ==
                   {:error, "Models are unavailable. Try again, or check /diagnostics."}

          assert {:noreply, compact} =
                   PaneLive.handle_async(:compact, result, socket)

          refute compact.assigns.compacting

          assert compact.assigns.toast.text ==
                   "Compaction did not complete. Try again, or check /diagnostics."
        end)

      assert log =~ "PRIVATE_FAILURE"
    end
  end

  test "a refused first submission shows diagnostics rather than the service error", %{
    conn: conn,
    stub: stub
  } do
    stub.("chat.send", {:error, {:unavailable, "PRIVATE_FAILURE", nil}})
    {_view, pane} = open(conn, key("submit-error"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_submit(pane, "send", %{"chat" => %{"prompt" => "hello", "mode" => "collect"}})
      end)

    assert log =~ "PRIVATE_FAILURE"

    assert has_element?(
             pane,
             "[id^=submit-error-]",
             "Lemon could not start that run. Check /diagnostics and try again."
           )

    refute render(pane) =~ "PRIVATE_FAILURE"
  end

  # ── Mounting, routes and validation ─────────────────────────────────────

  test "home renders the new-session form, and starting a session sends chat.send then opens it",
       %{conn: conn, stub: stub} do
    stub.("chat.send", {:ok, %{"runId" => "run-home"}})
    {:ok, view, html} = live(conn, "/")
    assert html =~ "What should Lemon work on?"
    assert has_element?(view, "#home-form textarea#home-prompt")

    view
    |> form("#home-form", home: %{prompt: "Add a farewell helper", cwd: System.tmp_dir!()})
    |> render_submit()

    assert_receive {:rpc, "chat.send",
                    %{"sessionKey" => key, "prompt" => "Add a farewell helper", "cwd" => cwd}}

    assert cwd == Path.expand(System.tmp_dir!())
    assert key =~ ~r/^agent:default:web:browser:unknown:tab-/
    assert_patch(view, "/chat/" <> URI.encode_www_form(key))

    # The first prompt shows in the new pane before history has it.
    [pane] = panes(view)
    assert has_element?(pane, "[data-kind=user]", "Add a farewell helper")
  end

  test "home refuses a missing workspace and incomplete setup without calling chat.send", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#home-form", home: %{prompt: "go", cwd: "/definitely/not/here"})
    |> render_submit()

    assert has_element?(view, "#home-error", "existing absolute directory")
    refute_received {:rpc, "chat.send", _}

    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness(false) end)
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Finish setup before chatting"
    assert has_element?(view, "#home-prompt[disabled]")
    render_submit(view, "home-start", %{"home" => %{"prompt" => "go", "cwd" => ""}})
    refute_received {:rpc, "chat.send", _}
  end

  test "invalid session keys redirect home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/chat/not-a-session-key")
  end

  test "split view mounts two independent panes", %{conn: conn} do
    a = key("split-a")
    b = key("split-b")
    {:ok, view, _html} = live(conn, "/chat/#{a}?split=#{b}")
    panes = panes(view)
    assert length(panes) == 2
    assert Enum.any?(panes, &(render(&1) =~ ~s(data-role="secondary")))
    assert_received {:rpc, "sessions.active", %{"sessionKey" => ^a}}
    assert_received {:rpc, "sessions.active", %{"sessionKey" => ^b}}
  end

  # ── Transcript ──────────────────────────────────────────────────────────

  test "history loads with full text, merges tool rows and renders markdown in .md", %{
    conn: conn,
    stub: stub
  } do
    stub.("chat.history", fn params ->
      assert params["includeFullText"] == true

      {:ok,
       %{
         "messages" => [
           %{"id" => "m1", "role" => "user", "content" => "List files", "timestampMs" => 1},
           %{
             "id" => "t1",
             "role" => "tool_use",
             "toolCallId" => "c1",
             "toolName" => "bash",
             "arguments" => %{"command" => "ls -1"},
             "phase" => "started",
             "timestampMs" => 2
           },
           %{
             "id" => "t2",
             "role" => "tool_result",
             "toolCallId" => "c1",
             "toolName" => "bash",
             "content" => "README.md",
             "phase" => "completed",
             "ok" => true,
             "details" => %{"exit_code" => 0},
             "timestampMs" => 3
           },
           %{
             "id" => "m2",
             "role" => "assistant",
             "content" => "# Done\n\n```elixir\nIO.puts(1)\n```",
             "timestampMs" => 4
           }
         ]
       }}
    end)

    {_view, pane} = open(conn, key("history"))
    assert has_element?(pane, "[data-kind=user]", "List files")
    assert has_element?(pane, "details.tool-card[data-tool=bash][data-status=done]", "README.md")
    assert has_element?(pane, "details.tool-card", "exit 0")
    assert count(pane, "details.tool-card") == 1
    assert has_element?(pane, "[data-kind=assistant] .md h1", "Done")
    assert has_element?(pane, ".md pre code.language-elixir")
  end

  test "streaming deltas coalesce into one reply and completion never duplicates it", %{
    conn: conn
  } do
    k = key("stream")
    {_view, pane} = open(conn, k)

    emit(pane, k, delta("run-s", 1, "Hello"))
    emit(pane, k, delta("run-s", 2, " world"))
    # A redelivered batch is at or behind the cursor and is applied once.
    emit(pane, k, delta("run-s", 2, " world"), seq: 2)

    eventually(fn ->
      has_element?(pane, "[data-kind=assistant][data-streaming=true]", "Hello world")
    end)

    refute render(pane) =~ "Hello world world"

    emit(pane, k, completed("run-s", "Hello world"))

    eventually(fn ->
      has_element?(pane, "[data-kind=assistant][data-streaming=false]", "Hello world")
    end)

    assert count(pane, "[data-kind=assistant]") == 1

    # A run that streamed nothing appends its final answer once.
    emit(pane, k, completed("run-quiet", "Quiet answer"))
    eventually(fn -> has_element?(pane, "[data-kind=assistant]", "Quiet answer") end)
    assert count(pane, "[data-kind=assistant]") == 2
  end

  test "unsequenced session-topic deltas and tools are never rendered", %{conn: conn} do
    k = key("unsequenced")
    {_view, pane} = open(conn, k)
    send(pane.pid, delta("run-u", 1, "UNSEQUENCED TEXT"))
    send(pane.pid, action("run-u", "c-u", :started, %{name: "bash", tool_call_id: "c-u"}))
    emit(pane, k, delta("run-u", 1, "sequenced text"))
    eventually(fn -> has_element?(pane, "[data-kind=assistant]", "sequenced text") end)
    refute render(pane) =~ "UNSEQUENCED TEXT"
    refute has_element?(pane, "details.tool-card")
  end

  test "a tool start splits the reply into segments around the card", %{conn: conn} do
    k = key("segments")
    {_view, pane} = open(conn, k)
    emit(pane, k, delta("run-g", 1, "Let me look."))

    emit(
      pane,
      k,
      action("run-g", "c-read", :started, %{
        name: "read",
        args: %{"path" => "mix.exs"},
        tool_call_id: "c-read"
      })
    )

    emit(pane, k, [delta("run-g", 2, "Found it."), completed("run-g", "Let me look.Found it.")])
    eventually(fn -> count(pane, "[data-kind=assistant]") == 2 end)
    html = render(pane)
    assert pos(html, "Let me look.") < pos(html, "mix.exs")
    assert pos(html, "mix.exs") < pos(html, "Found it.")
  end

  test "tool cards render per tool type and update in place", %{conn: conn} do
    k = key("tools")
    {_view, pane} = open(conn, k)

    events = [
      {"c-bash", %{name: "bash", args: %{"command" => "ls -la"}},
       %{result: "total 0", details: %{exit_code: 0}}},
      {"c-read", %{name: "read", args: %{"path" => "lib/app.ex", "offset" => 10, "limit" => 5}},
       %{result: "defmodule App do"}},
      {"c-edit",
       %{
         name: "edit",
         args: %{"path" => "app.py", "old_text" => "old line", "new_text" => "new line"}
       }, %{result: "ok"}},
      {"c-grep", %{name: "grep", args: %{"pattern" => "TODO"}},
       %{result: "a.ex:1: TODO\nb.ex:2: TODO", details: %{match_count: 2}}},
      {"c-todo",
       %{
         name: "todo",
         args: %{
           "todos" => [
             %{"content" => "Write tests", "status" => "completed"},
             %{"content" => "Ship", "status" => "pending"}
           ]
         }
       }, %{result: "ok"}},
      {"c-task", %{name: "task", args: %{"description" => "Investigate flake"}},
       %{result: "Found the race", details: %{status: "completed"}}},
      {"c-web", %{name: "webfetch", args: %{"url" => "https://example.com"}},
       %{result: "Example Domain"}},
      {"c-mystery", %{name: "mystery", args: %{"answer" => 42}}, %{result: "fine"}}
    ]

    for {id, detail, _} <- events,
        do: emit(pane, k, action("run-t", id, :started, Map.put(detail, :tool_call_id, id)))

    eventually(fn -> count(pane, "details.tool-card[data-status=running]") == 8 end)
    ids = attribute(pane, "details.tool-card", "id")

    for {id, detail, result} <- events,
        do:
          emit(
            pane,
            k,
            action(
              "run-t",
              id,
              :completed,
              detail |> Map.merge(result) |> Map.put(:tool_call_id, id),
              ok: true
            )
          )

    eventually(fn -> count(pane, "details.tool-card[data-status=done]") == 8 end)
    assert attribute(pane, "details.tool-card", "id") == ids
    assert has_element?(pane, "details[data-tool=bash]", "exit 0")
    assert has_element?(pane, "details[data-tool=read]", "lines 10–14")
    assert has_element?(pane, "details[data-tool=edit] [data-diff=del]", "-old line")
    assert has_element?(pane, "details[data-tool=edit] [data-diff=add]", "+new line")
    assert has_element?(pane, "details[data-tool=search]", "2 results")

    assert has_element?(
             pane,
             "details[data-tool=todo] [data-todo-status=completed]",
             "Write tests"
           )

    assert has_element?(pane, "details[data-tool=task]", "Found the race")
    assert has_element?(pane, "details[data-tool=web] a[href='https://example.com']")
    assert has_element?(pane, "details[data-tool=generic]", "42")
  end

  test "cancelled, failed and unknown completions stay distinct and show only visible text", %{
    conn: conn
  } do
    k = key("cancel")
    {_view, pane} = open(conn, k)

    emit(
      pane,
      k,
      action(
        "run-c",
        "c1",
        :completed,
        %{
          name: "bash",
          tool_call_id: "c1",
          partial_result: %{
            "content" => [
              %{"type" => "text", "text" => "STARTED partial"},
              %{"type" => "thinking", "thinking" => "PRIVATE_REASONING"}
            ]
          },
          result: "cancelled preview",
          details: %{"error_type" => "aborted", "outcome" => "unknown"}
        },
        ok: false
      )
    )

    emit(
      pane,
      k,
      action("run-c", "c2", :completed, %{name: "read", tool_call_id: "c2", result: "ENOENT"},
        ok: false
      )
    )

    emit(
      pane,
      k,
      action(
        "run-c",
        "c3",
        :completed,
        %{name: "write", tool_call_id: "c3", details: %{cancelled: true, outcome: "not_started"}},
        ok: false
      )
    )

    emit(pane, k, action("run-c", "c4", :completed, %{name: "unknown", tool_call_id: "c4"}))

    eventually(fn -> count(pane, "details.tool-card") == 4 end)
    assert has_element?(pane, "details[data-status=cancelled]", "STARTED partial")
    assert has_element?(pane, "details[data-status=cancelled]", "final outcome is unknown")

    assert has_element?(
             pane,
             "details[data-status=cancelled]",
             "Cancelled before the tool started."
           )

    assert has_element?(pane, "details[data-status=failed]", "ENOENT")
    assert has_element?(pane, "details[data-status=completed]", "unknown")
    refute render(pane) =~ "PRIVATE_REASONING"
    refute render(pane) =~ "cancelled preview"
  end

  # ── Approvals and plan ──────────────────────────────────────────────────

  test "approvals: pending ones load on mount, resolve inline, foreign ids are refused", %{
    conn: conn
  } do
    k = key("approve")
    mine = "approval-chat-#{System.unique_integer([:positive])}"
    theirs = "approval-other-#{System.unique_integer([:positive])}"
    mine_req = request(mine, k, "bash", %{"command" => "rm -rf ./build"})
    their_req = request(theirs, key("elsewhere"), "bash", %{"command" => "shutdown now"})

    eventually(fn ->
      is_map(ExecApprovalStore.get_pending(mine)) and
        is_map(ExecApprovalStore.get_pending(theirs))
    end)

    {_view, pane} = open(conn, k)
    assert has_element?(pane, "[data-approval-id='#{mine}']", "rm -rf ./build")
    refute render(pane) =~ "shutdown now"

    render_click(pane, "resolve-approval", %{"id" => theirs, "decision" => "approve_once"})
    assert has_element?(pane, ".approval-notice", "no longer pending for this session")
    assert is_map(ExecApprovalStore.get_pending(theirs))

    pane |> element("[data-approval-id='#{mine}'] button", "Approve once") |> render_click()
    assert Task.await(mine_req) == {:ok, :approved, :approve_once}
    refute has_element?(pane, "[data-approval-id='#{mine}']")
    assert has_element?(pane, ".approval-notice", "Approved once.")

    {:ok, %{decision: :deny, outcome: :denied}} = ExecApprovals.resolve(theirs, :deny)
    Task.await(their_req)
  end

  test "an approval answered elsewhere leaves the pane", %{conn: conn} do
    k = key("remote")
    id = "approval-remote-#{System.unique_integer([:positive])}"
    {_view, pane} = open(conn, k)
    req = request(id, k, "bash", %{"command" => "make release"})
    eventually(fn -> has_element?(pane, "[data-approval-id='#{id}']") end)

    {:ok, %{decision: :deny, outcome: :denied}} = ExecApprovals.resolve(id, :deny)
    Task.await(req)
    eventually(fn -> not has_element?(pane, "[data-approval-id='#{id}']") end)
    assert has_element?(pane, ".approval-notice", "answered elsewhere")
  end

  test "plan mode toggles through sessions.plan and exiting with a plan asks first", %{
    conn: conn,
    stub: stub
  } do
    stub.("sessions.plan", fn %{"sessionKey" => k, "action" => action} ->
      mode =
        if action == "enter", do: "plan", else: if(action == "exit", do: "code", else: "plan")

      {:ok,
       %{
         "sessionKey" => k,
         "plan" => %{
           "mode" => mode,
           "path" => "/p/x-plan.md",
           "content" => if(mode == "plan", do: "# Plan")
         }
       }}
    end)

    {_view, pane} = open(conn, key("plan"))
    eventually(fn -> has_element?(pane, "[id^=plan-indicator-]", "Plan") end)

    render_click(pane, "toggle-plan")
    assert has_element?(pane, "[id^=plan-exit-]", "Exit plan mode?")
    refute_received {:rpc, "sessions.plan", %{"action" => "exit"}}
    render_click(pane, "confirm-plan-exit")
    assert_received {:rpc, "sessions.plan", %{"action" => "exit"}}
    refute has_element?(pane, "[id^=plan-indicator-]")

    render_click(pane, "toggle-plan")
    assert_received {:rpc, "sessions.plan", %{"action" => "enter"}}
  end

  test "a propose_plan approval renders the plan; approve executes and refine denies", %{
    conn: conn
  } do
    k = key("proposal")
    {_view, pane} = open(conn, k)

    for {decision, label, expected} <- [
          {"approve", "Approve & execute", {:ok, :approved, :approve_once}},
          {"refine", "Refine", {:ok, :denied}}
        ] do
      id = "plan-#{decision}-#{System.unique_integer([:positive])}"

      req =
        request(id, k, "propose_plan", %{
          "title" => "Farewell",
          "path" => "/p/f-plan.md",
          "plan" => "## Steps\n\n1. Add farewell"
        })

      eventually(fn ->
        has_element?(pane, ".plan-proposal[data-approval-id='#{id}'] .md h2", "Steps")
      end)

      pane |> element(".plan-proposal[data-approval-id='#{id}'] button", label) |> render_click()
      assert Task.await(req) == expected
      refute has_element?(pane, "[data-approval-id='#{id}']")
    end

    assert has_element?(pane, ".approval-notice", "Tell Lemon what to change")
  end

  # ── Inspector and pickers ───────────────────────────────────────────────

  test "context panel shows usage and an explicit unavailable state", %{conn: conn, stub: stub} do
    {_view, pane} = open(conn, key("ctx-down"))
    render_click(pane, "inspector-tab", %{"tab" => "context"})

    eventually(fn ->
      has_element?(pane, "[id^=context-unavailable-]", "Context is unavailable")
    end)

    stub.("sessions.context", fn %{"sessionKey" => k} ->
      {:ok,
       %{
         "sessionKey" => k,
         "live" => true,
         "window" => 1000,
         "usedTokens" => 420,
         "percentUsed" => 42.0,
         "source" => "usage",
         "autoCompaction" => %{
           "enabled" => true,
           "thresholdTokens" => 800,
           "headroomTokens" => 380
         },
         "categories" => [
           %{
             "id" => "system_prompt",
             "label" => "System prompt",
             "tokens" => 300,
             "percent" => 30.0
           },
           %{
             "id" => "user_messages",
             "label" => "User messages",
             "tokens" => 120,
             "percent" => 12.0
           }
         ],
         "top" => [%{"category" => "tool_results", "label" => "Big result", "tokens" => 90}],
         "messageCount" => 3,
         "measuredAt" => 0
       }}
    end)

    {_view, pane} = open(conn, key("ctx-up"))
    render_click(pane, "inspector-tab", %{"tab" => "context"})
    eventually(fn -> has_element?(pane, "[id^=context-panel-]", "42.0%") end)
    assert has_element?(pane, "[data-category=system_prompt]", "System prompt")
    assert has_element?(pane, "[id^=context-panel-]", "Auto-compaction at 800")
    assert has_element?(pane, "[id^=context-gauge-]", "42.0%")
  end

  test "pickers patch model, thinking level and tool policy", %{conn: conn, stub: stub} do
    stub.(
      "models.list",
      {:ok,
       %{"models" => [%{"id" => "gpt-4o-mini", "provider" => "openai", "name" => "GPT-4o mini"}]}}
    )

    stub.("sessions.patch", {:ok, %{"success" => true}})
    k = key("pickers")
    {_view, pane} = open(conn, k)

    render_click(pane, "open-model-picker")
    eventually(fn -> has_element?(pane, "[role=option]", "openai:gpt-4o-mini") end)
    pane |> element("[role=option]", "openai:gpt-4o-mini") |> render_click()

    assert_received {:rpc, "sessions.patch",
                     %{"sessionKey" => ^k, "model" => "openai:gpt-4o-mini"}}

    render_click(pane, "set-thinking", %{"level" => "high"})
    assert_received {:rpc, "sessions.patch", %{"thinkingLevel" => "high"}}
    render_click(pane, "cycle-thinking")
    assert_received {:rpc, "sessions.patch", %{"thinkingLevel" => "xhigh"}}

    render_click(pane, "set-tool-profile", %{"profile" => "read_only"})
    assert_received {:rpc, "sessions.patch", %{"toolPolicy" => %{"profile" => "read_only"}}}
    render_click(pane, "toggle-ask")

    assert_received {:rpc, "sessions.patch",
                     %{
                       "toolPolicy" => %{
                         "profile" => "read_only",
                         "approvals" => %{"bash" => "always"}
                       }
                     }}
  end

  # ── Active run controls ─────────────────────────────────────────────────

  test "queue modes keep the original run as stop target and stop aborts the actual run", %{
    conn: conn,
    stub: stub
  } do
    k = key("queue")
    stub.("sessions.active", {:ok, %{"sessionKey" => k, "runId" => "run-active"}})
    stub.("chat.send", fn params -> {:ok, %{"runId" => "submission-#{params["queueMode"]}"}} end)
    stub.("chat.abort", {:ok, %{"aborted" => true}})
    {_view, pane} = open(conn, k)
    assert has_element?(pane, "[id^=modes-]")

    for {mode, notice} <- [
          {"followup", "Follow-up queued"},
          {"steer", "Steer sent"},
          {"redirect", "Redirect sent"}
        ] do
      render_submit(pane, "send", %{"chat" => %{"prompt" => "guide #{mode}", "mode" => mode}})

      assert_received {:rpc, "chat.send",
                       %{"sessionKey" => ^k, "prompt" => "guide " <> _, "queueMode" => ^mode}}

      assert has_element?(pane, "[id^=control-notice-]", notice)
    end

    assert has_element?(pane, "[id^=queued-]", "guide followup")
    render_click(pane, "stop")
    assert_received {:rpc, "chat.abort", %{"runId" => "run-active"}}
    assert has_element?(pane, "[id^=run-status-]", "Stopping")
  end

  test "guidance fails closed when the run already finished or status is unavailable", %{
    conn: conn,
    stub: stub
  } do
    k = key("race")
    {:ok, state} = Agent.start_link(fn -> {:ok, %{"sessionKey" => k, "runId" => "run-race"}} end)
    stub.("sessions.active", fn _ -> Agent.get(state, & &1) end)
    {_view, pane} = open(conn, k)

    Agent.update(state, fn _ -> {:error, {:unavailable, "secret /private/path", nil}} end)
    render_submit(pane, "send", %{"chat" => %{"prompt" => "keep draft", "mode" => "redirect"}})
    assert has_element?(pane, "[id^=control-notice-]", "could not confirm")
    assert has_element?(pane, "[id^=run-status-]", "Running")
    assert render(pane) =~ "keep draft"

    Agent.update(state, fn _ -> {:ok, %{"sessionKey" => k, "runId" => nil}} end)
    render_submit(pane, "send", %{"chat" => %{"prompt" => "keep draft", "mode" => "redirect"}})
    assert has_element?(pane, "[id^=control-notice-]", "already finished")
    refute_received {:rpc, "chat.send", _}
  end

  test "an unavailable run status on mount blocks sending", %{conn: conn, stub: stub} do
    stub.("sessions.active", {:error, {:internal_error, "boom /private", nil}})
    {_view, pane} = open(conn, key("unavailable"))
    assert has_element?(pane, "[id^=run-unavailable-]")
    assert has_element?(pane, "textarea[id^=composer-][disabled]")
    render_submit(pane, "send", %{"chat" => %{"prompt" => "nope", "mode" => "collect"}})
    refute_received {:rpc, "chat.send", _}
    refute render(pane) =~ "/private"
  end

  test "unavailable workspace history blocks default-workspace submissions and forks", %{
    conn: conn
  } do
    original = :sys.get_state(LemonCore.Store)
    :sys.replace_state(LemonCore.Store, &%{&1 | backend: BusyBackend, backend_state: %{}})

    try do
      {view, pane} = open(conn, key("workspace-unavailable"))
      assert render(pane) =~ "Session workspace is unavailable"

      render_submit(pane, "send", %{"chat" => %{"prompt" => "do not send", "mode" => "collect"}})
      assert has_element?(pane, "[id^=submit-error-]", "Session workspace is unavailable")

      render_click(pane, "fork", %{})
      refute_received {:rpc, "chat.send", _}
      refute_received {:rpc, "sessions.fork", _}
      refute_received {:rpc, "chat.history", _}
      refute render(pane) =~ "private-backend-detail"
      GenServer.stop(view.pid, :normal)
    after
      :sys.replace_state(LemonCore.Store, fn _ -> original end)
    end
  end

  test "readiness gate and upload failures block submission before chat.send", %{conn: conn} do
    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness(false) end)
    {_view, pane} = open(conn, key("gate"))
    assert has_element?(pane, "#setup-readiness", "Finish setup before chatting")
    render_submit(pane, "send", %{"chat" => %{"prompt" => "hello", "mode" => "collect"}})
    assert has_element?(pane, "[id^=submit-error-]", "Finish setup")

    Application.put_env(:lemon_web, :setup_readiness_fun, fn -> readiness(true) end)

    Application.put_env(:lemon_web, :upload_persist_fun, fn _socket ->
      {:error, "Upload failed: receipt.pdf"}
    end)

    {_view, pane} = open(conn, key("upload"))

    file =
      file_input(pane, "[id^=composer-form-]", :files, [
        %{name: "receipt.pdf", content: "pdf", type: "application/pdf"}
      ])

    render_upload(file, "receipt.pdf")
    render_submit(pane, "send", %{"chat" => %{"prompt" => "", "mode" => "collect"}})
    assert has_element?(pane, "[id^=submit-error-]", "Upload failed: receipt.pdf")
    refute_received {:rpc, "chat.send", _}
  end

  test "uploads respect the entry limit", %{conn: conn} do
    {_view, pane} = open(conn, key("limit"))
    files = for i <- 1..6, do: %{name: "f#{i}.txt", content: "x", type: "text/plain"}
    file = file_input(pane, "[id^=composer-form-]", :files, files)
    _ = preflight_upload(file)
    assert render(pane) =~ "At most 5 files per message."
  end

  test "fork navigates to the child session", %{conn: conn, stub: stub} do
    k = key("fork")

    stub.("sessions.fork", fn %{"sessionKey" => ^k} ->
      {:ok, %{"sessionKey" => "agent:default:fork:local:unknown:child1", "sourceSessionKey" => k}}
    end)

    {view, pane} = open(conn, k)
    render_click(pane, "fork")
    assert_patch(view, "/chat/" <> URI.encode_www_form("agent:default:fork:local:unknown:child1"))
  end

  # ── One transcript pipeline (#653) ──────────────────────────────────────

  test "a run streaming after the first snapshot appends deltas and never replaces the transcript",
       %{conn: conn, stub: stub} do
    k = key("append")

    stub.(
      "chat.history",
      {:ok,
       %{
         "messages" => [
           %{"id" => "h1", "role" => "user", "content" => "Earlier question", "timestampMs" => 1},
           %{
             "id" => "h2",
             "role" => "assistant",
             "content" => "Earlier answer",
             "timestampMs" => 2
           }
         ]
       }}
    )

    stub.("sessions.active", {:ok, %{"sessionKey" => k, "runId" => "run-live"}})
    stub.("chat.send", {:ok, %{"runId" => "submission"}})

    # The snapshot's bounded transcript rows are never rendered.
    snapshot =
      recovery_snapshot(
        k,
        "run-live",
        "running",
        [%{"id" => "snap", "role" => "assistant", "content" => "SNAPSHOT PREVIEW"}],
        seq: 7
      )

    stub.("sessions.snapshot", {:ok, snapshot})
    {_view, pane} = open(conn, k)
    _ = render_async(pane)

    # A row that exists only in this pane: any transcript reset would drop it.
    render_submit(pane, "send", %{"chat" => %{"prompt" => "LOCAL ONLY ROW", "mode" => "steer"}})
    assert has_element?(pane, "[data-kind=user]", "LOCAL ONLY ROW")

    # Batches at or before the snapshot cursor are already reflected.
    emit(pane, k, delta("run-live", 1, "BEFORE CURSOR"), seq: 7)
    for seq <- 8..57, do: emit(pane, k, delta("run-live", seq, "t#{seq} "), seq: seq)

    eventually(fn -> render(pane) =~ "t57" end)
    assert has_element?(pane, "[data-kind=assistant][data-streaming=true]", "t8 t9 t10")

    # A state read during the run changes no transcript row.
    render_click(pane, "inspector-tab", %{"tab" => "subagents"})
    _ = render_async(pane)
    for seq <- 58..60, do: emit(pane, k, delta("run-live", seq, "t#{seq} "), seq: seq)
    emit(pane, k, completed("run-live", "unused"), seq: 61)

    eventually(fn ->
      has_element?(pane, "[data-kind=assistant][data-streaming=false]", "t60")
    end)

    html = render(pane)
    assert html =~ "LOCAL ONLY ROW"
    assert html =~ "Earlier question"
    assert html =~ "Earlier answer"
    refute html =~ "SNAPSHOT PREVIEW"
    refute html =~ "BEFORE CURSOR"
    assert count(pane, "[data-kind=assistant]") == 2
    assert has_element?(pane, "[data-kind=assistant]", "t8 t9 t10")
  end

  test "long answers and edit diffs come from history in full after reload, recovery and reconnect",
       %{conn: conn, stub: stub} do
    k = key("full-text")
    answer = String.duplicate("0123456789", 2_000) <> " END-OF-ANSWER"
    new_text = Enum.map_join(1..300, "\n", &"replacement line #{&1}") <> "\nLAST-NEW-LINE"
    path = "lib/" <> String.duplicate("deeply/nested/", 20) <> "target_file.ex"
    assert byte_size(answer) > 20_000 and byte_size(new_text) > 4_096

    stub.(
      "chat.history",
      {:ok,
       %{
         "messages" => [
           %{"id" => "u1", "role" => "user", "content" => "Rewrite it", "timestampMs" => 1},
           %{
             "id" => "t1",
             "role" => "tool_use",
             "toolCallId" => "c-edit",
             "toolName" => "edit",
             "arguments" => %{"path" => path, "old_text" => "old line", "new_text" => new_text},
             "phase" => "started",
             "timestampMs" => 2
           },
           %{
             "id" => "t2",
             "role" => "tool_result",
             "toolCallId" => "c-edit",
             "toolName" => "edit",
             "content" => "ok",
             "phase" => "completed",
             "ok" => true,
             "timestampMs" => 3
           },
           %{"id" => "a1", "role" => "assistant", "content" => answer, "timestampMs" => 4}
         ]
       }}
    )

    # The snapshot carries only a bounded preview of the same turn.
    bounded =
      recovery_snapshot(k, "run-done", "completed", [
        %{"id" => "a1", "role" => "assistant", "content" => String.slice(answer, 0, 4_096)}
      ])
      |> put_in(["snapshot", "messagesTruncated"], true)

    stub.("sessions.snapshot", {:ok, bounded})

    stub.("sessions.events", fn %{"cursor" => cursor} ->
      {:ok,
       %{
         "status" => "ok",
         "sessionKey" => k,
         "entries" => [],
         "cursor" => cursor,
         "hasMore" => false
       }}
    end)

    full? = fn pane ->
      html = render(pane)

      html =~ "END-OF-ANSWER" and html =~ "LAST-NEW-LINE" and html =~ "target_file.ex" and
        count(pane, "[data-kind=assistant]") == 1 and count(pane, "details.tool-card") == 1
    end

    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    assert full?.(pane)
    assert has_element?(pane, "details[data-tool=edit] [data-diff=add]", "+LAST-NEW-LINE")

    # Recovery after lost delivery replays from the cursor: nothing replaced.
    send(pane.pid, {:stream_resync, :overflow})
    _ = render(pane)
    _ = render_async(pane)
    assert full?.(pane)

    # A changed stream reloads history, still in full.
    emit(pane, k, delta("run-next", 1, "unused"), stream: "stream-rewound", seq: 9)
    _ = render(pane)
    _ = render_async(pane)
    eventually(fn -> full?.(pane) end)

    # Reconnect.
    {_view, again} = open(conn, k)
    _ = render_async(again)
    assert full?.(again)
  end

  test "history is read once per open, on the connected mount", %{conn: conn} do
    {_view, pane} = open(conn, key("history-once"))
    _ = render_async(pane)
    assert rpc_count("chat.history") == 1
  end

  test "a cursor gap replays the missing batches in order before continuing", %{
    conn: conn,
    stub: stub
  } do
    k = key("gap")

    stub.("sessions.events", fn %{"cursor" => %{"seq" => 1} = from} ->
      entries =
        for {seq, text} <- [{2, "B"}, {3, "C"}] do
          %{
            "cursor" => Map.put(from, "seq", seq),
            "eventId" => "stream-1:#{seq}",
            "events" => [
              %{
                "event" => "chat",
                "payload" => %{"type" => "delta", "runId" => "run-gap", "text" => text}
              }
            ]
          }
        end

      {:ok,
       %{
         "status" => "ok",
         "sessionKey" => k,
         "entries" => entries,
         "cursor" => Map.put(from, "seq", 3),
         "hasMore" => false
       }}
    end)

    {_view, pane} = open(conn, k)
    _ = rpc_count("chat.history")
    emit(pane, k, delta("run-gap", 1, "A"), seq: 1)
    emit(pane, k, delta("run-gap", 4, "D"), seq: 4)
    emit(pane, k, delta("run-gap", 5, "E"), seq: 5)
    _ = render(pane)
    _ = render_async(pane)
    eventually(fn -> has_element?(pane, "[data-kind=assistant]", "ABCDE") end)
    assert_received {:rpc, "sessions.events", %{"cursor" => %{"seq" => 1}}}
    assert rpc_count("chat.history") == 0
  end

  test "a new owner stream continues without a reload; a rewound stream reloads history", %{
    conn: conn,
    stub: stub
  } do
    k = key("streams")
    {:ok, rows} = Agent.start_link(fn -> [] end)
    stub.("chat.history", fn _ -> {:ok, %{"messages" => Agent.get(rows, & &1)}} end)
    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    _ = rpc_count("chat.history")

    emit(pane, k, [delta("run-1", 1, "first owner"), completed("run-1", "first owner")], seq: 1)

    # A restarted owner process starts its own stream at 1.
    emit(pane, k, delta("run-2", 1, "second owner"), stream: "stream-restarted", seq: 1)
    eventually(fn -> has_element?(pane, "[data-kind=assistant]", "second owner") end)
    assert has_element?(pane, "[data-kind=assistant]", "first owner")
    assert rpc_count("chat.history") == 0

    # A branch change keeps counting in a new stream: history is reread.
    Agent.update(rows, fn _ ->
      [%{"id" => "r1", "role" => "assistant", "content" => "Rewound branch", "timestampMs" => 1}]
    end)

    emit(pane, k, delta("run-3", 1, "after rewind"), stream: "stream-rewound", seq: 40)
    _ = render(pane)
    _ = render_async(pane)
    eventually(fn -> has_element?(pane, "[data-kind=assistant]", "Rewound branch") end)
    refute render(pane) =~ "first owner"
    assert rpc_count("chat.history") == 1
  end

  test "not_found is an empty idle session and unknown is explicit; neither polls", %{
    conn: conn,
    stub: stub
  } do
    stub.("sessions.snapshot", {:error, {:not_found, "Session not found", nil}})
    {_view, pane} = open(conn, key("not-found"))
    _ = render_async(pane)
    refute has_element?(pane, "[id^=run-unavailable-]")
    refute has_element?(pane, "[id^=state-notice-]")
    render_click(pane, "inspector-tab", %{"tab" => "plan"})
    assert has_element?(pane, "[id^=todo-recovery-]", "has not started yet")
    assert :sys.get_state(pane.pid).socket.assigns.recovery.timer == nil

    k = key("snapshot-unknown")
    stub.("sessions.snapshot", {:ok, recovery_snapshot(k, nil, "unknown", [])})
    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    assert rpc_count("sessions.snapshot") == 2
    assert has_element?(pane, "[id^=run-unavailable-]")
    assert has_element?(pane, "textarea[id^=composer-][disabled]")
    assert has_element?(pane, "[id^=state-notice-]", "Current run state is unavailable.")
    assert :sys.get_state(pane.pid).socket.assigns.recovery.timer == nil
    # Longer than the first error backoff: nothing polls an explicit answer.
    refute_receive {:rpc, "sessions.snapshot", _}, 1_200
    assert rpc_count("sessions.snapshot") == 0
    render_submit(pane, "send", %{"chat" => %{"prompt" => "nope", "mode" => "collect"}})
    refute_received {:rpc, "chat.send", _}
  end

  test "a failed snapshot backs off instead of polling", %{conn: conn, stub: stub} do
    stub.("sessions.snapshot", {:error, {:unavailable, "PRIVATE owner failure", nil}})
    {_view, pane} = open(conn, key("backoff"))
    _ = render_async(pane)
    assert has_element?(pane, "[id^=state-notice-]", "Lemon will try again shortly")
    refute render(pane) =~ "PRIVATE"
    recovery = :sys.get_state(pane.pid).socket.assigns.recovery
    assert recovery.failures == 1 and is_reference(recovery.timer)
  end

  test "a stopping run and queued follow-ups go through the run reducer on recovery", %{
    conn: conn,
    stub: stub
  } do
    k = key("stopping")
    {:ok, phase} = Agent.start_link(fn -> "running" end)
    stub.("sessions.active", {:ok, %{"sessionKey" => k, "runId" => "run-a"}})
    stub.("chat.send", {:ok, %{"runId" => "submission"}})
    stub.("chat.abort", {:ok, %{"aborted" => true}})

    stub.("sessions.snapshot", fn _ ->
      {:ok, recovery_snapshot(k, "run-a", Agent.get(phase, & &1), [])}
    end)

    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    render_submit(pane, "send", %{"chat" => %{"prompt" => "later please", "mode" => "followup"}})
    assert has_element?(pane, "[id^=queued-]", "later please")
    render_click(pane, "stop")
    assert has_element?(pane, "[id^=run-status-]", "Stopping")

    render_click(pane, "inspector-tab", %{"tab" => "subagents"})
    _ = render_async(pane)
    assert has_element?(pane, "[id^=run-status-]", "Stopping")
    assert has_element?(pane, "[id^=queued-]", "later please")

    Agent.update(phase, fn _ -> "completed" end)
    render_click(pane, "inspector-tab", %{"tab" => "subagents"})
    _ = render_async(pane)
    refute has_element?(pane, "[id^=queued-]")
    refute has_element?(pane, "[id^=run-line-]")
  end

  test "a run that ends before reaching the native session completes from its unsequenced event",
       %{conn: conn, stub: stub} do
    k = key("pre-native")
    stub.("chat.send", {:ok, %{"runId" => "run-pre"}})
    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    render_submit(pane, "send", %{"chat" => %{"prompt" => "hello", "mode" => "collect"}})
    assert has_element?(pane, "[id^=run-line-]")

    send(
      pane.pid,
      Event.new(
        :run_completed,
        %{completed: %{ok: false, error: :runtime_unavailable}},
        %{run_id: "run-pre", session_key: k}
      )
    )

    eventually(fn -> not has_element?(pane, "[id^=run-line-]") end)
    assert has_element?(pane, "[data-kind=notice]", "execution runtime is unavailable")
  end

  test "a fast token stream shows no recovery banner and reads state at most once per run", %{
    conn: conn,
    stub: stub
  } do
    k = key("fast-stream")
    run_id = "run-fast"
    stub.("sessions.active", {:ok, %{"sessionKey" => k, "runId" => run_id}})

    # Every owner read races the live output, as it does under streaming.
    stub.(
      "sessions.snapshot",
      {:ok,
       %{
         "status" => "retry",
         "sessionKey" => k,
         "identity" => nil,
         "reason" => "snapshot_raced",
         "retrySafe" => true
       }}
    )

    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    assert rpc_count("sessions.snapshot") == 1

    for seq <- 1..400 do
      :ok =
        LemonCore.Bus.broadcast(
          "session_events",
          batch(k, "stream-1", seq, delta(run_id, seq, "tok "))
        )

      if rem(seq, 20) == 0, do: Process.sleep(2)
    end

    eventually(fn -> count_text(pane, "tok") == 400 end)
    during_run = rpc_count("sessions.snapshot")

    :ok =
      LemonCore.Bus.broadcast("session_events", batch(k, "stream-1", 401, completed(run_id, "x")))

    eventually(fn -> not has_element?(pane, "[id^=run-line-]") end)
    _ = render_async(pane)

    assert during_run == 0
    assert rpc_count("sessions.snapshot") == 1
    refute has_element?(pane, "[id^=state-notice-]")
    refute has_element?(pane, "[id^=run-unavailable-]")
    assert count(pane, "[data-kind=assistant]") == 1
  end

  test "snapshot state replaces todos, processes, children and approvals, never text", %{
    conn: conn,
    stub: stub
  } do
    k = key("state")

    snapshot =
      recovery_snapshot(k, "current-run", "completed", [
        %{"id" => "a", "role" => "assistant", "content" => "SNAPSHOT TEXT"}
      ])
      |> put_in(["snapshot", "todos", "items"], [
        %{"id" => "current-todo", "content" => "Current branch todo", "status" => "pending"}
      ])
      |> put_in(["snapshot", "children", "items"], [
        %{
          "taskId" => "fixed-task",
          "runId" => "fixed-child",
          "parentRunId" => "current-run",
          "status" => "completed"
        }
      ])
      |> put_in(["snapshot", "processes", "items"], [
        %{
          "identity" => "fixed-process",
          "classification" => "outcome_unknown",
          "status" => "lost"
        }
      ])
      |> put_in(["snapshot", "todos", "truncated"], true)
      |> put_in(["snapshot", "children", "truncated"], true)
      |> put_in(["snapshot", "processes", "truncated"], true)
      |> put_in(["snapshot", "approvals"], %{"status" => "unavailable"})

    stub.("sessions.snapshot", {:ok, snapshot})
    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    refute render(pane) =~ "SNAPSHOT TEXT"
    assert has_element?(pane, ".approval-notice", "Approval status is unavailable.")
    refute has_element?(pane, "[id^=approvals-] button")

    render_click(pane, "inspector-tab", %{"tab" => "plan"})
    _ = render_async(pane)
    assert has_element?(pane, "[id^=todo-recovery-]", "Current branch todo")
    assert has_element?(pane, "[id^=todo-recovery-]", "Todo snapshot truncated")

    render_click(pane, "inspector-tab", %{"tab" => "subagents"})
    _ = render_async(pane)
    assert has_element?(pane, "[data-status=completed]", "fixed-child")
    assert has_element?(pane, "[id^=subagent-tree-truncated-]")

    render_click(pane, "inspector-tab", %{"tab" => "details"})
    assert has_element?(pane, "[id^=process-recovery-]", "fixed-process")
    assert has_element?(pane, "[id^=process-recovery-]", "lost")
    assert has_element?(pane, "[id^=process-recovery-]", "Process snapshot truncated")
  end

  test "a history tool row without a receipt renders outcome unknown, never a spinner", %{
    conn: conn,
    stub: stub
  } do
    stub.(
      "chat.history",
      {:ok,
       %{
         "messages" => [
           %{
             "id" => "missing-receipt",
             "role" => "tool_use",
             "toolCallId" => "uncertain-call",
             "toolName" => "write",
             "phase" => "unknown"
           }
         ]
       }}
    )

    {_view, pane} = open(conn, key("receipt-unknown"))
    assert has_element?(pane, "details.tool-card[data-status=unknown]", "outcome unknown")
    refute has_element?(pane, "details.tool-card[data-status=running]")
  end

  test "a suspended pane has bounded fanout and replays the owner's events after overflow", %{
    conn: conn,
    stub: stub
  } do
    k = key("bounded-replay")
    run_id = "burst-run"
    last = 1_000
    stub.("sessions.active", {:ok, %{"sessionKey" => k, "runId" => run_id}})
    stub.("sessions.snapshot", {:ok, recovery_snapshot(k, run_id, "running", [])})

    projected = fn seq ->
      if seq == last,
        do: %{"type" => "completed", "runId" => run_id, "ok" => true, "answer" => "done"},
        else: %{"type" => "delta", "runId" => run_id, "text" => "."}
    end

    stub.("sessions.events", fn %{"cursor" => %{"seq" => from} = cursor} ->
      upto = min(from + 100, last)

      entries =
        for seq <- (from + 1)..upto//1 do
          event = if seq == last, do: "agent", else: "chat"

          %{
            "cursor" => Map.put(cursor, "seq", seq),
            "eventId" => "stream-1:#{seq}",
            "events" => [%{"event" => event, "payload" => projected.(seq)}]
          }
        end

      {:ok,
       %{
         "status" => "ok",
         "sessionKey" => k,
         "entries" => entries,
         "cursor" => Map.put(cursor, "seq", upto),
         "hasMore" => upto < last
       }}
    end)

    {_view, pane} = open(conn, k)
    _ = render_async(pane)
    :ok = :sys.suspend(pane.pid)

    try do
      for seq <- 1..last do
        event =
          if seq == last, do: completed(run_id, "done"), else: delta(run_id, seq, ".")

        :ok = LemonCore.Bus.broadcast("session_events", batch(k, "stream-1", seq, event))
      end

      {:message_queue_len, queued} = Process.info(pane.pid, :message_queue_len)
      {:messages, messages} = Process.info(pane.pid, :messages)
      # 256 admitted events + one overflow marker, with room for LiveView
      # control/timer messages (which share and conservatively consume capacity).
      assert queued <= 270

      assert Enum.count(
               messages,
               &match?({:lemon_bus_delivery, _, {:stream_resync, :overflow}}, &1)
             ) == 1
    after
      :ok = :sys.resume(pane.pid)
    end

    eventually(fn ->
      _ = render_async(pane)
      not has_element?(pane, "[id^=run-line-]")
    end)

    assert has_element?(pane, "[data-kind=assistant]", String.duplicate(".", last - 1))
    assert count(pane, "[data-kind=assistant]") == 1
    assert rpc_count("chat.history") == 1
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp recovery_snapshot(key, run_id, phase, messages, opts \\ []) do
    answer =
      messages
      |> Enum.filter(&(&1["role"] == "assistant"))
      |> Enum.map_join("", &(&1["content"] || ""))

    %{
      "status" => "ok",
      "sessionKey" => key,
      "identity" => %{
        "sessionKey" => key,
        "sessionId" => "native-session",
        "branchId" => "branch",
        "revision" => "revision",
        "runId" => run_id,
        "attempt" => run_id
      },
      "consistency" => %{
        "boundary" => "stable_owner_reads",
        "atomic" => false,
        "eventCursor" => cursor("stream-1", Keyword.get(opts, :seq, 0)),
        "runStatus" => "ok"
      },
      "snapshot" => %{
        "phase" => phase,
        "terminal" => phase in ["completed", "cancelled", "failed"],
        "answer" => %{
          "text" => answer,
          "canonical" => phase in ["completed", "cancelled", "failed"],
          "truncated" => false
        },
        "messages" => Enum.map(messages, &Map.put(&1, "runId", run_id)),
        "actions" => [],
        "approvals" => %{"status" => "ok", "items" => []},
        "children" => %{"status" => "ok", "items" => []},
        "processes" => %{"status" => "ok", "items" => []},
        "todos" => %{"status" => "ok", "items" => []},
        "plan" => %{"status" => "ok", "value" => %{"mode" => "code", "content" => nil}}
      }
    }
  end

  defp cursor(stream, seq),
    do: %{"version" => 1, "sessionId" => "native-session", "streamId" => stream, "seq" => seq}

  # A sequenced batch as the native owner broadcasts it on "session_events".
  defp batch(key, stream, seq, events) do
    events =
      Enum.map(List.wrap(events), &%{&1 | meta: Map.put(&1.meta || %{}, :session_key, key)})

    Event.new(
      :session_event,
      %{cursor: cursor(stream, seq), event_id: "#{stream}:#{seq}", events: events},
      %{session_key: key}
    )
  end

  # Delivers the next batch of `stream` (or `seq:`) straight to the pane.
  defp emit(pane, key, events, opts \\ []) do
    stream = Keyword.get(opts, :stream, "stream-1")
    seq = Keyword.get_lazy(opts, :seq, fn -> Process.get({:seq, key, stream}, 0) + 1 end)
    Process.put({:seq, key, stream}, max(seq, Process.get({:seq, key, stream}, 0)))
    send(pane.pid, batch(key, stream, seq, events))
  end

  # Counts (and consumes) the stubbed calls of `method` received so far.
  defp rpc_count(method, acc \\ 0) do
    receive do
      {:rpc, ^method, _} -> rpc_count(method, acc + 1)
    after
      0 -> acc
    end
  end

  defp count_text(view, text) do
    view |> render() |> :binary.matches(text) |> length()
  end

  defp open(conn, key) do
    {:ok, view, _html} = live(conn, "/chat/#{URI.encode_www_form(key)}")
    [pane] = panes(view)
    {view, pane}
  end

  # Chat panes are nested LiveViews; the sticky shell is a sibling child.
  defp panes(view), do: Enum.reject(live_children(view), &(&1.id == "lemon-shell"))

  defp key(name),
    do:
      "agent:web_chat_#{String.replace(name, "-", "_")}_#{System.unique_integer([:positive])}:main"

  defp delta(run_id, seq, text),
    do: Event.new(:delta, %{run_id: run_id, seq: seq, text: text}, %{run_id: run_id})

  defp completed(run_id, answer),
    do: Event.new(:run_completed, %{completed: %{ok: true, answer: answer}}, %{run_id: run_id})

  defp action(run_id, id, phase, detail, opts \\ []) do
    payload = %{
      engine: "lemon",
      action: %{id: id, kind: :tool, title: detail.name, detail: detail},
      phase: phase,
      ok: opts[:ok]
    }

    Event.new(:engine_action, payload, %{run_id: run_id})
  end

  defp request(id, session_key, tool, action) do
    Task.async(fn ->
      ExecApprovals.request(%{
        approval_id: id,
        run_id: "run-#{id}",
        session_key: session_key,
        tool: tool,
        action: action,
        expires_in_ms: 30_000
      })
    end)
  end

  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  defp attribute(view, selector, name),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute(name)

  defp pos(html, text) do
    case :binary.match(html, text) do
      {index, _} -> index
      :nomatch -> flunk("expected #{inspect(text)}")
    end
  end

  defp eventually(fun, attempts \\ 150) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition was not met in time")
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp readiness(ready?) do
    %{
      config: %{complete: ready?, path: "/tmp/lemon-config.toml"},
      secrets: %{complete: ready?, source: if(ready?, do: :env)},
      provider: %{
        complete: ready?,
        provider: "openai",
        model: "openai:gpt-5",
        credential_ready: ready?,
        reason: if(!ready?, do: :missing_default_provider)
      }
    }
  end
end
