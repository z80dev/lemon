defmodule LemonWeb.ChatSubagentsLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import LemonWeb.Test.OperatorAuth

  alias CodingAgent.{RunGraph, TaskStore}
  alias LemonCore.{Bus, Event}

  setup :configure_operator_token

  setup do
    settings = [
      {:lemon_web, :setup_readiness_fun},
      {:lemon_web, :chat_rpc_stub},
      {:lemon_core, :agent_runtime_provider}
    ]

    previous =
      Enum.map(settings, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    active(nil)

    Application.put_env(
      :lemon_core,
      :agent_runtime_provider,
      CodingAgent.ControlPlaneProvider
    )

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

    :ok
  end

  test "connected refresh follows real task status and nested graph without retaining private content",
       ctx do
    key = session_key("tree")
    child_key = session_key("child")
    root = graph_run()
    active(root)
    {child, child_task} = task(key, root, %{delegated_session_key: child_key})
    {grandchild, _} = task(key, child)
    {foreign, _} = task(session_key("foreign"), root)
    {other_run, _} = task(key, "different-run")
    TaskStore.mark_running(child_task)

    TaskStore.append_event(child_task, %{
      details: %{
        action_detail: %{name: "bash", command: "/private/workspace", api_key: "sk-tree-secret"}
      },
      content: [%{text: "PRIVATE_RESULT"}]
    })

    {:ok, view, _} = open(ctx.conn, key)
    assert has_element?(view, "[id^=subagent-tree-] [data-depth='0'][data-status=running]", child)

    assert has_element?(
             view,
             "[id^=subagent-tree-] [data-depth='1'][data-parent-id='#{child}']",
             grandchild
           )

    assert has_element?(
             view,
             "[id^=subagent-tree-] a[href='/chat/#{URI.encode_www_form(child_key)}']",
             "Open child session"
           )

    assert has_element?(view, "[id^=subagent-tree-]", "bash")
    refute has_element?(view, "[id^=subagent-tree-]", foreign)
    refute has_element?(view, "[id^=subagent-tree-]", other_run)

    state = :sys.get_state(view.pid)
    projection = inspect(state.socket.assigns.subagents, limit: :infinity)

    for private <- [
          "PRIVATE_PROMPT",
          "PRIVATE_RESULT",
          "/private/workspace",
          "sk-tree-secret",
          "PRIVATE_DESCRIPTION"
        ] do
      refute render(view) =~ private
      refute projection =~ private
    end

    TaskStore.finish(child_task, %{answer: "PRIVATE_RESULT"})
    # Do not send the refresh ourselves: this proves the connected-only timer.
    eventually(fn ->
      has_element?(view, "[id^=subagent-tree-] [data-depth='0'][data-status=completed]", child)
    end)
  end

  test "run changes isolate the tree and foreign session bus events cannot change it", ctx do
    key = session_key("run-switch")
    first = graph_run()
    second = graph_run()
    {first_child, _} = task(key, first)
    {second_child, _} = task(key, second)
    active(first)
    {:ok, view, _} = open(ctx.conn, key)
    assert has_element?(view, "[id^=subagent-tree-]", first_child)
    refute has_element?(view, "[id^=subagent-tree-]", second_child)

    Bus.broadcast(
      Bus.session_topic(session_key("foreign")),
      Event.new(:run_started, %{run_id: second})
    )

    assert has_element?(view, "[id^=subagent-tree-]", first_child)

    Bus.broadcast(Bus.session_topic(key), Event.new(:run_started, %{run_id: second}))
    eventually(fn -> has_element?(view, "[id^=subagent-tree-]", second_child) end)
    refute has_element?(view, "[id^=subagent-tree-]", first_child)
  end

  test "node and depth limits bound connected trees including graph cycles", ctx do
    key = session_key("bounded")
    root = graph_run()
    active(root)
    for _ <- 1..55, do: task(key, root)
    {:ok, view, _} = open(ctx.conn, key)

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[id^=subagent-tree-] li")
           |> Enum.count() == 50

    assert has_element?(view, "[id^=subagent-tree-truncated-]")

    deep_root = graph_run()
    {first, _} = task(key, deep_root)
    last = Enum.reduce(1..12, first, fn _, parent -> elem(task(key, parent), 0) end)
    RunGraph.add_child(last, first)
    Bus.broadcast(Bus.session_topic(key), Event.new(:run_started, %{run_id: deep_root}))
    eventually(fn -> has_element?(view, "[id^=subagent-tree-] [data-depth='7']") end)
    refute has_element?(view, "[id^=subagent-tree-] [data-depth='8']")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[id^=subagent-tree-] li")
           |> Enum.count() == 8

    assert has_element?(view, "[id^=subagent-tree-truncated-]")
  end

  test "recovered parent chains keep exact depths and stop at cycles" do
    rows =
      [
        {"root", nil},
        {"child", "root"},
        {"cycle-a", "cycle-b"},
        {"cycle-b", "cycle-a"}
      ]
      |> Enum.map(fn {id, parent} ->
        %{"runId" => id, "parentRunId" => parent, "status" => "completed"}
      end)

    projection = LemonWeb.Chat.Subagents.from_recovery(%{"status" => "ok", "items" => rows})
    depths = Map.new(projection.nodes, &{&1.id, &1.depth})

    assert projection.status == :available
    assert depths == %{"root" => 0, "child" => 1, "cycle-a" => 1, "cycle-b" => 1}
  end

  test "unavailable runtime stays distinct from empty and recovers on connected refresh", ctx do
    Application.delete_env(:lemon_core, :agent_runtime_provider)
    {:ok, view, _} = open(ctx.conn, session_key("unavailable"))
    assert has_element?(view, "[id^=subagent-tree-unavailable-]")
    refute has_element?(view, "[id^=subagent-tree-empty-]")

    Application.put_env(
      :lemon_core,
      :agent_runtime_provider,
      CodingAgent.ControlPlaneProvider
    )

    send(view.pid, :refresh_subagents)
    assert has_element?(view, "[id^=subagent-tree-empty-]")
    refute has_element?(view, "[id^=subagent-tree-unavailable-]")
  end

  defp open(conn, key) do
    {:ok, view, _} = live(conn, "/chat/#{URI.encode_www_form(key)}")
    [pane] = Enum.reject(live_children(view), &(&1.id == "lemon-shell"))
    render_click(pane, "inspector-tab", %{"tab" => "subagents"})
    {:ok, pane, nil}
  end

  defp active(run_id) do
    Application.put_env(:lemon_web, :chat_rpc_stub, fn
      "sessions.active", %{"sessionKey" => key} ->
        {:ok, %{"sessionKey" => key, "runId" => run_id}}

      _method, _params ->
        :passthrough
    end)
  end

  defp graph_run do
    run = RunGraph.new_run(%{})
    on_exit(fn -> RunGraph.delete_run(run) end)
    run
  end

  defp task(key, parent, extra \\ %{}) do
    run = RunGraph.new_run(%{parent: parent, type: :task})
    RunGraph.add_child(parent, run)

    id =
      TaskStore.new_task(
        Map.merge(
          %{
            session_key: key,
            run_id: run,
            parent_run_id: parent,
            description: "PRIVATE_DESCRIPTION",
            prompt: "PRIVATE_PROMPT",
            cwd: "/private/workspace",
            meta: %{api_key: "sk-tree-secret"}
          },
          extra
        )
      )

    on_exit(fn ->
      TaskStore.delete_task(id)
      RunGraph.delete_run(run)
    end)

    {run, id}
  end

  defp session_key(label),
    do: "agent:web_tree_#{label}_#{System.unique_integer([:positive])}:main"

  defp eventually(fun, attempts \\ 150) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("connected tree did not refresh")

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
