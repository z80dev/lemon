defmodule LemonControlPlane.Methods.ReadFailClosedTest do
  @moduledoc """
  Read handlers report an unreadable store as unavailable, never as empty,
  idle, disabled or not-found state.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.A2A.Handler, as: A2AHandler
  alias LemonControlPlane.ACP

  alias LemonControlPlane.Methods.{
    AgentWait,
    ChatHistory,
    ConfigGet,
    CronRuns,
    CronStatus,
    ExecApprovalsGet,
    LogsTail,
    SessionDetail,
    SessionsPreview,
    TasksActiveList,
    TasksRecentList
  }

  alias LemonCore.{RunHistoryStore, Store}
  alias LemonCore.Store.EtsBackend

  @ctx %{auth: %{role: :operator, scopes: [:read, :content, :admin, :approvals]}}

  defmodule FailingBackend do
    @moduledoc false
    @behaviour LemonCore.Store.Backend

    @impl true
    defdelegate init(opts), to: EtsBackend
    @impl true
    defdelegate put(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate delete(state, table, key), to: EtsBackend

    @impl true
    def get(_state, _table, _key), do: {:error, {:backend_failure, "api_key=private-backend"}}

    @impl true
    def list(_state, _table), do: {:error, {:backend_failure, "api_key=private-backend"}}
  end

  defmodule UnavailableLogRing do
    @moduledoc false
    def get_logs(_limit, _level), do: {:error, :unavailable}
  end

  defmodule ExitingTaskRuntime do
    @moduledoc false
    def list_tasks, do: exit({:timeout, {GenServer, :call, [:task_store]}})
    def get_task(_task_id), do: exit({:timeout, {GenServer, :call, [:task_store]}})
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    original = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      {:ok, backend_state} = EtsBackend.init([])
      %{state | backend: FailingBackend, backend_state: backend_state}
    end)

    on_exit(fn ->
      :sys.replace_state(Store, fn current ->
        Enum.each(current.backend_state, fn {_key, table} -> :ets.delete(table) end)
        original
      end)
    end)

    :ok
  end

  # Each row names a handler, how its dependency is made unreadable, and the
  # call. Every row must answer with an explicit unavailable error.
  @rows [
    {"agent.wait", :store, &__MODULE__.agent_wait/0},
    {"exec.approvals.get", :store, &__MODULE__.exec_approvals/0},
    {"config.get (all)", :store, &__MODULE__.config_all/0},
    {"config.get (key)", :store, &__MODULE__.config_key/0},
    {"cron.runs", :store, &__MODULE__.cron_runs/0},
    {"sessions.preview", :run_history, &__MODULE__.sessions_preview/0},
    {"chat.history", :run_history, &__MODULE__.chat_history/0},
    {"session.detail", :run_history, &__MODULE__.session_detail/0},
    {"session.detail (directory)", :store, &__MODULE__.session_detail/0},
    {"logs.tail", :log_ring, &__MODULE__.logs_tail/0},
    {"tasks.active.list", :task_runtime, &__MODULE__.tasks_active/0},
    {"tasks.recent.list", :task_runtime, &__MODULE__.tasks_recent/0}
  ]

  for {label, fault, call} <- @rows do
    test "#{label} reports unavailable when its #{fault} cannot be read" do
      with_fault(unquote(fault), fn ->
        assert {:error, error} = unquote(call).()
        assert {:unavailable, message} = {elem(error, 0), elem(error, 1)}
        assert is_binary(message)
        refute inspect(error) =~ "private-backend"
      end)
    end
  end

  test "cron.status reports unknown counts and names unreadable sections" do
    assert {:ok, status} = CronStatus.handle(%{}, @ctx)

    assert status["enabled"] == true
    assert status["unavailable"] == ["runs", "audit"]

    for key <- ~w(activeRunCount recentRunCount failedRunCount suppressedSlotCount) do
      assert is_nil(status[key]), "#{key} must be unknown, not zero"
      assert is_nil(status["summary"][key])
    end
  end

  test "cron.status reports enabled: nil when the job list cannot be read" do
    with_unregistered(LemonAutomation.CronManager, fn ->
      assert {:ok, status} = CronStatus.handle(%{}, @ctx)

      assert is_nil(status["enabled"])
      assert is_nil(status["summary"]["enabled"])
      assert is_nil(status["jobCount"])
      assert "jobs" in status["unavailable"]
    end)
  end

  test "ACP session listing and lookup fail closed instead of listing nothing" do
    assert {:error, -32_603, "session store unavailable"} = ACP.list_sessions(%{}, [])

    assert {:error, -32_603, "session store unavailable"} =
             ACP.close_session(%{"sessionId" => "acp-session-unreadable"})
  end

  test "A2A task reads fail closed instead of reporting an unknown task" do
    assert {:error, -32_603, message} = A2AHandler.handle("GetTask", %{"id" => "t1"}, "hermes")
    assert message =~ "unavailable"
    assert {:error, -32_603, _} = A2AHandler.handle("ListTasks", %{}, "hermes")
  end

  def agent_wait,
    do: AgentWait.handle(%{"runId" => "run-unreadable", "timeoutMs" => 2_000}, @ctx)

  def exec_approvals, do: ExecApprovalsGet.handle(%{}, @ctx)
  def config_all, do: ConfigGet.handle(%{}, @ctx)
  def config_key, do: ConfigGet.handle(%{"key" => "logLevel"}, @ctx)
  def cron_runs, do: CronRuns.handle(%{"id" => "cron-job-unreadable"}, @ctx)
  def sessions_preview, do: SessionsPreview.handle(%{"sessionKey" => session_key()}, @ctx)
  def chat_history, do: ChatHistory.handle(%{"sessionKey" => session_key()}, @ctx)
  def session_detail, do: SessionDetail.handle(%{"sessionKey" => session_key()}, @ctx)
  def logs_tail, do: LogsTail.handle(%{}, @ctx)
  def tasks_active, do: TasksActiveList.handle(%{}, @ctx)
  def tasks_recent, do: TasksRecentList.handle(%{}, @ctx)

  defp session_key, do: "agent:fail-closed:#{System.unique_integer([:positive])}"

  # Store faults are installed by `setup`; RunHistoryStore is its own SQLite
  # owner, so it is detached from its name while the read runs.
  defp with_fault(:store, fun), do: fun.()

  defp with_fault(:run_history, fun) do
    restore_store()
    with_unregistered(RunHistoryStore, fun)
  end

  defp with_fault(:log_ring, fun) do
    with_env(:lemon_control_plane, :log_ring_module, UnavailableLogRing, fun)
  end

  defp with_fault(:task_runtime, fun) do
    with_env(:lemon_core, :agent_runtime_provider, ExitingTaskRuntime, fun)
  end

  defp restore_store do
    :sys.replace_state(Store, fn state ->
      %{state | backend: EtsBackend}
    end)
  end

  defp with_unregistered(name, fun) do
    pid = Process.whereis(name)
    assert is_pid(pid)
    Process.unregister(name)

    try do
      fun.()
    after
      Process.register(pid, name)
    end
  end

  defp with_env(app, key, value, fun) do
    original = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    try do
      fun.()
    after
      case original do
        {:ok, previous} -> Application.put_env(app, key, previous)
        :error -> Application.delete_env(app, key)
      end
    end
  end
end
