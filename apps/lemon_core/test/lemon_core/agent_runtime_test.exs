defmodule LemonCore.AgentRuntimeTest do
  # Mutates the provider registration, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.AgentRuntime

  defmodule TaskProvider do
    def list_tasks, do: [{"task-1", %{status: :running}}]
    def get_task("task-1"), do: {:ok, %{status: :running}, []}
    def get_task(_), do: {:error, :not_found}
  end

  defmodule FailingProvider do
    def list_tasks, do: raise("private provider failure")
    def get_task(_id), do: exit({:timeout, {GenServer, :call, [:task_store]}})
    def session_history(_key, _cwd), do: throw(:private_throw)

    def background_start(_prompt, opts) do
      {:ok, run} = Agent.start_link(fn -> :running end)
      send(Keyword.fetch!(opts, :owner), {:background_started, run})
      raise "private failure after start"
    end

    def session_create(_key, _cwd), do: exit(:killed)
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :agent_runtime_provider)
      else
        Application.put_env(:lemon_core, :agent_runtime_provider, original)
      end
    end)

    :ok
  end

  defp use_provider(module),
    do: Application.put_env(:lemon_core, :agent_runtime_provider, module)

  defp no_provider, do: Application.delete_env(:lemon_core, :agent_runtime_provider)

  describe "registration" do
    test "register/1 refuses a module that cannot be loaded" do
      no_provider()

      assert AgentRuntime.register(Definitely.Not.Loaded) == {:error, :not_a_provider}
      refute AgentRuntime.available?()
    end

    test "register/1 refuses a provider missing required callbacks" do
      no_provider()

      assert AgentRuntime.register(TaskProvider) == {:error, :not_a_provider}
      assert is_nil(AgentRuntime.provider())
    end

    test "the compiler diagnoses a provider missing required callbacks" do
      source = """
      defmodule LemonCore.AgentRuntimeTest.IncompleteProvider do
        @behaviour LemonCore.AgentRuntime.Provider
        def list_tasks, do: []
      end
      """

      {_, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(source) end)

      assert Enum.any?(diagnostics, fn diagnostic ->
               diagnostic.severity == :warning and
                 diagnostic.message =~ "required by behaviour LemonCore.AgentRuntime.Provider" and
                 diagnostic.message =~ "get_task/1"
             end)
    end
  end

  describe "query/3" do
    test "returns the callback value when the provider answers" do
      use_provider(TaskProvider)

      assert AgentRuntime.query(:list_tasks, []) == [{"task-1", %{status: :running}}]
      assert AgentRuntime.query(:get_task, ["task-1"]) == {:ok, %{status: :running}, []}
      assert AgentRuntime.query(:get_task, ["other"]) == {:error, :not_found}
    end

    test "no provider or callback is an error, never an empty result" do
      no_provider()
      assert AgentRuntime.query(:list_tasks, []) == {:error, :unavailable}

      use_provider(TaskProvider)
      assert AgentRuntime.query(:session_history, ["key", "/tmp"]) == {:error, :unavailable}
    end

    test "a provider exit on a query returns an error, never [] or nil" do
      use_provider(FailingProvider)

      log =
        capture_log(fn ->
          assert AgentRuntime.query(:get_task, ["task-1"]) == {:error, :unavailable}
        end)

      assert log =~ "failure_class=timeout"
    end

    test "a raising query returns its documented fallback and logs nothing at error level" do
      use_provider(FailingProvider)

      error_log =
        capture_log([level: :error], fn ->
          assert AgentRuntime.query(:list_tasks, [], {:error, :tasks_unavailable}) ==
                   {:error, :tasks_unavailable}

          assert AgentRuntime.query(:session_history, ["key", "/tmp"]) == {:error, :unavailable}
        end)

      assert error_log == ""

      warning_log = capture_log(fn -> AgentRuntime.query(:list_tasks, []) end)

      assert warning_log =~ "AgentRuntime query callback failed"
      refute warning_log =~ "private"
    end
  end

  describe "mutate/2" do
    test "a provider that raises after starting a background run is outcome_unknown, logged once" do
      use_provider(FailingProvider)

      log =
        capture_log(fn ->
          assert AgentRuntime.mutate(:background_start, ["prompt", [owner: self()]]) ==
                   {:error, :outcome_unknown}
        end)

      assert_received {:background_started, run}
      assert Agent.get(run, & &1) == :running
      Agent.stop(run)
      refute_received {:background_started, _}

      assert [line] =
               log |> String.split("\n") |> Enum.filter(&(&1 =~ "callback failed"))

      assert line =~ "[error]"
      assert line =~ "AgentRuntime mutation"
      assert line =~ "failure_class=exception"
      refute log =~ "private"
    end

    test "an exit after the call was reached is outcome_unknown" do
      use_provider(FailingProvider)

      capture_log(fn ->
        assert AgentRuntime.mutate(:session_create, ["agent:a:main", "/tmp"]) ==
                 {:error, :outcome_unknown}
      end)
    end

    test "a mutation never reached is a clean unavailable rejection" do
      no_provider()
      assert AgentRuntime.mutate(:background_start, ["prompt", []]) == {:error, :unavailable}

      use_provider(TaskProvider)

      assert AgentRuntime.mutate(:session_create, ["agent:a:main", "/tmp"]) ==
               {:error, :unavailable}
    end
  end
end
