defmodule LemonControlPlane.Methods.SessionsResetPreviewTest do
  @moduledoc """
  Regression tests for issues #615 and #652:
  - `sessions.reset` is preview-first (`dryRun: true` / absent `confirmToken` mutates nothing)
  - Confirmation binds to a server-side single-use token and current session digest
  - Mid-reset store failures return `retrySafe: false` with no raw exception text and keep the session readable
  - ACP session metadata lives in `SessionMetadataStore` (no shadow ACP table),
    is removed by `SessionLifecycle.delete/2`, never resurrects `ChatState` after `sessions.reset`,
    and handles post-submit store write failures without raising while returning `runId` + `retrySafe: false`.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.ACP
  alias LemonControlPlane.Methods.SessionsReset
  alias LemonControlPlane.Protocol.Schemas

  alias LemonCore.{
    ChatState,
    ChatStateStore,
    Event,
    ExecutionCommand,
    PolicyStore,
    RunHistoryStore,
    RunRequest,
    RunStore,
    SessionLifecycle,
    SessionMetadataStore,
    Store
  }

  alias LemonRouter.RunCompletion

  defmodule ControlledRuntime do
    @behaviour LemonCore.EngineRuntime
    def available?, do: true
    def run_pid(_), do: nil
    def cancel_by_run_id(_, _), do: :ok

    def submit_execution(command) do
      send(
        Application.fetch_env!(:lemon_router, :sessions_reset_preview_test_pid),
        {:execution, command}
      )

      :ok
    end
  end

  defmodule PolicyDeleteFailingBackend do
    alias LemonCore.Store.EtsBackend

    for {name, arity} <- EtsBackend.__info__(:functions), {name, arity} != {:delete, 3} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: EtsBackend.unquote(name)(unquote_splicing(args))
    end

    def delete(_state, :session_policies, _key), do: {:error, :simulated_disk_full}
    def delete(state, table, key), do: EtsBackend.delete(state, table, key)
  end

  defmodule MetadataPutFailingBackend do
    alias LemonCore.Store.EtsBackend

    for {name, arity} <- EtsBackend.__info__(:functions), {name, arity} != {:put, 4} do
      args = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(unquote_splicing(args)),
        do: EtsBackend.unquote(name)(unquote_splicing(args))
    end

    def put(_state, :session_metadata_v1, _key, _value) do
      {:error, :simulated_store_write_failure}
    end

    def put(state, table, key, value), do: EtsBackend.put(state, table, key, value)
  end

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    key = "agent:default:tui:local:main:reset-preview-#{suffix}"
    previous_runtime = Application.get_env(:lemon_router, :engine_runtime)
    previous_pid = Application.get_env(:lemon_router, :sessions_reset_preview_test_pid)
    previous_submitter = Application.get_env(:lemon_control_plane, :acp_submitter)

    Application.put_env(:lemon_router, :engine_runtime, ControlledRuntime)
    Application.put_env(:lemon_router, :sessions_reset_preview_test_pid, self())

    on_exit(fn ->
      LemonRouter.abort(key)
      restore_env(:lemon_router, :engine_runtime, previous_runtime)
      restore_env(:lemon_router, :sessions_reset_preview_test_pid, previous_pid)
      restore_env(:lemon_control_plane, :acp_submitter, previous_submitter)
      RunStore.delete_session(key)
      ChatStateStore.delete(key)
      PolicyStore.delete_session(key)
      SessionMetadataStore.delete(key)
    end)

    %{key: key}
  end

  test "sessions.reset schema accepts dryRun and confirmToken", %{key: key} do
    assert :ok =
             Schemas.validate("sessions.reset", %{
               "sessionKey" => key,
               "dryRun" => true
             })

    assert :ok =
             Schemas.validate("sessions.reset", %{
               "sessionKey" => key,
               "dryRun" => false,
               "confirmToken" => "tok_123"
             })
  end

  test "sessions.reset without a preview token mutates nothing and returns digest", %{key: key} do
    seed_session(key)

    assert {:ok, preview} = SessionsReset.handle(%{"sessionKey" => key}, %{})
    assert preview["dryRun"] == true
    assert preview["sessionKey"] == key
    assert is_binary(preview["confirmToken"]) and preview["confirmToken"] != ""
    assert is_binary(preview["digest"]) and preview["digest"] != ""
    assert preview["preview"]["runHistoryCount"] == 1
    assert preview["preview"]["hasChatState"] == true
    assert preview["preview"]["hasSessionPolicy"] == true
    assert preview["summary"]["reset"] == false
    assert preview["summary"]["requiresConfirmation"] == true

    # Nothing was mutated.
    assert {:ok, [_]} = RunHistoryStore.fetch(key, limit: 10)
    assert %{last_resume_token: _} = ChatStateStore.get(key)
    assert {:ok, %{model: "private-model"}} = PolicyStore.fetch_session(key)

    # Confirming with the issued token resets and verifies deletion.
    assert {:ok, applied} =
             SessionsReset.handle(
               %{
                 "sessionKey" => key,
                 "dryRun" => false,
                 "confirmToken" => preview["confirmToken"]
               },
               %{}
             )

    assert applied["dryRun"] == false
    assert applied["success"] == true
    assert applied["summary"]["reset"] == true
    assert applied["summary"]["verified"] == true

    assert {:ok, []} = RunHistoryStore.fetch(key, limit: 10)
    assert ChatStateStore.get(key) == nil
    assert {:ok, nil} = PolicyStore.fetch_session(key)

    # Replaying the single-use token is refused.
    assert {:error, {:conflict, _msg, %{"reason" => "confirmation_mismatch"}}} =
             SessionsReset.handle(
               %{
                 "sessionKey" => key,
                 "dryRun" => false,
                 "confirmToken" => preview["confirmToken"]
               },
               %{}
             )
  end

  test "stale preview token is rejected when session state changes before confirmation", %{
    key: key
  } do
    seed_session(key)

    assert {:ok, %{"confirmToken" => token}} =
             SessionsReset.handle(%{"sessionKey" => key, "dryRun" => true}, %{})

    :ok = PolicyStore.put_session(key, %{model: "updated-model"})

    assert {:error, {:conflict, _msg, %{"reason" => "confirmation_mismatch"}}} =
             SessionsReset.handle(
               %{"sessionKey" => key, "dryRun" => false, "confirmToken" => token},
               %{}
             )

    # State remains intact.
    assert {:ok, %{model: "updated-model"}} = PolicyStore.fetch_session(key)
    assert {:ok, [_]} = RunHistoryStore.fetch(key, limit: 10)
  end

  test "mid-reset store failure returns retrySafe: false, no raw exception text, and leaves session readable",
       %{key: key} do
    seed_session(key)

    assert {:ok, %{"confirmToken" => token}} =
             SessionsReset.handle(%{"sessionKey" => key, "dryRun" => true}, %{})

    original = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      {:ok, backend_state} = PolicyDeleteFailingBackend.init([])
      %{state | backend: PolicyDeleteFailingBackend, backend_state: backend_state}
    end)

    try do
      # Seed into the fault-injected backend.
      :ok = RunStore.create_session_index(key, "default", :control_plane)
      :ok = ChatStateStore.put(key, %{last_engine: "lemon", last_resume_token: "kept-token"})
      :ok = PolicyStore.put_session(key, %{model: "private-model"})

      # Re-preview against this backend state so token matches.
      assert {:ok, %{"confirmToken" => fault_token}} =
               SessionsReset.handle(%{"sessionKey" => key, "dryRun" => true}, %{})

      assert {:error, {code, message, details}} =
               SessionsReset.handle(
                 %{"sessionKey" => key, "dryRun" => false, "confirmToken" => fault_token},
                 %{}
               )

      assert code in [:unavailable, :internal_error]
      assert details["retrySafe"] == false
      refute message =~ "simulated_disk_full"
      refute inspect(details) =~ "simulated_disk_full"

      # Session stays readable and prior state was restored.
      assert %{session_key: ^key} = SessionLifecycle.get(key)
      assert %{last_resume_token: "kept-token"} = ChatStateStore.get(key)
      assert {:ok, %{model: "private-model"}} = PolicyStore.fetch_session(key)
      assert {:ok, [_]} = RunHistoryStore.fetch(key, limit: 10)
      _ = token
    after
      :sys.replace_state(Store, fn current ->
        Enum.each(current.backend_state, fn {_k, table} -> :ets.delete(table) end)
        original
      end)
    end
  end

  test "ACP touch after sessions.reset does not resurrect ChatState and SessionLifecycle.delete removes ACP metadata" do
    {:ok, created} = ACP.new_session(%{"cwd" => File.cwd!(), "mcpServers" => []})
    session_id = created["sessionId"]
    session_key = get_in(created, ["_meta", "lemon", "sessionKey"])

    on_exit(fn ->
      RunStore.delete_session(session_key)
      ChatStateStore.delete(session_key)
      PolicyStore.delete_session(session_key)
      SessionMetadataStore.delete(session_key)
    end)

    # Simulate an earlier native run that populated ChatState.
    :ok =
      ChatStateStore.put(session_key, %ChatState{
        last_engine: "lemon",
        last_resume_token: "native-resume-before-reset",
        updated_at: System.system_time(:millisecond)
      })

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      {:ok, request.run_id}
    end)

    assert {:ok, _} =
             ACP.prompt(%{
               "sessionId" => session_id,
               "prompt" => [%{"type" => "text", "text" => "before reset"}],
               "_meta" => %{"lemon" => %{"wait" => false}}
             })

    # Preview and execute sessions.reset on the ACP session key.
    assert {:ok, %{"confirmToken" => token, "preview" => preview}} =
             SessionsReset.handle(%{"sessionKey" => session_key, "dryRun" => true}, %{})

    assert preview["hasChatState"] == true
    assert preview["hasAcpMetadata"] == true

    assert {:ok, %{"summary" => %{"reset" => true, "verified" => true}}} =
             SessionsReset.handle(
               %{"sessionKey" => session_key, "dryRun" => false, "confirmToken" => token},
               %{}
             )

    assert ChatStateStore.get(session_key) == nil

    # An ACP prompt/resume after reset MUST NOT resurrect the deleted ChatState.
    assert {:ok, _} =
             ACP.resume_session(%{
               "sessionId" => session_id,
               "cwd" => File.cwd!(),
               "mcpServers" => []
             })

    assert ChatStateStore.get(session_key) == nil

    assert {:ok, _} =
             ACP.prompt(%{
               "sessionId" => session_id,
               "prompt" => [%{"type" => "text", "text" => "after reset"}],
               "_meta" => %{"lemon" => %{"wait" => false}}
             })

    assert ChatStateStore.get(session_key) == nil

    # SessionLifecycle.delete/2 removes all ACP session metadata.
    assert {:ok, %{verified: true}} =
             LemonRouter.with_session_lifecycle_fence(session_key, :delete, fn gen ->
               SessionLifecycle.delete(session_key, fence_generation: gen)
             end)

    assert {:error, -32_602, "session not found"} =
             ACP.resume_session(%{
               "sessionId" => session_id,
               "cwd" => File.cwd!(),
               "mcpServers" => []
             })

    assert {:ok, %{"sessions" => listed}} = ACP.list_sessions(%{})
    refute Enum.any?(listed, &(&1["sessionId"] == session_id))
  end

  test "ACP store write failure after submit returns runId with retrySafe: false instead of raising" do
    {:ok, created} = ACP.new_session(%{"cwd" => File.cwd!(), "mcpServers" => []})
    session_id = created["sessionId"]
    session_key = get_in(created, ["_meta", "lemon", "sessionKey"])

    on_exit(fn ->
      SessionMetadataStore.delete(session_key)
    end)

    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_run_id, request.run_id})
      {:ok, request.run_id}
    end)

    original = :sys.get_state(Store)

    # Copy current ETS tables into the failing backend so reads find the session
    # while writes to session metadata fail after submitter returns {:ok, run_id}.
    :sys.replace_state(Store, fn state ->
      %{state | backend: MetadataPutFailingBackend}
    end)

    try do
      result =
        ACP.handle_jsonrpc(%{
          "jsonrpc" => "2.0",
          "id" => "prompt-fail-put",
          "method" => "session/prompt",
          "params" => %{
            "sessionId" => session_id,
            "prompt" => [%{"type" => "text", "text" => "persist failure"}],
            "_meta" => %{"lemon" => %{"wait" => false}}
          }
        })

      assert_receive {:submitted_run_id, run_id}

      assert {:ok,
              %{
                "error" => %{
                  "code" => -32_000,
                  "data" => %{
                    "runId" => ^run_id,
                    "retrySafe" => false
                  }
                }
              }} = result
    after
      :sys.replace_state(Store, fn _current -> original end)
    end
  end

  defp seed_session(key) do
    assert {:ok, run_id} = LemonRouter.submit(request(key, "earlier work"))
    assert_receive {:execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    finish(command)
    await(fn -> match?({:ok, [_ | _]}, RunHistoryStore.fetch(key, limit: 1)) end)

    await(fn ->
      match?({:ok, %{presence: %{idle: true}}}, LemonRouter.run_presence(%{session_key: key}))
    end)

    :ok = ChatStateStore.put(key, %{last_engine: "lemon", last_resume_token: "resume-#{run_id}"})
    :ok = PolicyStore.put_session(key, %{model: "private-model"})
  end

  defp request(key, prompt) do
    %RunRequest{
      session_key: key,
      agent_id: "default",
      prompt: prompt,
      cwd: File.cwd!(),
      model: "test-model"
    }
  end

  defp finish(command) do
    completed = LemonCore.Events.Completion.new(%{engine: "lemon", ok: true, answer: "done"})

    event =
      Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{completed: completed, duration_ms: 1}),
        %{run_id: command.run_id, session_key: command.session_key}
      )

    :ok = RunCompletion.publish(command, event)
    await(fn -> not LemonRouter.run_active?(command.run_id) end)
  end

  defp await(fun, attempts \\ 200)
  defp await(_fun, 0), do: flunk("condition not met before timeout")

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
