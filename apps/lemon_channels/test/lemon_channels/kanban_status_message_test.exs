defmodule LemonChannels.KanbanStatusMessageTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.KanbanStatusMessage
  alias LemonCore.KanbanStore

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

    on_exit(fn ->
      KanbanStore.list_boards(limit: 100)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)
    end)

    :ok
  end

  test "creates and renders redacted board and task status" do
    private_board = "secret board #{System.unique_integer([:positive])}"
    private_task = "secret task #{System.unique_integer([:positive])}"
    private_comment = "secret comment #{System.unique_integer([:positive])}"

    board_text =
      KanbanStatusMessage.handle("create --workspace /tmp/lemon #{private_board}",
        owner: "codex"
      )

    assert board_text =~ "Kanban Board Created"
    refute board_text =~ private_board
    assert board_text =~ "Name bytes:"

    [board] = KanbanStore.list_boards(owner: "codex", limit: 1)

    task_text =
      KanbanStatusMessage.handle(
        "task create #{board.id} --priority high --assignee sonnet #{private_task}"
      )

    assert task_text =~ "Kanban Task Created"
    assert task_text =~ "Priority: high"
    refute task_text =~ private_task

    [task] = KanbanStore.list_tasks(board.id, limit: 1)

    comment_text = KanbanStatusMessage.handle("comment #{task.id} #{private_comment}")
    assert comment_text =~ "Kanban Task Commented"
    assert comment_text =~ "Comments: 1"
    refute comment_text =~ private_comment

    show_text = KanbanStatusMessage.handle("show #{board.id}")
    assert show_text =~ board.id
    assert show_text =~ task.id
    refute show_text =~ private_board
    refute show_text =~ private_task
    refute show_text =~ private_comment

    archive_text = KanbanStatusMessage.handle("archive #{board.id}")
    assert archive_text =~ "Kanban Board Archived"
    assert archive_text =~ "Status: archived"
    refute archive_text =~ private_board
  end

  test "updates task and controls dispatcher through configured module" do
    {:ok, board} = KanbanStore.create_board("dispatch board")
    {:ok, task} = KanbanStore.create_task(board.id, "task title")

    update_text = KanbanStatusMessage.handle("task update #{task.id} --status doing")
    assert update_text =~ "Kanban Task Updated"
    assert update_text =~ "Status: doing"

    opts = [dispatcher_module: KanbanDispatcherStub]

    start_text =
      KanbanStatusMessage.handle("dispatch start #{board.id} --max-concurrency 2", opts)

    assert start_text =~ "Kanban Dispatcher Started"
    board_id = board.id
    assert_receive {:start_board, ^board_id, [max_concurrency: 2]}

    status_text = KanbanStatusMessage.handle("dispatch status #{board.id}", opts)
    assert status_text =~ "Running: true"

    stop_text = KanbanStatusMessage.handle("dispatch stop #{board.id}", opts)
    assert stop_text =~ "Kanban Dispatcher Stopped"
  end

  test "renders help and recognizes telegram kanban command for bot" do
    assert KanbanStatusMessage.handle("wat") =~ "Kanban Commands"
    assert Commands.kanban_command?("/kanban", "lemon_bot")
    assert Commands.kanban_command?("/kanban@lemon_bot", "lemon_bot")
    refute Commands.kanban_command?("/kanban@other_bot", "lemon_bot")
  end
end
