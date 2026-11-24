defmodule LemonWeb.ChatSubagentsLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias LemonCore.{Bus, Event}

  setup :configure_operator_token

  setup do
    settings = [{:lemon_web, :setup_readiness_fun}, {:lemon_web, :chat_rpc_stub}]

    previous =
      Enum.map(settings, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    {:ok, children} = Agent.start_link(fn -> %{"status" => "ok", "items" => []} end)
    test_pid = self()

    Application.put_env(:lemon_web, :chat_rpc_stub, fn
      "sessions.active", %{"sessionKey" => key} ->
        {:ok, %{"sessionKey" => key, "runId" => nil}}

      "chat.history", _ ->
        {:ok, %{"messages" => []}}

      "sessions.snapshot", %{"sessionKey" => key} ->
        send(test_pid, :snapshot_read)
        {:ok, snapshot(key, Agent.get(children, & &1))}

      _method, _params ->
        :passthrough
    end)

    Application.put_env(:lemon_web, :setup_readiness_fun, fn ->
      %{
        config: %{complete: true},
        secrets: %{complete: true},
        provider: %{complete: true, credential_ready: true}
      }
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)
    end)

    %{children: fn value -> Agent.update(children, fn _ -> value end) end}
  end

  test "the tree is the snapshot's children projection, without private content", ctx do
    ctx.children.(
      ok([
        child("child-run", "root-run", "running", answer: "PRIVATE_RESULT /private/workspace"),
        child("grandchild-run", "child-run", "queued"),
        child("bad id with spaces", "root-run", "running")
      ])
    )

    {:ok, view, _} = open(ctx.conn, session_key("tree"))

    assert has_element?(
             view,
             "[id^=subagent-tree-] [data-depth='0'][data-status=running]",
             "child-run"
           )

    assert has_element?(
             view,
             "[id^=subagent-tree-] [data-depth='1'][data-parent-id='child-run'][data-status=queued]",
             "grandchild-run"
           )

    refute render(view) =~ "bad id with spaces"
    state = :sys.get_state(view.pid)
    projection = inspect(state.socket.assigns.subagents, limit: :infinity)

    for private <- ["PRIVATE_RESULT", "/private/workspace"] do
      refute render(view) =~ private
      refute projection =~ private
    end
  end

  test "child lifecycle events reread the snapshot; foreign sessions cannot", ctx do
    key = session_key("events")
    {:ok, view, _} = open(ctx.conn, key)
    assert has_element?(view, "[id^=subagent-tree-empty-]")
    flush_reads()

    ctx.children.(ok([child("late-child", "root-run", "running")]))

    started = fn session_key ->
      Event.new(:run_started, %{run_id: "late-child", session_key: session_key}, %{
        run_id: "late-child",
        session_key: session_key,
        parent_run_id: "root-run"
      })
    end

    Bus.broadcast(Bus.session_topic(session_key("foreign")), started.(session_key("foreign")))
    refute_receive :snapshot_read, 100

    Bus.broadcast(Bus.session_topic(key), started.(key))
    assert_receive :snapshot_read
    _ = render_async(view)
    assert has_element?(view, "[id^=subagent-tree-] [data-status=running]", "late-child")
  end

  test "node and depth limits bound the tree, including parent cycles", ctx do
    many = for i <- 1..55, do: child("run-#{i}", "root-run", "completed")
    ctx.children.(%{"status" => "ok", "items" => many, "truncated" => false})
    {:ok, view, _} = open(ctx.conn, session_key("bounded"))

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[id^=subagent-tree-] li")
           |> Enum.count() == 50

    assert has_element?(view, "[id^=subagent-tree-truncated-]")

    rows =
      [{"root", nil}, {"child", "root"}, {"cycle-a", "cycle-b"}, {"cycle-b", "cycle-a"}]
      |> Enum.map(fn {id, parent} -> child(id, parent, "completed") end)

    chain = for i <- 1..12, do: child("deep-#{i}", "deep-#{i - 1}", "running")
    projection = LemonWeb.Chat.Subagents.from_recovery(ok(rows ++ chain))
    depths = Map.new(projection.nodes, &{&1.id, &1.depth})

    assert projection.status == :available

    assert Map.take(depths, ~w(root child cycle-a cycle-b)) ==
             %{"root" => 0, "child" => 1, "cycle-a" => 1, "cycle-b" => 1}

    assert depths["deep-12"] == 7
  end

  test "an unavailable children owner stays distinct from empty and recovers on reread", ctx do
    ctx.children.(%{"status" => "unavailable"})
    {:ok, view, _} = open(ctx.conn, session_key("unavailable"))
    assert has_element?(view, "[id^=subagent-tree-unavailable-]")
    refute has_element?(view, "[id^=subagent-tree-empty-]")

    ctx.children.(ok([]))
    render_click(view, "inspector-tab", %{"tab" => "subagents"})
    _ = render_async(view)
    assert has_element?(view, "[id^=subagent-tree-empty-]")
    refute has_element?(view, "[id^=subagent-tree-unavailable-]")
  end

  defp open(conn, key) do
    {:ok, view, _} = live(conn, "/chat/#{URI.encode_www_form(key)}")
    [pane] = Enum.reject(live_children(view), &(&1.id == "lemon-shell"))
    render_click(pane, "inspector-tab", %{"tab" => "subagents"})
    _ = render_async(pane)
    {:ok, pane, nil}
  end

  defp ok(items), do: %{"status" => "ok", "items" => items, "truncated" => false}

  defp child(run_id, parent, status, opts \\ []) do
    %{
      "taskId" => "task-" <> run_id,
      "runId" => run_id,
      "parentRunId" => parent,
      "status" => status,
      "terminal" => status == "completed",
      "sessionId" => "child-session",
      "answer" => opts[:answer]
    }
  end

  defp snapshot(key, children) do
    %{
      "status" => "ok",
      "sessionKey" => key,
      "identity" => %{
        "sessionKey" => key,
        "sessionId" => "native-session",
        "branchId" => "branch",
        "revision" => "revision",
        "runId" => nil,
        "attempt" => nil
      },
      "consistency" => %{"eventCursor" => nil},
      "snapshot" => %{
        "phase" => "idle",
        "approvals" => %{"status" => "ok", "items" => []},
        "children" => children,
        "processes" => %{"status" => "ok", "items" => []},
        "todos" => %{"status" => "ok", "items" => []}
      }
    }
  end

  defp flush_reads do
    receive do
      :snapshot_read -> flush_reads()
    after
      0 -> :ok
    end
  end

  defp session_key(label),
    do: "agent:web_tree_#{label}_#{System.unique_integer([:positive])}:main"
end
