defmodule LemonChannels.Adapters.Telegram.TransportKanbanTest do
  @moduledoc """
  `/kanban` through the real Telegram transport against
  `LemonChannels.Telegram.FakeAPI`. Mutations need the transport's operator
  attestation; the principal, workspace and tool policy come from the chat's
  trusted context, never from command flags.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.KanbanStore
  alias LemonChannels.Adapters.Telegram
  alias LemonChannels.Telegram.FakeAPI
  alias LemonCore.ToolPolicy

  defmodule Dispatcher do
    def start_board(board_id, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:start_board, board_id, opts})
      {:ok, %{board_id: board_id, status: "running", max_concurrency: 1}}
    end

    def stop_board(board_id, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:stop_board, board_id, opts})
      {:ok, %{board_id: board_id, status: "stopped", max_concurrency: 1}}
    end

    def status(board_id, _opts),
      do: {:ok, %{running: true, dispatcher: %{board_id: board_id, status: "running"}}}
  end

  @gateway_config_key :gateway_test_config
  @group -100_555_001
  @owner 555_001
  @member 555_002

  setup do
    unless Process.whereis(LemonChannels.Adapters.Telegram.AsyncSupervisor) do
      start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor})
    end

    stop_transport()
    FakeAPI.reset()
    root = Path.join(System.tmp_dir!(), "kanban-chat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {real_root, 0} = System.cmd("pwd", ["-P"], cd: root)

    previous_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    previous_dispatcher = Application.get_env(:lemon_channels, :kanban_dispatcher_module)
    :persistent_term.put({Dispatcher, :pid}, self())
    Application.put_env(:lemon_channels, :kanban_dispatcher_module, Dispatcher)

    Application.put_env(:lemon_core, @gateway_config_key, %{
      telegram: %{bot_token: "fake-token", api_mod: FakeAPI},
      bindings: [
        %{transport: :telegram, chat_id: @group, project: "kanban-chat"},
        %{transport: :telegram, chat_id: @owner, project: "kanban-chat"}
      ],
      projects: %{"kanban-chat" => %{root: root}}
    })

    on_exit(fn ->
      stop_transport()
      FakeAPI.reset()
      :persistent_term.erase({Dispatcher, :pid})
      restore_env(:lemon_core, @gateway_config_key, previous_gateway)
      restore_env(:lemon_channels, :kanban_dispatcher_module, previous_dispatcher)

      KanbanStore.list_boards(limit: 1_000)
      |> Enum.filter(&String.starts_with?(&1.name, "chat-"))
      |> Enum.each(&KanbanStore.clear_board(&1.id))

      File.rm_rf!(root)
    end)

    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [@group, @owner]})
    %{root: String.trim(real_root)}
  end

  test "a group member without operator attestation cannot mutate kanban work" do
    name = "chat-member-#{System.unique_integer([:positive])}"
    assert reply(@group, "/kanban create #{name}", @member) =~ "operator"
    refute Enum.any?(KanbanStore.list_boards(limit: 1_000), &(&1.name == name))
  end

  test "command flags never override the trusted owner, workspace or assignee", %{root: root} do
    name = "chat-flags-#{System.unique_integer([:positive])}"

    assert reply(@group, "/kanban create #{name} --workspace /etc --owner victim", @owner) =~
             "not accepted"

    refute Enum.any?(KanbanStore.list_boards(limit: 1_000), &(&1.name == name))

    assert reply(@group, "/kanban create #{name}", @owner) =~ "Kanban Board Created"
    [board] = Enum.filter(KanbanStore.list_boards(limit: 1_000), &(&1.name == name))
    assert board.workspace == root

    authority = board.meta["kanbanAuthority"]
    assert authority["principal"]["sessionKey"] =~ "telegram"
    assert authority["principal"]["sessionKey"] =~ Integer.to_string(@group)
    # A group chat's run approval floor is recorded for every worker.
    assert ToolPolicy.requires_approval?(authority["policy"], "bash", %{"command" => "ls"}, :exec)

    assert reply(@group, "/kanban task create #{board.id} --assignee victim Do it", @owner) =~
             "not accepted"

    assert KanbanStore.list_tasks(board.id) == []
  end

  test "dispatch control requires operator attestation in the owning chat" do
    name = "chat-dispatch-#{System.unique_integer([:positive])}"
    assert reply(@group, "/kanban create #{name}", @owner) =~ "Kanban Board Created"
    [board] = Enum.filter(KanbanStore.list_boards(limit: 1_000), &(&1.name == name))

    assert reply(@group, "/kanban dispatch stop #{board.id}", @member) =~ "operator"
    refute_received {:stop_board, _, _}

    # The same human in another chat is a different principal.
    assert reply(@owner, "/kanban dispatch stop #{board.id}", @owner) =~ "not authorized"
    refute_received {:stop_board, _, _}
    assert reply(@owner, "/kanban show #{board.id}", @owner) =~ "not authorized"
    refute reply(@owner, "/kanban boards", @owner) =~ board.id

    assert reply(@group, "/kanban dispatch stop #{board.id}", @owner) =~
             "Kanban Dispatcher Stopped"

    board_id = board.id
    assert_received {:stop_board, ^board_id, _}
  end

  # Clears captured calls so only the reply to this command can match.
  defp reply(chat_id, text, user_id) do
    FakeAPI.clear()
    FakeAPI.simulate_message(chat_id, text, user_id: user_id)
    await_text(chat_id, "Kanban")
  end

  defp await_text(chat_id, fragment) do
    assert {:ok, %{args: [^chat_id, text | _]}} =
             FakeAPI.await_send(
               fn
                 %{fun: :send_message, args: [^chat_id, text | _]} ->
                   String.contains?(text, fragment)

                 _ ->
                   false
               end,
               2_000
             )

    text
  end

  defp start_transport(overrides) do
    token = "kanban-test-#{System.pid()}-#{System.unique_integer([:positive])}"

    config =
      %{bot_token: token, api_mod: FakeAPI, poll_interval_ms: 10, debounce_ms: 10}
      |> Map.merge(overrides)

    case LemonChannels.Registry.register(Telegram) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    Telegram.Transport.start_link(config: config)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_transport do
    if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end

    if Process.whereis(LemonChannels.Registry),
      do: LemonChannels.Registry.unregister("telegram")
  catch
    :exit, _ -> :ok
  end
end
