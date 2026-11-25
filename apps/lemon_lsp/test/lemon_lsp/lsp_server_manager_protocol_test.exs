defmodule LemonLsp.ServerManagerProtocolTest do
  use ExUnit.Case, async: false

  alias LemonLsp.ServerManager

  @env "LEMON_LSP_ELIXIR_LS_COMMAND"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lsp_protocol_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    previous_paths = Application.get_env(:lemon_core, :paths)
    global_config = Path.join(tmp_dir, "global.toml")
    Application.put_env(:lemon_core, :paths, global_config: global_config)
    LemonCore.ConfigCache.clear()

    File.write!(
      global_config,
      "[runtime.tools.lsp]\nidle_timeout_ms = 0\n"
    )

    server_path = Path.join(tmp_dir, "fake_protocol_server.exs")
    File.write!(server_path, fake_server_script())
    File.chmod!(server_path, 0o755)

    previous = System.get_env(@env)
    System.put_env(@env, server_path)
    session_id = "lsp-protocol-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = ServerManager.stop_session(session_id)
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)

      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      LemonCore.ConfigCache.clear()
      File.rm_rf!(tmp_dir)
    end)

    if System.find_executable("elixir") do
      {:ok, tmp_dir: tmp_dir, session_id: session_id, global_config: global_config}
    else
      {:skip, "elixir executable is not on PATH"}
    end
  end

  test "session cleanup contains no process sleeps" do
    for module <- ["server_manager.ex", "session.ex"] do
      source = Path.expand("../../lib/lemon_lsp/#{module}", __DIR__)
      refute File.read!(source) =~ "Process.sleep"
    end
  end

  test "a slow fake server and a suspended session cannot block another root", context do
    {first, second, first_pid} = isolated_pair(context)

    request =
      :gen_server.send_request(
        ServerManager,
        {:request_session, first, "fake/slow", %{}, 20_000,
         %{on_timeout: :cancel, capture_edits: false}}
      )

    # A response from the same fake server proves it consumed the slow request.
    assert {:ok, _} = ServerManager.request_session(first, "fake/pid", %{}, timeout_ms: 20_000)
    :ok = :sys.suspend(first_pid)

    try do
      assert {:ok, response} =
               ServerManager.request_session(second, "fake/pid", %{}, timeout_ms: 2_000)

      assert is_binary(response["result"]["pid"])
      assert :timeout = :gen_server.wait_response(request, 0)
    after
      :sys.resume(first_pid)
    end

    assert {:ok, _} = ServerManager.stop_session(first)
    assert {:reply, {:error, :session_stopped}} = :gen_server.receive_response(request, 2_000)
  end

  test "a fake server crash and session crash leave its sibling alive", context do
    {first, second, first_pid} = isolated_pair(context)
    manager = Process.whereis(ServerManager)
    first_monitor = Process.monitor(first_pid)

    assert {:error, :session_exited} =
             ServerManager.request_session(first, "fake/crash", %{}, timeout_ms: 20_000)

    assert {:ok, _} = ServerManager.request_session(second, "fake/pid")
    assert Process.alive?(manager)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, :normal}, 2_000
    [{second_pid, _}] = Registry.lookup(LemonLsp.SessionRegistry, {:id, manager, second})
    monitor = Process.monitor(second_pid)
    Process.exit(second_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^second_pid, :killed}, 2_000
    assert Process.alive?(manager)

    assert {:ok, restarted} =
             ServerManager.start_session(:elixir_ls, cwd: context.tmp_dir, session_id: first)

    assert restarted.session_id == first
    assert {:ok, _} = ServerManager.request_session(first, "fake/pid", %{}, timeout_ms: 20_000)
  end

  defp isolated_pair(context) do
    first = context.session_id
    second = first <> "-other-root"
    other_root = Path.join(context.tmp_dir, "other")
    File.mkdir_p!(other_root)
    on_exit(fn -> ServerManager.stop_session(second) end)

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: context.tmp_dir, session_id: first)

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls,
               cwd: other_root,
               config_root: context.tmp_dir,
               session_id: second
             )

    assert {:ok, _} = ServerManager.request_session(first, "fake/pid", %{}, timeout_ms: 20_000)
    assert {:ok, _} = ServerManager.request_session(second, "fake/pid", %{}, timeout_ms: 20_000)
    manager = Process.whereis(ServerManager)
    [{first_pid, _}] = Registry.lookup(LemonLsp.SessionRegistry, {:id, manager, first})
    {first, second, first_pid}
  end

  test "acknowledges edits only after applying them and permits reentrant manager calls", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    path = Path.join(tmp_dir, "applied.ex")
    uri = "file://" <> URI.encode(path)
    text = "updated\n"
    receipt = %{path: path, bytes: byte_size(text)}
    File.write!(path, "original\n")

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    apply_edit = fn edit ->
      assert %{"changes" => %{^uri => [%{"newText" => ^text}]}} = edit
      assert {:ok, %{seq: 0, entry: nil}} = ServerManager.document_diagnostics(session_id, uri)

      assert {:error, :edit_request_in_progress} =
               ServerManager.request_with_edits(session_id, "workspace/executeCommand", %{},
                 timeout_ms: 2_000,
                 apply_edit: fn _ -> flunk("an overlapping operation must not capture edits") end
               )

      assert {:ok, probe} =
               ServerManager.request_session(session_id, "fake/editProbe", %{"path" => path},
                 timeout_ms: 2_000
               )

      assert probe["result"] == %{
               "applyEditAcknowledged" => false,
               "bytes" => "original\n"
             }

      File.write!(path, text)
      {:ok, receipt}
    end

    assert {:ok, response, [{:ok, ^receipt}]} =
             ServerManager.request_with_edits(
               session_id,
               "workspace/executeCommand",
               %{"command" => "fake.apply", "path" => path, "text" => text},
               timeout_ms: 20_000,
               apply_edit: apply_edit
             )

    # The server's configuration request reused the pending client id; it must
    # be answered as a server request rather than completing our call.
    assert response["result"]["configuration"] == [nil, nil]
    assert response["result"]["applyEdit"] == %{"applied" => true}
    assert response["result"]["bytesAfterAck"] == text
    assert File.read!(path) == text

    assert {:ok, plain} =
             ServerManager.request_session(
               session_id,
               "workspace/executeCommand",
               %{"path" => path, "text" => "unrequested\n"},
               timeout_ms: 20_000
             )

    assert plain["result"]["applyEdit"]["applied"] == false
    assert plain["result"]["bytesAfterAck"] == text
    assert File.read!(path) == text
  end

  test "reports callback failure to the server without changing the file", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    path = Path.join(tmp_dir, "rejected.ex")
    uri = "file://" <> URI.encode(path)
    reason = "workspace edit rejected"
    File.write!(path, "original\n")

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    assert {:ok, response, [{:error, ^reason}]} =
             ServerManager.request_with_edits(
               session_id,
               "workspace/executeCommand",
               %{"path" => path, "text" => "rejected\n"},
               timeout_ms: 20_000,
               apply_edit: fn edit ->
                 assert %{"changes" => %{^uri => [%{"newText" => "rejected\n"}]}} = edit
                 {:error, reason}
               end
             )

    assert response["result"]["applyEdit"] == %{
             "applied" => false,
             "failureReason" => reason
           }

    assert response["result"]["bytesAfterAck"] == "original\n"
    assert File.read!(path) == "original\n"
  end

  test "keeps raw diagnostics per document while status stays redacted", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    uri = "file://#{tmp_dir}/secret.ex"

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)
    assert {:ok, %{seq: 0, entry: nil}} = ServerManager.document_diagnostics(session_id, uri)

    assert {:ok, _} = ServerManager.open_document(session_id, uri, "elixir", "x", version: 3)

    entry =
      wait_until(fn ->
        case ServerManager.document_diagnostics(session_id, uri) do
          {:ok, %{entry: %{} = entry}} -> entry
          _ -> nil
        end
      end)

    assert entry.version == 3
    assert entry.seq == 1
    assert [%{"message" => "private diagnostic text"}] = entry.diagnostics
    refute inspect(ServerManager.status()) =~ "private diagnostic text"
    refute inspect(ServerManager.status()) =~ tmp_dir
  end

  test "cancel-on-timeout keeps the session and notifies the server", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    assert {:error, :request_timeout} =
             ServerManager.request_session(session_id, "fake/slow", %{},
               timeout_ms: 200,
               on_timeout: :cancel
             )

    assert {:ok, response} =
             ServerManager.request_session(session_id, "fake/cancelled", %{}, timeout_ms: 20_000)

    assert [id] = response["result"]
    assert is_integer(id)
  end

  test "cancels an in-flight edit callback before acknowledging timeout with no late writes", %{
    tmp_dir: tmp_dir,
    session_id: session_id
  } do
    path = Path.join(tmp_dir, "cancelled.ex")
    File.write!(path, "original\n")
    caller = self()

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: tmp_dir, session_id: session_id)

    assert {:ok, _} = ServerManager.initialize_session(session_id, %{}, timeout_ms: 20_000)

    request =
      Task.async(fn ->
        ServerManager.request_with_edits(
          session_id,
          "workspace/executeCommand",
          %{"path" => path, "text" => "late\n"},
          timeout_ms: 1_000,
          on_timeout: :cancel,
          apply_edit: fn _edit ->
            send(caller, {:callback_started, self()})

            receive do
              :finish ->
                File.write!(path, "late\n")
                {:ok, %{path: path}}
            end
          end
        )
      end)

    assert_receive {:callback_started, worker}, 1_000
    monitor = Process.monitor(worker)
    assert {:error, :request_timeout} = Task.await(request, 2_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000

    # A released callback must not outlive the request and mutate the workspace.
    send(worker, :finish)

    assert {:ok, response} =
             ServerManager.request_session(session_id, "fake/editStatus", %{}, timeout_ms: 2_000)

    assert response["result"]["applyEdit"]["applied"] == false
    assert is_binary(response["result"]["applyEdit"]["failureReason"])
    assert response["result"]["bytesAfterAck"] == "original\n"
    assert [id] = response["result"]["cancelled"]
    assert id == response["result"]["commandId"]
    assert File.read!(path) == "original\n"
  end

  test "stops the session when its owner exits", %{tmp_dir: tmp_dir, session_id: session_id} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls,
               cwd: tmp_dir,
               session_id: session_id,
               owner: owner
             )

    send(owner, :stop)

    assert wait_until(fn ->
             status = ServerManager.status()

             Enum.find(
               status.recent_sessions,
               &(&1.session_hash == session.session_hash and &1.status == :idle)
             )
           end)

    assert {:error, :unknown_lsp_session} = ServerManager.stop_session(session_id)
  end

  test "shares one process, initializes once and reference-counts owners", ctx do
    owner = start_owner()
    before_count = ServerManager.status().active_count

    assert {:ok, first} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    assert {:ok, second} = ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, owner: owner)
    assert first.session_id == second.session_id
    assert {:ok, _} = ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir)
    assert ServerManager.status().active_count == before_count + 1

    initializers =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              ServerManager.initialize_session(first.session_id, %{}, timeout_ms: 5_000)
            end)

    Enum.each(initializers, fn task -> assert {:ok, _} = Task.await(task, 6_000) end)
    assert {:ok, response} = ServerManager.request_session(first.session_id, "fake/pid")
    assert response["result"]["initializations"] == 1
    assert is_binary(response["result"]["pid"])

    active =
      Enum.find(ServerManager.status().active_servers, &(&1.session_hash == first.session_hash))

    assert active.owner_count == 3
    assert :ok = ServerManager.release_session(first.session_id)
    assert :ok = ServerManager.release_session(first.session_id)
    assert {:ok, same} = ServerManager.request_session(second.session_id, "fake/pid")
    assert same["result"]["pid"] == response["result"]["pid"]
    assert :ok = ServerManager.release_session(second.session_id, owner)

    assert wait_until(fn ->
             match?(
               {:error, :unknown_lsp_session},
               ServerManager.document_diagnostics(first.session_id, "file:///gone")
             )
           end)
  end

  test "idle shutdown starts only after the last release and reacquisition cancels it", ctx do
    config = ctx.global_config
    File.write!(config, "[runtime.tools.lsp]\nidle_timeout_ms = 300\n")
    LemonCore.Config.reload(ctx.tmp_dir)
    owner = start_owner()

    assert {:ok, first} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    assert {:ok, _} = ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, owner: owner)
    assert :ok = ServerManager.release_session(first.session_id)
    Process.sleep(350)
    assert {:ok, _} = ServerManager.document_diagnostics(first.session_id, "file:///alive")
    assert :ok = ServerManager.release_session(first.session_id, owner)
    assert {:ok, _} = ServerManager.document_diagnostics(first.session_id, "file:///idle")
    Process.sleep(100)
    assert {:ok, reused} = ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir)
    assert reused.session_id == first.session_id
    Process.sleep(250)
    assert {:ok, _} = ServerManager.document_diagnostics(first.session_id, "file:///reacquired")
    assert :ok = ServerManager.release_session(first.session_id)

    assert wait_until(fn ->
             match?(
               {:error, :unknown_lsp_session},
               ServerManager.document_diagnostics(first.session_id, "file:///gone")
             )
           end)
  end

  test "document versions and diagnostic delivery are shared across owners", ctx do
    first_owner = start_owner()
    second_owner = start_owner()
    path = Path.join(ctx.tmp_dir, "shared.ex")
    uri = "file://" <> URI.encode(path)
    File.write!(path, "first")

    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls,
               cwd: ctx.tmp_dir,
               owner: first_owner,
               session_id: ctx.session_id
             )

    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, owner: second_owner)

    assert {:ok, _} = ServerManager.initialize_session(session.session_id, %{}, timeout_ms: 5_000)
    sid = session.session_id

    assert {:ok, %{version: 1, synced: :opened}} =
             owner_call(first_owner, fn -> ServerManager.sync_file(sid, path, "elixir") end)

    assert_receive {:owner_message, ^first_owner,
                    {ServerManager, :diagnostics, ^sid, ^uri, %{version: 1}}},
                   2_000

    assert_receive {:owner_message, ^second_owner,
                    {ServerManager, :diagnostics, ^sid, ^uri, %{version: 1}}},
                   2_000

    assert {:ok, %{version: 1, synced: :unchanged}} =
             owner_call(second_owner, fn -> ServerManager.sync_file(sid, path, "elixir") end)

    File.write!(path, "second")

    assert {:ok, %{version: 2, synced: :changed}} =
             owner_call(second_owner, fn -> ServerManager.sync_file(sid, path, "elixir") end)

    assert {:ok, %{version: 2, synced: :unchanged}} =
             owner_call(first_owner, fn -> ServerManager.sync_file(sid, path, "elixir") end)

    File.write!(path, "third")

    assert {:ok, %{version: 3, synced: :changed}} =
             owner_call(first_owner, fn -> ServerManager.sync_file(sid, path, "elixir") end)

    assert {:ok, _} = owner_call(first_owner, fn -> ServerManager.close_document(sid, uri) end)
    assert {:ok, events} = ServerManager.request_session(sid, "fake/events")
    methods = Enum.map(events["result"], & &1["method"])
    assert methods == ["textDocument/didOpen", "textDocument/didChange", "textDocument/didChange"]
    assert {:ok, _} = owner_call(second_owner, fn -> ServerManager.close_document(sid, uri) end)
    assert {:ok, events} = ServerManager.request_session(sid, "fake/events")
    assert List.last(events["result"])["method"] == "textDocument/didClose"
    Process.exit(first_owner, :kill)

    assert wait_until(fn ->
             active =
               Enum.find(
                 ServerManager.status().active_servers,
                 &(&1.session_hash == session.session_hash)
               )

             active && active.owner_count == 1
           end)

    assert {:ok, _} = ServerManager.request_session(sid, "fake/pid")
    Process.exit(second_owner, :kill)

    assert wait_until(fn ->
             match?({:error, :unknown_lsp_session}, ServerManager.document_diagnostics(sid, uri))
           end)
  end

  test "a non-UTF-8 document is rejected without crashing the shared session", ctx do
    latin1 = Path.join(ctx.tmp_dir, "latin1.ex")
    valid = Path.join(ctx.tmp_dir, "valid.ex")
    File.write!(latin1, <<"secret_caf", 0xE9, " = 1\n">>)
    File.write!(valid, "valid = 1\n")

    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    sid = session.session_id
    assert {:ok, _} = ServerManager.initialize_session(sid, %{}, timeout_ms: 5_000)
    [{pid, _}] = Registry.lookup(LemonLsp.SessionRegistry, {:id, manager(), sid})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        bad = Task.async(fn -> ServerManager.sync_file(sid, latin1, "elixir") end)
        good = Task.async(fn -> ServerManager.sync_file(sid, valid, "elixir") end)
        other = Task.async(fn -> ServerManager.request_session(sid, "fake/pid") end)

        assert {:error, :invalid_document_encoding} = Task.await(bad)
        assert {:ok, %{synced: :opened, version: 1}} = Task.await(good)
        assert {:ok, %{"result" => %{"pid" => _}}} = Task.await(other)

        assert {:error, :invalid_document_encoding} =
                 ServerManager.open_document(sid, "file:///latin1.ex", "elixir", <<0xE9>>)

        assert {:error, :invalid_document_encoding} =
                 ServerManager.change_document(sid, "file:///valid.ex", <<0xE9>>, version: 2)

        assert {:error, :invalid_document_uri} =
                 ServerManager.close_document(sid, <<"file:///", 0xE9>>)
      end)

    refute log =~ "secret_caf"
    assert Process.alive?(pid)
    assert [{^pid, _}] = Registry.lookup(LemonLsp.SessionRegistry, {:id, manager(), sid})
    assert {:ok, events} = ServerManager.request_session(sid, "fake/events")
    assert [%{"method" => "textDocument/didOpen", "params" => params}] = events["result"]
    assert params["textDocument"]["text"] == "valid = 1\n"
  end

  test "a transport encoding failure is an error reply, not a session crash", ctx do
    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    sid = session.session_id
    [{pid, _}] = Registry.lookup(LemonLsp.SessionRegistry, {:id, manager(), sid})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_message_encoding} =
                 ServerManager.notify_session(sid, "fake/note", %{"text" => <<"secret", 0xFF>>})

        assert {:error, :invalid_message_encoding} =
                 ServerManager.request_session(sid, "fake/pid", %{"text" => <<"secret", 0xFF>>})
      end)

    refute log =~ "secret"
    assert Process.alive?(pid)
    assert ServerManager.status().pending_request_count == 0
    assert {:ok, %{"result" => %{"pid" => _}}} = ServerManager.request_session(sid, "fake/pid")
  end

  test "any session exit during a call is an error reply without raw exit terms", ctx do
    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    sid = session.session_id
    [{pid, _}] = Registry.lookup(LemonLsp.SessionRegistry, {:id, manager(), sid})
    :ok = :sys.suspend(pid)

    assert {:error, {:session_crashed, :timeout}} =
             ServerManager.request_session(sid, "fake/pid", %{}, timeout_ms: 50)

    call = Task.async(fn -> ServerManager.document_diagnostics(sid, "file:///x") end)
    # The timed-out request is still queued; wait for the second call to join it.
    assert wait_until(fn -> elem(Process.info(pid, :message_queue_len), 1) >= 2 end)
    monitor = Process.monitor(pid)

    ExUnit.CaptureLog.capture_log(fn ->
      :sys.terminate(pid, {:secret_reason, <<0xE9>>})
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
    end)

    assert {:error, {:session_crashed, :abnormal_exit}} = Task.await(call)
  end

  test "crash fails every in-flight request and the next acquire starts a new process", ctx do
    owner = start_owner()

    assert {:ok, session} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    assert {:ok, _} = ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, owner: owner)
    assert {:ok, _} = ServerManager.initialize_session(session.session_id, %{}, timeout_ms: 5_000)
    assert {:ok, before} = ServerManager.request_session(session.session_id, "fake/pid")

    requests =
      for _ <- 1..2,
          do:
            Task.async(fn ->
              ServerManager.request_session(session.session_id, "fake/slow", %{},
                timeout_ms: 5_000
              )
            end)

    assert wait_until(fn -> ServerManager.status().pending_request_count == 2 end)

    assert {:error, :session_exited} =
             ServerManager.request_session(session.session_id, "fake/crash")

    Enum.each(requests, fn task -> assert {:error, :session_exited} = Task.await(task, 2_000) end)
    sid = session.session_id
    assert_receive {ServerManager, :server_stopped, ^sid}, 2_000
    assert_receive {:owner_message, ^owner, {ServerManager, :server_stopped, ^sid}}, 2_000

    assert {:ok, restarted} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    assert {:ok, _} =
             ServerManager.initialize_session(restarted.session_id, %{}, timeout_ms: 5_000)

    assert {:ok, after_restart} = ServerManager.request_session(restarted.session_id, "fake/pid")
    refute before["result"]["pid"] == after_restart["result"]["pid"]
  end

  describe "live session cap" do
    setup do
      assert wait_until(fn -> ServerManager.status().active_count == 0 end)
      %{max: ServerManager.status().max_active_count}
    end

    test "is reported in status with the live count", %{max: max} do
      # `status/0` degrades to the unavailable projection when the manager is
      # slower than its 1 s probe (a loaded machine); read a live projection.
      status = wait_until(fn -> (status = ServerManager.status()).running && status end)
      assert max == 8
      assert status.max_active_count == 8
      assert status.active_count == 0
      assert :live_session_cap in status.capabilities
      assert :workspace_root_detection in status.capabilities
      refute :workspace_root_detection in status.planned_capabilities
    end

    test "opening one root beyond the cap evicts the least-recently-used idle session", ctx do
      [first, second | rest] = ids = start_roots(ctx, 1..ctx.max)
      assert wait_until(fn -> ServerManager.status().active_count == ctx.max end)

      # Use every session except `second` after it, making it the LRU one.
      for id <- [first | rest], do: assert({:ok, _} = touch(id))
      lru = session_pid(second)
      monitor = Process.monitor(lru)

      [extra] = start_roots(ctx, [ctx.max + 1])

      assert_receive {:DOWN, ^monitor, :process, ^lru, :normal}, 2_000
      assert_receive {ServerManager, :server_stopped, ^second}, 2_000
      assert {:error, :unknown_lsp_session} = touch(second)
      for id <- [extra | List.delete(ids, second)], do: assert({:ok, _} = touch(id))

      assert wait_until(fn ->
               status = ServerManager.status()

               status.active_count == ctx.max and
                 Enum.any?(status.recent_sessions, &(&1.status == :evicted))
             end)
    end

    test "a session with an in-flight request is never evicted", ctx do
      [busy | others] = start_roots(ctx, 1..ctx.max)
      slow = slow_request(busy)
      assert wait_until(fn -> ServerManager.status().pending_request_count == 1 end)
      # `busy` is the least recently used session, but it is serving a request.
      for id <- others, do: assert({:ok, _} = touch(id))
      [next_lru | _] = others

      start_roots(ctx, [ctx.max + 1])

      assert wait_until(fn -> session_pid(next_lru) == nil end)
      assert {:ok, _} = touch(busy)
      assert Task.yield(slow, 0) == nil
      assert {:ok, _} = ServerManager.stop_session(busy)
      assert {:error, :session_stopped} = Task.await(slow)
    end

    test "an acquire fails closed when every live session is busy", ctx do
      ids = start_roots(ctx, 1..ctx.max)
      requests = Enum.map(ids, &slow_request/1)
      assert wait_until(fn -> ServerManager.status().pending_request_count == ctx.max end)
      extra = Path.join(ctx.tmp_dir, "root-extra")
      File.mkdir_p!(extra)

      assert {:error, :lsp_session_limit} =
               ServerManager.start_session(:elixir_ls, cwd: extra, config_root: ctx.tmp_dir)

      assert Enum.all?(ids, &session_pid/1)
      Enum.each(ids, &ServerManager.stop_session/1)
      Enum.each(requests, &assert({:error, :session_stopped} = Task.await(&1)))
    end

    test "a session that cannot answer eviction is skipped for the next candidate", ctx do
      [stuck, next_lru | rest] = start_roots(ctx, 1..ctx.max)
      for id <- rest, do: assert({:ok, _} = touch(id))
      stuck_pid = session_pid(stuck)
      :ok = :sys.suspend(stuck_pid)

      try do
        start_roots(ctx, [ctx.max + 1])
        assert wait_until(fn -> session_pid(next_lru) == nil end)
        assert session_pid(stuck) == stuck_pid
      after
        :sys.resume(stuck_pid)
      end
    end
  end

  defp start_roots(ctx, indexes) do
    for index <- indexes do
      root = Path.join(ctx.tmp_dir, "root-#{index}")
      File.mkdir_p!(root)
      id = "#{ctx.session_id}-#{index}"
      on_exit(fn -> ServerManager.stop_session(id) end)

      assert {:ok, %{session_id: ^id}} =
               ServerManager.start_session(:elixir_ls,
                 cwd: root,
                 config_root: ctx.tmp_dir,
                 session_id: id
               )

      id
    end
  end

  defp touch(id), do: ServerManager.document_diagnostics(id, "file:///touch")

  defp slow_request(id) do
    Task.async(fn ->
      ServerManager.request_session(id, "fake/slow", %{},
        timeout_ms: 60_000,
        on_timeout: :cancel
      )
    end)
  end

  defp session_pid(id) do
    case Registry.lookup(LemonLsp.SessionRegistry, {:id, manager(), id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp manager, do: Process.whereis(ServerManager)

  defp start_owner do
    parent = self()
    pid = spawn(fn -> owner_loop(parent) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp owner_loop(parent) do
    receive do
      {:call, from, ref, fun} -> send(from, {ref, fun.()})
      message -> send(parent, {:owner_message, self(), message})
    end

    owner_loop(parent)
  end

  defp owner_call(owner, fun) do
    ref = make_ref()
    send(owner, {:call, self(), ref, fun})
    assert_receive {^ref, result}, 5_000
    result
  end

  defp wait_until(fun, attempts \\ 400)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      falsy when falsy in [nil, false] ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(fun, 0), do: fun.()

  defp fake_server_script do
    ~S"""
    #!/usr/bin/env elixir
    :io.setopts(:standard_io, encoding: :latin1, binary: true)

    defmodule Fake do
      def read do
        case headers(nil) do
          nil -> nil
          len -> :stdio |> IO.binread(len) |> JSON.decode!()
        end
      end

      defp headers(len) do
        case IO.binread(:stdio, :line) do
          line when is_binary(line) ->
            case String.trim(line) do
              "" -> len
              "Content-Length: " <> n -> headers(String.to_integer(n))
              _ -> headers(len)
            end

          _ ->
            nil
        end
      end

      def send(message) do
        body = JSON.encode!(Map.put(message, "jsonrpc", "2.0"))
        IO.binwrite(:stdio, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
      end

      def await_responses(ids, acc, cancelled) do
        if ids == [] do
          {acc, cancelled}
        else
          case read() do
            %{"method" => "$/cancelRequest", "params" => %{"id" => id}} ->
              await_responses(ids, acc, [id | cancelled])

            %{"method" => "fake/editProbe", "id" => id, "params" => params} ->
              send(%{
                "id" => id,
                "result" => %{
                  "applyEditAcknowledged" => Map.has_key?(acc, "edit-1"),
                  "bytes" => File.read!(params["path"])
                }
              })

              await_responses(ids, acc, cancelled)

            message ->
              id = message["id"]

              if id in ids and not Map.has_key?(message, "method") do
                await_responses(
                  List.delete(ids, id),
                  Map.put(acc, id, message["result"]),
                  cancelled
                )
              else
                await_responses(ids, acc, cancelled)
              end
          end
        end
      end

      def loop(cancelled, last_command \\ nil) do
        case read() do
          nil ->
            :ok

          %{"method" => "initialize", "id" => id} ->
            Process.sleep(50)
            Process.put(:initializations, Process.get(:initializations, 0) + 1)
            send(%{"id" => id, "result" => %{"capabilities" => %{}}})
            loop(cancelled, last_command)

          %{"method" => "fake/pid", "id" => id} ->
            send(%{"id" => id, "result" => %{"pid" => System.pid(), "initializations" => Process.get(:initializations, 0)}})
            loop(cancelled, last_command)

          %{"method" => "fake/events", "id" => id} ->
            send(%{"id" => id, "result" => Enum.reverse(Process.get(:events, []))})
            loop(cancelled, last_command)

          %{"method" => "fake/crash"} ->
            System.halt(7)

          %{"method" => "workspace/executeCommand", "id" => id, "params" => params} ->
            send(%{
              "id" => id,
              "method" => "workspace/configuration",
              "params" => %{"items" => [%{}, %{}]}
            })

            send(%{
              "id" => "edit-1",
              "method" => "workspace/applyEdit",
              "params" => %{
                "edit" => %{
                  "changes" => %{
                    ("file://" <> URI.encode(params["path"])) => [
                      %{
                        "range" => %{
                          "start" => %{"line" => 0, "character" => 0},
                          "end" => %{"line" => 1, "character" => 0}
                        },
                        "newText" => params["text"]
                      }
                    ]
                  }
                }
              }
            })

            {results, cancelled} = await_responses([id, "edit-1"], %{}, cancelled)

            result = %{
              "commandId" => id,
              "configuration" => results[id],
              "applyEdit" => results["edit-1"],
              "bytesAfterAck" => File.read!(params["path"])
            }

            send(%{"id" => id, "result" => result})
            loop(cancelled, result)

          %{"method" => "fake/editProbe", "id" => id, "params" => params} ->
            send(%{
              "id" => id,
              "result" => %{
                "applyEditAcknowledged" => last_command != nil,
                "bytes" => File.read!(params["path"])
              }
            })

            loop(cancelled, last_command)

          %{"method" => "fake/editStatus", "id" => id} ->
            send(%{"id" => id, "result" => Map.put(last_command, "cancelled", cancelled)})
            loop(cancelled, last_command)

          %{"method" => method, "params" => params}
              when method in ["textDocument/didOpen", "textDocument/didChange", "textDocument/didClose"] ->
            Process.put(:events, [%{"method" => method, "params" => params} | Process.get(:events, [])])
            if method != "textDocument/didClose" do
            send(%{
              "method" => "textDocument/publishDiagnostics",
              "params" => %{
                "uri" => params["textDocument"]["uri"],
                "version" => params["textDocument"]["version"],
                "diagnostics" => [%{"severity" => 1, "message" => "private diagnostic text"}]
              }
            })
            end

            loop(cancelled, last_command)

          %{"method" => "$/cancelRequest", "params" => %{"id" => cancelled_id}} ->
            loop([cancelled_id | cancelled], last_command)

          %{"method" => "fake/cancelled", "id" => id} ->
            send(%{"id" => id, "result" => cancelled})
            loop(cancelled, last_command)

          _other ->
            loop(cancelled, last_command)
        end
      end
    end

    Fake.loop([])
    """
  end
end
