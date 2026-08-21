defmodule LemonGateway.RunRedirectTest do
  @moduledoc """
  Tests redirect handling in `LemonGateway.Run` through its configured executor.

  Redirect is forwarded to `executor.redirect/2`. Only
  `{:error, :unsupported}` degrades to `executor.steer/2`; every other
  redirect failure remains rejected.
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Run
  alias LemonGateway.ExecutionRequest
  alias LemonCore.ResumeToken
  alias LemonGateway.Event

  # ============================================================================
  # Configured executor fixture
  # ============================================================================

  defmodule RunRedirectFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      scenario = (request.meta || %{})[:scenario]
      meta = request.meta || %{}
      resume = request.resume || %ResumeToken{engine: "lemon", value: unique_id()}

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          if controller_pid = Map.get(meta, :controller_pid) do
            send(controller_pid, {:executor_started, run_ref, request})
          end

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: "lemon", resume: resume, ok: true, answer: answer})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: "lemon", resume: resume, ok: false, error: :timeout})}
              )
          end
        end)

      {:ok, run_ref,
       %{
         task_pid: task_pid,
         scenario: scenario,
         notify_pid: Map.get(meta, :capability_notify_pid)
       }}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_ctx), do: :ok

    @impl true
    def steer(%{scenario: scenario, notify_pid: notify_pid}, text)
        when scenario in ["redirectable_test", "steer_only_test", "redirect_fails_test"] and
               is_pid(notify_pid) do
      send(notify_pid, {:executor_steered, text})
      :ok
    end

    def steer(_ctx, _text), do: {:error, :unsupported}

    @impl true
    def redirect(%{scenario: "redirectable_test", notify_pid: notify_pid}, text)
        when is_pid(notify_pid) do
      send(notify_pid, {:executor_redirected, text})
      :ok
    end

    # The Run contract, rather than executor capability introspection, decides
    # to fall back to steer for this explicit result only.
    def redirect(%{scenario: "redirect_fails_test"}, _text), do: {:error, :transport_failed}
    def redirect(_ctx, _text), do: {:error, :unsupported}

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :executor, RunRedirectFixtureExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    "test:#{chat_id}"
  end

  defp make_request(session_key, opts) do
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)

    meta =
      %{notify_pid: self(), user_msg_id: user_msg_id}
      |> Map.merge(Keyword.get(opts, :meta, %{}))
      |> Map.put(:scenario, Keyword.fetch!(opts, :scenario))

    %ExecutionRequest{
      run_id: Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}"),
      session_key: session_key,
      prompt: Keyword.get(opts, :prompt, Keyword.get(opts, :text, "test message")),
      conversation_key: {:session, session_key},
      resume: Keyword.get(opts, :resume),
      meta: meta
    }
  end

  defp start_run_direct(request, slot_ref \\ make_ref()) do
    args = %{
      execution_request: request,
      slot_ref: slot_ref,
      worker_pid: self()
    }

    Run.start_link(args)
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "redirect behavior" do
    test "forwards redirect to the configured executor" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "redirectable_test",
          meta: %{controller_pid: self(), capability_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref,
                      %ExecutionRequest{meta: %{scenario: "redirectable_test"}}},
                     2000

      submission_run_id = "redirect-submission-#{System.unique_integer([:positive])}"
      GenServer.cast(pid, {:redirect, submission_run_id, "new direction", self()})

      assert_receive {:executor_redirected, "new direction"}, 2000
      assert_receive {:redirect_accepted, ^submission_run_id}, 2000

      # A successful redirect must not also steer.
      refute_receive {:executor_steered, _}, 100
    end

    test "falls back to steer only when redirect returns unsupported" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "steer_only_test",
          meta: %{controller_pid: self(), capability_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref,
                      %ExecutionRequest{meta: %{scenario: "steer_only_test"}}},
                     2000

      submission_run_id = "redirect-submission-#{System.unique_integer([:positive])}"
      GenServer.cast(pid, {:redirect, submission_run_id, "degraded correction", self()})

      assert_receive {:executor_steered, "degraded correction"}, 2000
      assert_receive {:redirect_accepted, ^submission_run_id}, 2000
    end

    test "does not fall back to steer for other redirect errors" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "redirect_fails_test",
          meta: %{controller_pid: self(), capability_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref,
                      %ExecutionRequest{meta: %{scenario: "redirect_fails_test"}}},
                     2000

      submission_run_id = "redirect-submission-#{System.unique_integer([:positive])}"
      GenServer.cast(pid, {:redirect, submission_run_id, "do not steer", self()})

      assert_receive {:redirect_rejected, ^submission_run_id}, 2000
      refute_receive {:executor_steered, _}, 100
    end

    test "acknowledges redirects with the supplied submission run ID" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "redirectable_test",
          meta: %{controller_pid: self(), capability_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref,
                      %ExecutionRequest{meta: %{scenario: "redirectable_test"}}},
                     2000

      submission_run_id = "stable-submission-run-id"
      GenServer.cast(pid, {:redirect, submission_run_id, "new direction", self()})

      assert_receive {:executor_redirected, "new direction"}, 2000
      assert_receive {:redirect_accepted, ^submission_run_id}, 2000
      refute_receive {:executor_steered, _}, 100
    end

    test "rejects unsupported redirects with the supplied submission run ID" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "no_capability_test",
          meta: %{controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref,
                      %ExecutionRequest{meta: %{scenario: "no_capability_test"}}},
                     2000

      submission_run_id = "unsupported-submission-run-id"
      GenServer.cast(pid, {:redirect, submission_run_id, "unsupported", self()})

      assert_receive {:redirect_rejected, ^submission_run_id}, 2000
    end

    test "rejects redirect when the executor does not support either control" do
      scope = make_scope()

      request =
        make_request(scope,
          scenario: "no_capability_test",
          meta: %{controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref,
                      %ExecutionRequest{meta: %{scenario: "no_capability_test"}}},
                     2000

      submission_run_id = "rejected-submission-run-id"
      GenServer.cast(pid, {:redirect, submission_run_id, "unsupported", self()})

      assert_receive {:redirect_rejected, ^submission_run_id}, 2000
    end
  end
end
