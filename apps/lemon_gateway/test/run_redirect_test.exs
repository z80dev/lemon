defmodule LemonGateway.RunRedirectTest do
  @moduledoc """
  Tests for redirect handling in LemonGateway.Run.

  Redirect is an optional engine capability (`supports_redirect?/0`,
  defaulting to false for engines that do not export it). A redirect cast is
  forwarded to `engine.redirect/2` when supported, degrades to a steer when
  the engine only supports steering, and is rejected otherwise.
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Run
  alias LemonGateway.ExecutionRequest
  alias LemonGateway.Types.Job
  alias LemonCore.ResumeToken
  alias LemonGateway.Event

  # ============================================================================
  # Test Engines
  # ============================================================================

  defmodule RedirectableEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias LemonGateway.Event

    @impl true
    def id, do: "redirectable_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "redirectable_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: true

    @impl true
    def supports_redirect?, do: true

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      notify_pid = (job.meta || %{})[:capability_notify_pid]
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: :timeout})}
              )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid, notify_pid: notify_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_ctx), do: :ok

    @impl true
    def steer(%{notify_pid: notify_pid}, text) when is_pid(notify_pid) do
      send(notify_pid, {:engine_steered, text})
      :ok
    end

    def steer(_ctx, _text), do: :ok

    @impl true
    def redirect(%{notify_pid: notify_pid}, text) when is_pid(notify_pid) do
      send(notify_pid, {:engine_redirected, text})
      :ok
    end

    def redirect(_ctx, _text), do: :ok

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # Supports steering but does not export supports_redirect?/0: a redirect
  # must degrade to a steer.
  defmodule SteerOnlyEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias LemonGateway.Event

    @impl true
    def id, do: "steer_only_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "steer_only_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: true

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      notify_pid = (job.meta || %{})[:capability_notify_pid]
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: :timeout})}
              )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid, notify_pid: notify_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_ctx), do: :ok

    @impl true
    def steer(%{notify_pid: notify_pid}, text) when is_pid(notify_pid) do
      send(notify_pid, {:engine_steered, text})
      :ok
    end

    def steer(_ctx, _text), do: :ok

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # Supports neither steering nor redirect.
  defmodule NoCapabilityEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias LemonGateway.Event

    @impl true
    def id, do: "no_capability_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "no_capability_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: true, answer: answer})}
              )
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: id(), resume: resume, ok: false, error: :timeout})}
              )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_ctx), do: :ok

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "redirectable_test",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      RedirectableEngine,
      SteerOnlyEngine,
      NoCapabilityEngine,
      LemonGateway.Engines.Echo
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    "test:#{chat_id}"
  end

  defp make_job(session_key, opts) do
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)
    base_meta = %{notify_pid: self(), user_msg_id: user_msg_id}
    meta_opt = Keyword.get(opts, :meta, %{})

    meta =
      cond do
        is_nil(meta_opt) -> nil
        is_map(meta_opt) -> Map.merge(base_meta, meta_opt)
        true -> meta_opt
      end

    %Job{
      session_key: session_key,
      prompt: Keyword.get(opts, :prompt, Keyword.get(opts, :text, "test message")),
      engine_id: Keyword.fetch!(opts, :engine_id),
      resume: Keyword.get(opts, :resume),
      meta: meta
    }
  end

  defp make_request(session_key, opts) do
    job = make_job(session_key, opts)
    ExecutionRequest.from_job(job, conversation_key: test_conversation_key(job))
  end

  defp test_conversation_key(%Job{session_key: session_key}) when is_binary(session_key),
    do: {:session, session_key}

  defp start_run_direct(job, slot_ref \\ make_ref()) do
    args = %{
      execution_request:
        ExecutionRequest.from_job(job, conversation_key: test_conversation_key(job)),
      slot_ref: slot_ref,
      worker_pid: self()
    }

    Run.start_link(args)
  end

  # ============================================================================
  # Tests
  # ============================================================================

  describe "redirect behavior" do
    test "forwards redirect to an engine that supports it" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_id: "redirectable_test",
          meta: %{controller_pid: self(), capability_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      request = make_request(scope, engine_id: "redirectable_test", text: "new direction")
      GenServer.cast(pid, {:redirect, request, self()})

      assert_receive {:engine_redirected, "new direction"}, 2000
      assert_receive {:redirect_accepted, ^request}, 2000

      # It must NOT have been degraded to a steer
      refute_receive {:engine_steered, _}, 100
    end

    test "degrades to steer when the engine only supports steering" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_id: "steer_only_test",
          meta: %{controller_pid: self(), capability_notify_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      request = make_request(scope, engine_id: "steer_only_test", text: "degraded correction")
      GenServer.cast(pid, {:redirect, request, self()})

      assert_receive {:engine_steered, "degraded correction"}, 2000
      assert_receive {:redirect_accepted, ^request}, 2000
    end

    test "rejects redirect when the engine supports neither redirect nor steer" do
      scope = make_scope()

      job =
        make_job(scope,
          engine_id: "no_capability_test",
          meta: %{controller_pid: self()}
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref}, 2000

      request = make_request(scope, engine_id: "no_capability_test", text: "unsupported")
      GenServer.cast(pid, {:redirect, request, self()})

      assert_receive {:redirect_rejected, ^request}, 2000
    end
  end
end
