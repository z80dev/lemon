defmodule LemonRouter.AgentMessagingRecoveryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, SessionManager}
  alias CodingAgent.Session.Presentation

  alias LemonCore.{
    AgentIdentity,
    ChatStateStore,
    Event,
    ExecutionCommand,
    ResumeToken,
    RunRequest,
    RunStore,
    Store,
    ToolPolicy
  }

  alias LemonRouter.{AgentMessaging, AgentMessagingSessions, ResumeResolver, RunCompletion}

  # Keep native recovery, identity lookup, durable admission and the real router
  # queue in the loop. Only the final executor is controlled; no provider runs.
  defmodule ControlledRuntime do
    @behaviour LemonCore.EngineRuntime
    def available?, do: true
    def run_pid(_), do: nil
    def cancel_by_run_id(_, _), do: :ok

    def submit_execution(command) do
      send(
        Application.fetch_env!(:lemon_router, :named_agent_recovery_test_pid),
        {:recovery_execution, command}
      )

      :ok
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    original_agent_dir = System.get_env("LEMON_AGENT_DIR")
    original_runtime = Application.get_env(:lemon_router, :engine_runtime)
    original_pid = Application.get_env(:lemon_router, :named_agent_recovery_test_pid)
    original_provider = Application.get_env(:lemon_core, :agent_runtime_provider)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    Application.put_env(:lemon_router, :engine_runtime, ControlledRuntime)
    Application.put_env(:lemon_router, :named_agent_recovery_test_pid, self())
    Application.put_env(:lemon_core, :agent_runtime_provider, ControlPlaneProvider)
    cwd = Path.join(root, "original-workspace")
    File.mkdir_p!(cwd)

    on_exit(fn ->
      restore_env(:lemon_router, :engine_runtime, original_runtime)
      restore_env(:lemon_router, :named_agent_recovery_test_pid, original_pid)
      restore_env(:lemon_core, :agent_runtime_provider, original_provider)

      if original_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", original_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")

      case Store.fetch_all(:agent_message_receipts) do
        {:ok, rows} ->
          Enum.each(rows, fn {id, _} ->
            if String.ends_with?(id, "-#{suffix}"),
              do: Store.delete(:agent_message_receipts, id)
          end)

        _ ->
          :ok
      end
    end)

    %{suffix: suffix, cwd: cwd, root: root}
  end

  test "wrong native header refuses named admission despite a historical cwd", context do
    source = seed_admitted("source", context)
    target = seed_historical("wrong-header", context)
    spoof = %{target.session | header: %{target.session.header | id: "different-native-owner"}}
    assert :ok = SessionManager.save_to_file(target.path, spoof)
    original = File.read!(target.path)

    assert {:error, :context_unavailable} =
             ControlPlaneProvider.session_addressing_context(target.key)

    assert_refused(source, target, "wrong-header", context)
    assert File.read!(target.path) == original
  end

  test "ambiguous native journals refuse named admission despite a historical cwd", context do
    source = seed_admitted("source", context)
    target = seed_historical("ambiguous-journals", context)
    other_cwd = Path.join(context.root, "other-workspace")
    File.mkdir_p!(other_cwd)
    duplicate = %{target.session | header: %{target.session.header | cwd: other_cwd}}
    duplicate_path = Presentation.session_file_path(duplicate.header.id, other_cwd)
    assert :ok = SessionManager.save_to_file(duplicate_path, duplicate)

    assert {:error, :context_unavailable} =
             ControlPlaneProvider.session_addressing_context(target.key)

    assert_refused(source, target, "ambiguous-journals", context)
    assert File.exists?(target.path)
    assert File.exists?(duplicate_path)
  end

  test "ambiguous live roots refuse named admission despite a historical cwd", context do
    source = seed_admitted("source", context)
    target = seed_historical("ambiguous-live", context)

    for id <- [:first_root, :second_root] do
      start_supervised!(
        Supervisor.child_spec(
          {CodingAgent.Session,
           cwd: context.cwd,
           workspace_dir: Path.join(context.root, "bootstrap"),
           session_key: target.key,
           register: true,
           task_child: false,
           model: LemonAi.Models.get_model(:openai, "gpt-4o"),
           system_prompt: "Recovery ownership test",
           tools: [],
           stream_fn: fn _, _, _ -> flunk("recovery must not invoke a provider") end},
          id: id
        )
      )
    end

    assert {:error, :context_unavailable} =
             ControlPlaneProvider.session_addressing_context(target.key)

    assert_refused(source, target, "ambiguous-live", context)
  end

  test "cold legacy recovery without a recorded policy keeps its journal and router defaults",
       context do
    source = seed_admitted("source", context)
    target = seed_historical("unbound-legacy", context)
    resume = ResumeToken.new("lemon", target.session.header.id)

    assert {:ok, %{status: :accepted, run_id: run_id}} =
             AgentMessaging.send(
               "operator",
               source.id,
               "session://" <> target.key,
               "Continue the legacy journal",
               message_id: "legacy-#{context.suffix}"
             )

    assert_receive {:recovery_execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    assert command.resume == resume
    assert command.cwd == context.cwd
    assert command.tool_policy == source.policy
    finish(command, "Legacy answer")
    assert_receive {:recovery_execution, %ExecutionCommand{} = reply}, 2_000
    finish(reply, "Received")
  end

  test "query recovery never creates a deleted session index", context do
    target = seed_historical("deleted-index", context)
    assert :ok = RunStore.delete_session_index(target.key)
    assert {:error, :not_found} = AgentMessagingSessions.context(target.key)
    assert {:ok, nil} = RunStore.fetch_session_index(target.key)
    assert File.exists?(target.path)
  end

  test "a nonempty cold fork inherits policy and resumes its exact journal before any normal turn",
       context do
    source = seed_admitted("source", context)
    fork = seed_cold_fork(context)
    original = File.read!(fork.path)
    files = journal_files(context)
    handle = "cold_fork_#{context.suffix}"
    target_id = "session://" <> fork.key

    assert {:ok, %{run_count: 0}} = RunStore.fetch_session_index(fork.key)
    assert {:ok, nil} = Store.fetch(:agent_messaging_sessions, fork.key)
    assert {:ok, recovered} = ControlPlaneProvider.session_addressing_context(fork.key)
    assert ToolPolicy.allowed?(recovered.tool_policy, "read")
    refute ToolPolicy.allowed?(recovered.tool_policy, "exec")
    assert recovered.cwd == context.cwd
    assert recovered.resume == fork.resume
    assert {:ok, %{id: ^target_id}} = AgentMessaging.rename("operator", target_id, handle)
    assert {:ok, nil} = Store.fetch(:native_resume_contexts, {"lemon", fork.resume.value})

    message_id = "cold-fork-#{context.suffix}"

    assert {:ok, %{status: :accepted, run_id: run_id}} =
             AgentMessaging.send("operator", source.id, "@" <> handle, "Continue the fork",
               message_id: message_id
             )

    assert_receive {:recovery_execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    assert command.session_key == fork.key
    assert command.cwd == context.cwd
    assert command.resume == fork.resume
    assert ToolPolicy.allowed?(command.tool_policy, "read")
    refute ToolPolicy.allowed?(command.tool_policy, "exec")
    assert command.meta.named_agent_require_resume
    assert {:ok, binding} = Store.fetch(:native_resume_contexts, {"lemon", fork.resume.value})
    assert is_binary(binding)
    assert ChatStateStore.get(fork.key).last_resume_token == fork.resume.value
    assert journal_files(context) == files
    assert File.read!(fork.path) == original

    finish(command, "The inherited branch answer")

    assert_receive {:recovery_execution, %ExecutionCommand{session_key: source_key} = reply},
                   2_000

    assert source_key == source.key
    assert reply.meta.named_agent_reply
    finish(reply, "Received")
    assert File.read!(fork.path) == original
  end

  test "cold inherited policy cannot overwrite an incompatible existing resume binding",
       context do
    source = seed_admitted("source", context)
    fork = seed_cold_fork(context)
    original = File.read!(fork.path)
    files = journal_files(context)

    assert :ok =
             ResumeResolver.bind(fork.resume, %ExecutionCommand{
               run_id: "incompatible-#{context.suffix}",
               session_key: fork.key,
               prompt: "",
               tool_policy: ToolPolicy.from_profile(:full_access),
               meta: %{}
             })

    assert {:ok, original_binding} =
             Store.fetch(:native_resume_contexts, {"lemon", fork.resume.value})

    assert {:error, :context_unavailable} =
             AgentMessaging.send(
               "operator",
               source.id,
               "session://" <> fork.key,
               "Do not create another journal",
               message_id: "conflicting-fork-#{context.suffix}"
             )

    refute_receive {:recovery_execution, _}, 100

    assert {:ok, ^original_binding} =
             Store.fetch(:native_resume_contexts, {"lemon", fork.resume.value})

    assert ChatStateStore.get(fork.key).last_resume_token == fork.resume.value
    assert File.read!(fork.path) == original
    assert journal_files(context) == files
  end

  test "captured replies cannot continue a recreated source even with the same creation timestamp",
       context do
    source = seed_admitted("source", context)
    target = seed_admitted("target", context)
    assert {:ok, old_index} = RunStore.ensure_session_incarnation(source.key)
    assert {:ok, old_context} = AgentMessagingSessions.context(source.key)
    message_id = "recreated-source-#{context.suffix}"

    assert {:ok, %{status: :accepted, run_id: run_id}} =
             AgentMessaging.send("operator", source.id, target.id, "Answer after recreation",
               message_id: message_id
             )

    assert_receive {:recovery_execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000

    assert :ok = RunStore.delete_session_index(source.key)
    assert :ok = RunStore.create_session_index(source.key, "default", :control_plane)
    assert {:ok, new_index} = RunStore.ensure_session_incarnation(source.key)
    refute new_index.incarnation == old_index.incarnation

    assert :ok =
             Store.put(
               :sessions_index,
               source.key,
               Map.put(new_index, :created_at_ms, old_index.created_at_ms)
             )

    fresh = save_native(source.key, context.cwd)
    assert {:ok, current} = AgentMessagingSessions.context(source.key)
    assert current.incarnation == new_index.incarnation
    refute current.incarnation == old_context.incarnation
    assert {:ok, %{created_at_ms: timestamp}} = RunStore.fetch_session_index(source.key)
    assert timestamp == old_index.created_at_ms

    assert {:error, :forbidden} =
             AgentMessagingSessions.request(
               %{session_key: source.key},
               "stale-reply-#{context.suffix}",
               "Late result",
               %{},
               old_context
             )

    finish(command, "An answer for the deleted source")

    wait_until(fn ->
      match?({:ok, %{status: :completed}}, AgentMessaging.get("operator", source.id, message_id))
    end)

    source_key = source.key
    refute_receive {:recovery_execution, %ExecutionCommand{session_key: ^source_key}}, 100
    assert ChatStateStore.get(source.key).last_resume_token == fresh.header.id
  end

  defp assert_refused(source, target, label, context) do
    message_id = "refused-#{label}-#{context.suffix}"
    files = journal_files(context)

    assert {:error, :context_unavailable} =
             AgentMessaging.send(
               "operator",
               source.id,
               "session://" <> target.key,
               "Do not bypass recovery",
               message_id: message_id
             )

    assert {:error, :not_found} = AgentMessaging.get("operator", source.id, message_id)
    refute_receive {:recovery_execution, _}, 100
    assert journal_files(context) == files
  end

  defp seed_admitted(label, context) do
    key = session_key(label, context)
    cleanup_session(key)

    assert {:ok, run_id} =
             LemonRouter.submit(%RunRequest{
               session_key: key,
               agent_id: "default",
               prompt: "Existing #{label}",
               cwd: context.cwd
             })

    assert_receive {:recovery_execution, %ExecutionCommand{run_id: ^run_id} = command}, 2_000
    resume = ResumeToken.new("lemon", "recovery-#{label}-#{context.suffix}")
    assert :ok = ResumeResolver.bind(resume, command)
    assert :ok = ChatStateStore.put(key, %{last_engine: "lemon", last_resume_token: resume.value})
    on_exit(fn -> Store.delete(:native_resume_contexts, {"lemon", resume.value}) end)
    finish(command, "Existing context")
    %{id: "session://" <> key, key: key, policy: command.tool_policy}
  end

  defp seed_historical(label, context) do
    key = session_key(label, context)
    cleanup_session(key)
    session = save_native(key, context.cwd)

    assert :ok =
             RunStore.finalize("historical-#{label}-#{context.suffix}", %{
               session_key: key,
               agent_id: "default",
               cwd: context.cwd,
               meta: %{task_child: false, native_managed_context: false}
             })

    %{
      key: key,
      session: session,
      path: Presentation.session_file_path(session.header.id, context.cwd)
    }
  end

  defp seed_cold_fork(context) do
    parent = seed_historical("fork-parent", context)
    policy = ToolPolicy.from_profile(:read_only)

    assert {:ok, execution} =
             LemonCore.ExecutionContext.new(
               run_id: "historical-fork-parent-#{context.suffix}",
               cwd: context.cwd,
               agent_id: "default",
               origin: :control_plane,
               tool_policy: policy
             )

    assert {:ok, session} = SessionManager.append_execution_context(parent.session, execution)

    session =
      SessionManager.append_message(session, %{
        "role" => "user",
        "content" => "Preserve the existing branch and read-only authority"
      })

    assert :ok = SessionManager.save_to_file(parent.path, session)
    key = session_key("cold-fork", context)
    cleanup_session(key)
    assert :ok = ControlPlaneProvider.session_fork(parent.key, context.cwd, key)
    assert :ok = RunStore.create_session_index(key, "default", :control_plane)
    resume = ResumeToken.new("lemon", ChatStateStore.get(key).last_resume_token)
    path = Presentation.session_file_path(resume.value, context.cwd)
    assert {:ok, fork} = SessionManager.load_from_file(path)
    assert {:ok, inherited} = SessionManager.execution_context(fork)
    assert inherited.provenance.origin == "fork"
    assert ToolPolicy.allowed?(inherited.tool_policy, "read")
    refute ToolPolicy.allowed?(inherited.tool_policy, "exec")
    assert fork.header.parent_session == parent.session.header.id
    assert length(SessionManager.entries(fork)) > 1
    on_exit(fn -> Store.delete(:native_resume_contexts, {"lemon", resume.value}) end)
    %{key: key, path: path, resume: resume, policy: inherited.tool_policy}
  end

  defp save_native(key, cwd) do
    session = SessionManager.new(cwd)

    assert :ok =
             SessionManager.save_to_file(
               Presentation.session_file_path(session.header.id, cwd),
               session
             )

    assert :ok =
             ChatStateStore.put(key, %LemonCore.ChatState{
               last_engine: "lemon",
               last_resume_token: session.header.id
             })

    session
  end

  defp cleanup_session(key) do
    on_exit(fn ->
      LemonRouter.abort(key)
      AgentIdentity.remove("operator", "session://" <> key)
      RunStore.delete_session(key)
      Store.delete(:agent_messaging_sessions, key)
      ChatStateStore.delete(key)
    end)
  end

  defp session_key(label, context),
    do: "agent:default:tui:local:main:recovery-#{label}-#{context.suffix}"

  defp journal_files(context),
    do:
      Path.wildcard(Path.join([context.root, "agent", "sessions", "*", "*.jsonl"])) |> Enum.sort()

  defp finish(command, answer) do
    completed = LemonCore.Events.Completion.new(%{engine: "lemon", ok: true, answer: answer})

    event =
      Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{completed: completed, duration_ms: 1}),
        %{run_id: command.run_id, session_key: command.session_key}
      )

    assert :ok = RunCompletion.publish(command, event)
  end

  defp wait_until(fun, remaining \\ 100)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_until(fun, remaining - 1)
        )
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
