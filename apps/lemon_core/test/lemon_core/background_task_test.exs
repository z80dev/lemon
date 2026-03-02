defmodule LemonCore.BackgroundTaskTest do
  use ExUnit.Case, async: true

  alias LemonCore.BackgroundTask

  describe "start/2 with a running supervisor" do
    test "starts task under the default supervisor" do
      test_pid = self()
      ref = make_ref()

      assert {:ok, pid} =
               BackgroundTask.start(fn ->
                 send(test_pid, {:task_ran, ref})
               end)

      assert is_pid(pid)
      assert_receive {:task_ran, ^ref}, 1_000
    end

    test "starts task under a custom supervisor" do
      {:ok, sup} = Task.Supervisor.start_link()
      test_pid = self()
      ref = make_ref()

      assert {:ok, pid} =
               BackgroundTask.start(
                 fn -> send(test_pid, {:custom_sup, ref}) end,
                 supervisor: sup
               )

      assert is_pid(pid)
      assert_receive {:custom_sup, ^ref}, 1_000
    end
  end

  describe "start/2 when supervisor is not available" do
    test "returns error by default (allow_unsupervised: false)" do
      assert {:error, {:supervisor_not_available, :nonexistent_supervisor}} =
               BackgroundTask.start(
                 fn -> :should_not_run end,
                 supervisor: :nonexistent_supervisor
               )
    end

    test "falls back to unsupervised Task.start when allow_unsupervised: true" do
      test_pid = self()
      ref = make_ref()

      assert {:ok, pid} =
               BackgroundTask.start(
                 fn -> send(test_pid, {:unsupervised, ref}) end,
                 supervisor: :nonexistent_supervisor,
                 allow_unsupervised: true
               )

      assert is_pid(pid)
      assert_receive {:unsupervised, ^ref}, 1_000
    end
  end

  describe "function execution" do
    test "the function body is actually executed" do
      test_pid = self()
      marker = System.unique_integer([:positive, :monotonic])

      {:ok, _pid} =
        BackgroundTask.start(fn ->
          send(test_pid, {:marker, marker})
        end)

      assert_receive {:marker, ^marker}, 1_000
    end

    test "exceptions in the function do not crash the caller" do
      test_pid = self()

      {:ok, pid} =
        BackgroundTask.start(fn ->
          send(test_pid, :before_raise)
          raise "boom"
        end)

      assert_receive :before_raise, 1_000

      # The task process should exit, but the caller stays alive
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
      assert Process.alive?(self())
    end
  end

  describe "error handling" do
    test "supervisor rejection with allow_unsupervised: false returns error" do
      # Start a supervisor then stop it to simulate a stopped supervisor
      {:ok, sup} = Task.Supervisor.start_link()
      GenServer.stop(sup)

      # Small sleep to ensure the process is fully stopped
      Process.sleep(10)

      assert {:error, {:supervisor_not_available, ^sup}} =
               BackgroundTask.start(
                 fn -> :noop end,
                 supervisor: sup
               )
    end

    test "supervisor rejection with allow_unsupervised: true falls back" do
      {:ok, sup} = Task.Supervisor.start_link()
      GenServer.stop(sup)

      Process.sleep(10)

      test_pid = self()
      ref = make_ref()

      assert {:ok, _pid} =
               BackgroundTask.start(
                 fn -> send(test_pid, {:fallback, ref}) end,
                 supervisor: sup,
                 allow_unsupervised: true
               )

      assert_receive {:fallback, ^ref}, 1_000
    end
  end

  describe "opts" do
    test "defaults to LemonCore.BackgroundTaskSupervisor" do
      test_pid = self()
      ref = make_ref()

      # The default supervisor is started by LemonCore.Application
      assert {:ok, _pid} =
               BackgroundTask.start(fn ->
                 send(test_pid, {:default_sup, ref})
               end)

      assert_receive {:default_sup, ^ref}, 1_000
    end

    test "allow_unsupervised defaults to false" do
      assert {:error, {:supervisor_not_available, _}} =
               BackgroundTask.start(
                 fn -> :noop end,
                 supervisor: :does_not_exist
               )
    end
  end
end
