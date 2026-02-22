defmodule LemonCore.ConfigReloader.WatcherTest do
  @moduledoc """
  Tests for the ConfigReloader.Watcher GenServer.
  """
  use ExUnit.Case, async: false

  alias LemonCore.ConfigReloader.Watcher

  @short_debounce_ms 50
  @short_poll_ms 5_000

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "watcher_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    global_lemon_dir = Path.join(mock_home, ".lemon")
    File.mkdir_p!(global_lemon_dir)

    project_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(project_dir)

    project_lemon_dir = Path.join(project_dir, ".lemon")
    File.mkdir_p!(project_lemon_dir)

    original_home = System.get_env("HOME")
    System.put_env("HOME", mock_home)

    original_dotenv_dir = System.get_env("LEMON_DOTENV_DIR")
    System.delete_env("LEMON_DOTENV_DIR")

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      if original_dotenv_dir do
        System.put_env("LEMON_DOTENV_DIR", original_dotenv_dir)
      else
        System.delete_env("LEMON_DOTENV_DIR")
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok,
     tmp_dir: tmp_dir,
     mock_home: mock_home,
     global_lemon_dir: global_lemon_dir,
     project_dir: project_dir,
     project_lemon_dir: project_lemon_dir}
  end

  # Helper: start watcher without global name registration, with short timers
  defp start_watcher!(opts \\ []) do
    opts = Keyword.put_new(opts, :debounce_ms, @short_debounce_ms)
    opts = Keyword.put_new(opts, :poll_interval_ms, @short_poll_ms)

    {:ok, pid} = GenServer.start_link(Watcher, opts)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  # ---------------------------------------------------------------------------
  # start_link/1
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    test "starts the GenServer and process is alive" do
      pid = start_watcher!()
      assert Process.alive?(pid)
    end

    test "registers with module name via start_link/1" do
      # Ensure no existing registered process
      if pid = Process.whereis(Watcher), do: GenServer.stop(pid)

      {:ok, pid} =
        Watcher.start_link(debounce_ms: @short_debounce_ms, poll_interval_ms: @short_poll_ms)

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end)

      assert Process.whereis(Watcher) == pid
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # init/1
  # ---------------------------------------------------------------------------

  describe "init/1" do
    test "sets default debounce_ms (250)" do
      {:ok, pid} = GenServer.start_link(Watcher, [])
      state = :sys.get_state(pid)
      assert state.debounce_ms == 250
      GenServer.stop(pid)
    end

    test "sets default poll_interval_ms (5000)" do
      {:ok, pid} = GenServer.start_link(Watcher, [])
      state = :sys.get_state(pid)
      assert state.poll_interval_ms == 5_000
      GenServer.stop(pid)
    end

    test "accepts custom debounce_ms" do
      pid = start_watcher!(debounce_ms: 500)
      state = :sys.get_state(pid)
      assert state.debounce_ms == 500
    end

    test "accepts custom poll_interval_ms" do
      pid = start_watcher!(poll_interval_ms: 10_000)
      state = :sys.get_state(pid)
      assert state.poll_interval_ms == 10_000
    end

    test "stores cwd in state", %{project_dir: project_dir} do
      pid = start_watcher!(cwd: project_dir)
      state = :sys.get_state(pid)
      assert state.cwd == project_dir
    end

    test "cwd defaults to nil" do
      pid = start_watcher!()
      state = :sys.get_state(pid)
      assert state.cwd == nil
    end

    test "debounce_ref starts as nil" do
      pid = start_watcher!()
      state = :sys.get_state(pid)
      assert state.debounce_ref == nil
    end

    test "mode is :native or :polling depending on FileSystem availability" do
      pid = start_watcher!()
      state = :sys.get_state(pid)
      assert state.mode in [:native, :polling]
    end

    test "watcher_pid is set when native mode is active" do
      pid = start_watcher!()
      state = :sys.get_state(pid)

      if state.mode == :native do
        assert is_pid(state.watcher_pid)
        assert Process.alive?(state.watcher_pid)
      else
        assert state.watcher_pid == nil
      end
    end

    test "empty options start successfully" do
      {:ok, pid} = GenServer.start_link(Watcher, [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # watch_directories (tested indirectly through init behavior)
  # ---------------------------------------------------------------------------

  describe "watch_directories" do
    test "starts successfully with existing global ~/.lemon directory", %{
      global_lemon_dir: global_lemon_dir
    } do
      assert File.dir?(global_lemon_dir)
      pid = start_watcher!()
      assert Process.alive?(pid)
    end

    test "starts with cwd pointing to project directory", %{project_dir: project_dir} do
      pid = start_watcher!(cwd: project_dir)
      state = :sys.get_state(pid)
      assert state.cwd == project_dir
      assert Process.alive?(pid)
    end

    test "handles cwd pointing to non-existent directory" do
      nonexistent = "/tmp/nonexistent_#{System.unique_integer([:positive])}"
      pid = start_watcher!(cwd: nonexistent)
      assert Process.alive?(pid)
    end

    test "respects LEMON_DOTENV_DIR environment variable", %{tmp_dir: tmp_dir} do
      dotenv_dir = Path.join(tmp_dir, "custom_dotenv")
      File.mkdir_p!(dotenv_dir)
      System.put_env("LEMON_DOTENV_DIR", dotenv_dir)

      pid = start_watcher!()
      assert Process.alive?(pid)

      System.delete_env("LEMON_DOTENV_DIR")
    end

    test "nil cwd does not crash" do
      pid = start_watcher!(cwd: nil)
      state = :sys.get_state(pid)
      assert state.cwd == nil
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info - file events
  # ---------------------------------------------------------------------------

  describe "handle_info - file events" do
    test "file event sets debounce_ref in state" do
      pid = start_watcher!(debounce_ms: 500)
      state_before = :sys.get_state(pid)
      assert state_before.debounce_ref == nil

      send(pid, {:file_event, self(), {"/some/path/config.toml", [:modified]}})
      Process.sleep(10)

      state_after = :sys.get_state(pid)
      assert state_after.debounce_ref != nil
    end

    test "second file event cancels first debounce timer" do
      pid = start_watcher!(debounce_ms: 500)

      send(pid, {:file_event, self(), {"/some/path/config.toml", [:modified]}})
      Process.sleep(10)
      state1 = :sys.get_state(pid)
      ref1 = state1.debounce_ref

      send(pid, {:file_event, self(), {"/some/path/config.toml", [:modified]}})
      Process.sleep(10)
      state2 = :sys.get_state(pid)
      ref2 = state2.debounce_ref

      # New timer reference should differ from the first
      assert ref1 != ref2
    end

    test "debounced_reload fires after debounce_ms elapses" do
      pid = start_watcher!(debounce_ms: 30)

      send(pid, {:file_event, self(), {"/some/path/config.toml", [:modified]}})
      Process.sleep(10)
      state = :sys.get_state(pid)
      assert state.debounce_ref != nil

      # Wait for debounce to fire
      Process.sleep(50)
      state_after = :sys.get_state(pid)
      assert state_after.debounce_ref == nil
    end

    test "multiple rapid events coalesce via debounce" do
      pid = start_watcher!(debounce_ms: 100)

      # Send multiple events in rapid succession
      for _i <- 1..5 do
        send(pid, {:file_event, self(), {"/some/path/config.toml", [:modified]}})
        Process.sleep(5)
      end

      # The debounce_ref should be set (timer not yet fired)
      state = :sys.get_state(pid)
      assert state.debounce_ref != nil

      # Wait for debounce to fire
      Process.sleep(150)
      state_after = :sys.get_state(pid)
      assert state_after.debounce_ref == nil
    end

    test "file_event :stop sets mode to polling and clears watcher_pid" do
      pid = start_watcher!()

      send(pid, {:file_event, self(), :stop})
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.mode == :polling
      assert state.watcher_pid == nil
    end

    test "handles various file event types" do
      pid = start_watcher!(debounce_ms: 500)

      events = [[:created], [:modified], [:deleted], [:renamed], [:modified, :created]]

      for event <- events do
        send(pid, {:file_event, self(), {"/some/path", event}})
        Process.sleep(5)
      end

      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.debounce_ref != nil
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info - :debounced_reload
  # ---------------------------------------------------------------------------

  describe "handle_info - :debounced_reload" do
    test "clears debounce_ref in state" do
      pid = start_watcher!(debounce_ms: 5_000)

      # Set up a debounce_ref via file event
      send(pid, {:file_event, self(), {"/path/file", [:modified]}})
      Process.sleep(10)
      state = :sys.get_state(pid)
      assert state.debounce_ref != nil

      # Manually trigger debounced_reload
      send(pid, :debounced_reload)
      Process.sleep(10)

      state_after = :sys.get_state(pid)
      assert state_after.debounce_ref == nil
    end

    test "handles debounced_reload when no prior debounce_ref exists" do
      pid = start_watcher!()

      send(pid, :debounced_reload)
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.debounce_ref == nil
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info - :poll
  # ---------------------------------------------------------------------------

  describe "handle_info - :poll" do
    test "poll message does not crash the process" do
      pid = start_watcher!(poll_interval_ms: 60_000)

      send(pid, :poll)
      Process.sleep(10)

      assert Process.alive?(pid)
    end

    test "poll fires periodically at configured interval" do
      pid = start_watcher!(poll_interval_ms: 50, debounce_ms: 5_000)

      # Wait long enough for multiple polls
      Process.sleep(200)

      # Process should still be alive after multiple poll cycles
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # handle_info - unknown messages
  # ---------------------------------------------------------------------------

  describe "handle_info - unknown messages" do
    test "ignores unknown messages without changing state" do
      pid = start_watcher!(debounce_ms: 5_000, poll_interval_ms: 60_000)
      state_before = :sys.get_state(pid)

      send(pid, :some_random_message)
      Process.sleep(10)

      state_after = :sys.get_state(pid)
      assert state_after.cwd == state_before.cwd
      assert state_after.debounce_ms == state_before.debounce_ms
      assert state_after.poll_interval_ms == state_before.poll_interval_ms
      assert state_after.mode == state_before.mode
    end

    test "does not crash on unexpected message types" do
      pid = start_watcher!()

      send(pid, {:unexpected, :tuple})
      send(pid, %{unexpected: "map"})
      send(pid, 42)
      Process.sleep(10)

      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # terminate/2
  # ---------------------------------------------------------------------------

  describe "terminate/2" do
    test "handles nil watcher_pid gracefully" do
      pid = start_watcher!()

      # Force watcher_pid to nil via :stop event
      send(pid, {:file_event, self(), :stop})
      Process.sleep(10)

      state = :sys.get_state(pid)
      assert state.watcher_pid == nil

      # Stopping should not crash
      GenServer.stop(pid, :normal, 1_000)
      refute Process.alive?(pid)
    end

    test "stops watcher_pid on terminate when in native mode" do
      pid = start_watcher!()
      state = :sys.get_state(pid)

      if state.mode == :native do
        watcher_pid = state.watcher_pid
        assert Process.alive?(watcher_pid)

        GenServer.stop(pid, :normal, 1_000)
        Process.sleep(50)

        refute Process.alive?(watcher_pid)
      end
    end

    test "handles already-dead watcher_pid on terminate" do
      pid = start_watcher!()
      state = :sys.get_state(pid)

      if state.mode == :native and is_pid(state.watcher_pid) do
        # Stop the file system watcher normally (normal exit doesn't crash linked procs)
        GenServer.stop(state.watcher_pid, :normal, 1_000)
        Process.sleep(50)

        # The main GenServer should handle terminate with dead watcher_pid
        # It may still be alive or may have received an exit signal
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 1_000)
          refute Process.alive?(pid)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "edge cases" do
    test "survives rapid start/stop cycles" do
      for _i <- 1..5 do
        {:ok, pid} =
          GenServer.start_link(Watcher,
            debounce_ms: @short_debounce_ms,
            poll_interval_ms: @short_poll_ms
          )

        assert Process.alive?(pid)
        GenServer.stop(pid, :normal, 1_000)
      end
    end

    test "empty string cwd does not add project directory" do
      pid = start_watcher!(cwd: "")
      state = :sys.get_state(pid)
      assert state.cwd == ""
      assert Process.alive?(pid)
    end
  end
end
