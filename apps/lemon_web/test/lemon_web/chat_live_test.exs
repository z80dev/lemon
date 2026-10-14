defmodule LemonWeb.ChatLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonCore.{Event, ExecApprovals, ExecApprovalStore}

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

  defp default_stub("sessions.plan", %{"sessionKey" => key}),
    do:
      {:ok,
       %{"sessionKey" => key, "plan" => %{"mode" => "code", "path" => nil, "content" => nil}}}

  defp default_stub("sessions.context", _),
    do: {:error, {:unavailable, "Context is unavailable", nil}}

  defp default_stub(_method, _params), do: :passthrough

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
    {_view, pane} = open(conn, key("stream"))

    send(pane.pid, delta("run-s", 1, "Hello"))
    send(pane.pid, delta("run-s", 2, " world"))
    send(pane.pid, delta("run-s", 2, " world"))

    eventually(fn ->
      has_element?(pane, "[data-kind=assistant][data-streaming=true]", "Hello world")
    end)

    refute render(pane) =~ "Hello world world"

    send(pane.pid, completed("run-s", "Hello world"))

    eventually(fn ->
      has_element?(pane, "[data-kind=assistant][data-streaming=false]", "Hello world")
    end)

    assert count(pane, "[data-kind=assistant]") == 1

    # A run that streamed nothing appends its final answer once.
    send(pane.pid, completed("run-quiet", "Quiet answer"))
    eventually(fn -> has_element?(pane, "[data-kind=assistant]", "Quiet answer") end)
    assert count(pane, "[data-kind=assistant]") == 2
  end

  test "a tool start splits the reply into segments around the card", %{conn: conn} do
    {_view, pane} = open(conn, key("segments"))
    send(pane.pid, delta("run-g", 1, "Let me look."))

    send(
      pane.pid,
      action("run-g", "c-read", :started, %{
        name: "read",
        args: %{"path" => "mix.exs"},
        tool_call_id: "c-read"
      })
    )

    send(pane.pid, delta("run-g", 2, "Found it."))
    send(pane.pid, completed("run-g", "Let me look.Found it."))
    eventually(fn -> count(pane, "[data-kind=assistant]") == 2 end)
    html = render(pane)
    assert pos(html, "Let me look.") < pos(html, "mix.exs")
    assert pos(html, "mix.exs") < pos(html, "Found it.")
  end

  test "tool cards render per tool type and update in place", %{conn: conn} do
    {_view, pane} = open(conn, key("tools"))

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
        do: send(pane.pid, action("run-t", id, :started, Map.put(detail, :tool_call_id, id)))

    eventually(fn -> count(pane, "details.tool-card[data-status=running]") == 8 end)
    ids = attribute(pane, "details.tool-card", "id")

    for {id, detail, result} <- events,
        do:
          send(
            pane.pid,
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
    {_view, pane} = open(conn, key("cancel"))

    send(
      pane.pid,
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

    send(
      pane.pid,
      action("run-c", "c2", :completed, %{name: "read", tool_call_id: "c2", result: "ENOENT"},
        ok: false
      )
    )

    send(
      pane.pid,
      action(
        "run-c",
        "c3",
        :completed,
        %{name: "write", tool_call_id: "c3", details: %{cancelled: true, outcome: "not_started"}},
        ok: false
      )
    )

    send(pane.pid, action("run-c", "c4", :completed, %{name: "unknown", tool_call_id: "c4"}))

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

  # ── Helpers ─────────────────────────────────────────────────────────────

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
