defmodule LemonAutomation.ChatCommands.KanbanTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.KanbanStore
  alias LemonAutomation.ChatCommands.Kanban

  defmodule KanbanDispatcherStub do
    def start_board(board_id, opts) do
      send(Process.get(:kanban_status_message_test_pid), {:start_board, board_id, opts})

      {:ok,
       %{
         board_id: board_id,
         status: "running",
         max_concurrency: Keyword.get(opts, :max_concurrency, 1)
       }}
    end

    def status(board_id, _opts) do
      {:ok, %{running: true, dispatcher: %{board_id: board_id, status: "running"}}}
    end

    def stop_board(board_id, _opts) do
      {:ok, %{board_id: board_id, status: "stopped", max_concurrency: 1}}
    end
  end

  setup do
    Process.put(:kanban_status_message_test_pid, self())

    workspace =
      Path.join(System.tmp_dir!(), "kanban-chat-unit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      KanbanStore.list_boards(limit: 1_000)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)

      File.rm_rf!(workspace)
    end)

    opts = [
      agent_id: "codex",
      session_key: "agent:codex:telegram:default:dm:42",
      workspace: workspace,
      operator?: true,
      channel_context: %{channel_id: "telegram", peer_kind: :dm, peer_id: "42"},
      meta: %{"notificationSessionKey" => "agent:codex:telegram:default:dm:42"},
      dispatcher_module: KanbanDispatcherStub
    ]

    %{opts: opts}
  end

  test "creates and renders redacted board and task status", %{opts: opts} do
    private_board = "secret board #{System.unique_integer([:positive])}"
    private_task = "secret task #{System.unique_integer([:positive])}"
    private_comment = "secret comment #{System.unique_integer([:positive])}"

    board_text = Kanban.handle("create #{private_board}", opts)
    assert board_text =~ "Kanban Board Created"
    refute board_text =~ private_board
    assert board_text =~ "Name bytes:"

    [board] = Enum.filter(KanbanStore.list_boards(limit: 1_000), &(&1.name == private_board))
    assert board.owner == "codex"
    assert board.meta["kanbanAuthority"]["grantedBy"] == "channel"

    task_text =
      Kanban.handle("task create #{board.id} --priority high #{private_task}", opts)

    assert task_text =~ "Kanban Task Created"
    assert task_text =~ "Priority: high"
    refute task_text =~ private_task

    [task] = KanbanStore.list_tasks(board.id, limit: 1)
    assert task.assignee == "codex"
    assert is_map(task.meta["dispatchPolicy"])

    comment_text = Kanban.handle("comment #{task.id} #{private_comment}", opts)
    assert comment_text =~ "Kanban Task Commented"
    assert comment_text =~ "Comments: 1"
    refute comment_text =~ private_comment

    show_text = Kanban.handle("show #{board.id}", opts)
    assert show_text =~ board.id
    assert show_text =~ task.id
    refute show_text =~ private_board
    refute show_text =~ private_task
    refute show_text =~ private_comment

    archive_text = Kanban.handle("archive #{board.id}", opts)
    assert archive_text =~ "Kanban Board Archived"
    assert archive_text =~ "Status: archived"
    refute archive_text =~ private_board
  end

  test "updates task and controls dispatcher through configured module", %{opts: opts} do
    assert Kanban.handle("create dispatch board", opts) =~ "Kanban Board Created"
    [board] = Enum.filter(KanbanStore.list_boards(limit: 1_000), &(&1.name == "dispatch board"))
    assert Kanban.handle("task create #{board.id} task title", opts) =~ "Created"
    [task] = KanbanStore.list_tasks(board.id)

    update_text = Kanban.handle("task update #{task.id} --status doing", opts)
    assert update_text =~ "Kanban Task Updated"
    assert update_text =~ "Status: doing"

    start_text =
      Kanban.handle("dispatch start #{board.id} --max-concurrency 2", opts)

    assert start_text =~ "Kanban Dispatcher Started"
    board_id = board.id
    assert_receive {:start_board, ^board_id, start_opts}
    assert start_opts[:max_concurrency] == 2
    assert start_opts[:worker_id] == "codex"

    status_text = Kanban.handle("dispatch status #{board.id}", opts)
    assert status_text =~ "Running: true"

    stop_text = Kanban.handle("dispatch stop #{board.id}", opts)
    assert stop_text =~ "Kanban Dispatcher Stopped"
  end

  test "mutations need operator attestation and the board's principal", %{opts: opts} do
    assert Kanban.handle("create owned board", opts) =~ "Kanban Board Created"
    [board] = Enum.filter(KanbanStore.list_boards(limit: 1_000), &(&1.name == "owned board"))

    member = Keyword.put(opts, :operator?, false)
    assert Kanban.handle("dispatch stop #{board.id}", member) =~ "operator"
    assert Kanban.handle("create another", member) =~ "operator"

    other_chat = Keyword.put(opts, :session_key, "agent:codex:telegram:default:dm:43")
    assert Kanban.handle("dispatch stop #{board.id}", other_chat) =~ "not authorized"
    assert Kanban.handle("show #{board.id}", other_chat) =~ "not authorized"
    refute Kanban.handle("boards", other_chat) =~ board.id

    for flag <- ~w(--owner --workspace --assignee --worker-id --session-key --run-id) do
      assert Kanban.handle("create flagged #{flag} x", opts) =~ "not accepted"
    end

    no_workspace = Keyword.delete(opts, :workspace)
    assert Kanban.handle("create nowhere", no_workspace) =~ "bound project"
  end
end
