defmodule LemonRouter.ResumeResolverTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ChatStateStore, ExecutionCommand, ResumeToken}
  alias LemonRouter.ResumeResolver

  defmodule SyncRefusingBackend do
    @behaviour LemonCore.Store.Backend
    def init(_opts), do: {:ok, %{}}
    def put(state, table, key, value), do: {:ok, Map.put(state, {table, key}, value)}

    def put_new(state, table, key, value) do
      if Map.has_key?(state, {table, key}),
        do: {:exists, state},
        else: put(state, table, key, value)
    end

    def get(state, table, key), do: {:ok, Map.get(state, {table, key}), state}
    def delete(state, table, key), do: {:ok, Map.delete(state, {table, key})}

    def list(state, table),
      do: {:ok, for({{^table, key}, value} <- state, do: {key, value}), state}

    def sync(_state), do: {:error, :sync_refused}
  end

  setup do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = ChatStateStore.delete(session_key)
    end)

    {:ok, session_key: session_key}
  end

  test "prefers an explicit native resume token", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "codex", last_resume_token: "stale"})

    assert {:ok, %ResumeToken{engine: "lemon", value: "thread_123"}, :explicit} =
             ResumeResolver.resolve(
               %ResumeToken{engine: "lemon", value: "thread_123"},
               session_key
             )
  end

  test "rejects an explicit resume token for a retired engine", %{session_key: session_key} do
    assert {:error, {:unsupported_resume_engine, "codex", message}} =
             ResumeResolver.resolve(
               %ResumeToken{engine: "codex", value: "thread_123"},
               session_key
             )

    assert message =~ ~s(native "lemon" engine)
  end

  test "uses native auto resume from chat state", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "lemon", last_resume_token: "thread_auto"})

    assert {:ok, %ResumeToken{engine: "lemon", value: "thread_auto"}, :auto} =
             ResumeResolver.resolve(nil, session_key)
  end

  test "does not auto resume when disabled in meta", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "lemon", last_resume_token: "thread_auto"})

    assert {:ok, nil, nil} =
             ResumeResolver.resolve(nil, session_key, %{disable_auto_resume: true})
  end

  test "ignores stale non-native auto state without deleting it", %{session_key: session_key} do
    ChatStateStore.put(session_key, %{last_engine: "claude", last_resume_token: "thread_auto"})

    assert {:ok, nil, nil} = ResumeResolver.resolve(nil, session_key)

    assert %{last_engine: "claude", last_resume_token: "thread_auto"} =
             ChatStateStore.get(session_key)
  end

  test "bound native journals resume only the exact principal capabilities and memory scope", %{
    session_key: session_key
  } do
    token = %ResumeToken{engine: "lemon", value: session_key}

    meta = %{
      invocation_context_key: "owner",
      memory_context_key: "private-room",
      memory_context_verified: true,
      shared_memory_grant: true,
      mcp_servers: [%{url: "https://mcp.invalid", secret_ref: "grant-a"}]
    }

    policy = %{blocked_tools: ["bash"]}

    request = %ExecutionCommand{
      run_id: session_key,
      session_key: session_key,
      prompt: "private",
      meta: meta,
      tool_policy: policy
    }

    assert :ok = ResumeResolver.bind_run(request)
    assert :ok = ResumeResolver.bind(token, request)

    assert :ok =
             ChatStateStore.put(session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    assert {:ok, ^token, :auto} = ResumeResolver.resolve(nil, session_key, meta, policy)
    assert {:ok, ^token, :explicit} = ResumeResolver.resolve(token, session_key, meta, policy)

    for {other_meta, other_policy} <- [
          {Map.put(meta, :invocation_context_key, "other"), policy},
          {Map.delete(meta, :invocation_context_key), policy},
          {Map.put(meta, :memory_context_key, "shared-room"), policy},
          {Map.delete(meta, :memory_context_key), policy},
          {Map.put(meta, :memory_context_verified, false), policy},
          {Map.put(meta, :shared_memory_grant, false), policy},
          {Map.put(meta, :mcp_servers, []), policy},
          {Map.delete(meta, :mcp_servers), policy},
          {meta, %{blocked_tools: ["read"]}}
        ] do
      assert {:ok, nil, nil} = ResumeResolver.resolve(nil, session_key, other_meta, other_policy)

      assert {:ok, nil, nil} =
               ResumeResolver.resolve(token, session_key, other_meta, other_policy)

      changed = %{request | meta: other_meta, tool_policy: other_policy}
      assert {:error, :resume_context_conflict} = ResumeResolver.bind(token, changed)
      assert {:ok, ^token, :auto} = ResumeResolver.resolve(nil, session_key, meta, policy)
    end

    assert ChatStateStore.get(session_key).last_resume_token == token.value
  end

  test "unknown journals preserve legacy default policy but reject unproven scoped capabilities",
       %{
         session_key: session_key
       } do
    token = %ResumeToken{engine: "lemon", value: session_key}

    assert :ok =
             ChatStateStore.put(session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    policy = %{approvals: %{"bash" => :always}}
    assert {:ok, ^token, :auto} = ResumeResolver.resolve(nil, session_key, %{}, policy)

    for meta <- [
          %{invocation_context_key: "owner"},
          %{memory_context_key: "private-room"},
          %{mcp_servers: []},
          %{resume_policy_override: true}
        ] do
      assert {:ok, nil, nil} = ResumeResolver.resolve(nil, session_key, meta, policy)
      assert {:ok, nil, nil} = ResumeResolver.resolve(token, session_key, meta, policy)
    end

    assert ChatStateStore.get(session_key).last_resume_token == token.value
  end

  test "durable run ownership filters private compaction history instead of deleting it", %{
    session_key: session_key
  } do
    policy = %{blocked_tools: ["bash"]}
    private = %{invocation_context_key: "owner", memory_context_key: "private-room"}
    other = %{invocation_context_key: "other", memory_context_key: "shared-room"}

    first = %ExecutionCommand{
      run_id: "#{session_key}-first",
      session_key: session_key,
      prompt: "private first",
      tool_policy: policy,
      meta: private
    }

    second = %{first | run_id: "#{session_key}-second", meta: other}
    assert :ok = ResumeResolver.bind_run(first)
    assert :ok = ResumeResolver.bind_run(second)
    first_entry = {first.run_id, %{summary: %{prompt: first.prompt, meta: private}}}
    second_entry = {second.run_id, %{summary: %{prompt: "other prompt", meta: other}}}

    unbound_private =
      {"#{session_key}-unbound", %{summary: %{prompt: "unbound private", meta: private}}}

    legacy = {"#{session_key}-legacy", %{summary: %{prompt: "legacy"}}}
    history = [first_entry, second_entry, unbound_private, legacy]

    assert ResumeResolver.filter_history(history, private, policy) == [first_entry]
    assert ResumeResolver.filter_history(history, other, policy) == [second_entry]
    assert ResumeResolver.filter_history(history, %{}, policy) == [legacy]

    assert {:error, :resume_context_conflict} =
             ResumeResolver.bind_run(%{first | meta: other})

    assert ResumeResolver.filter_history(history, private, policy) == [first_entry]
  end

  test "visible but unsynchronized context bindings cannot authorize native resume or history", %{
    session_key: session_key
  } do
    name = :"resume_sync_#{System.unique_integer([:positive])}"
    store = start_supervised!({LemonCore.Store, name: name, backend: SyncRefusingBackend})
    token = %ResumeToken{engine: "lemon", value: session_key}
    meta = %{invocation_context_key: "owner", memory_context_key: "private-room"}
    policy = %{blocked_tools: ["bash"]}

    request = %ExecutionCommand{
      run_id: session_key,
      session_key: session_key,
      prompt: "private",
      meta: meta,
      tool_policy: policy
    }

    assert {:error, :sync_refused} = ResumeResolver.bind(token, request, store)
    assert {:error, :sync_refused} = ResumeResolver.bind_run(request, store)

    assert :ok =
             ChatStateStore.put(store, session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    assert {:ok, nil, nil} = ResumeResolver.resolve(nil, session_key, meta, policy, store)
    assert {:ok, nil, nil} = ResumeResolver.resolve(token, session_key, meta, policy, store)
    history = [{request.run_id, %{summary: %{prompt: request.prompt, meta: meta}}}]
    assert ResumeResolver.filter_history(history, meta, policy, store) == []
  end

  test "only factory-attested run proof rotation preserves native resume and scoped history", %{
    session_key: session_key
  } do
    first_id = "proof-#{System.unique_integer([:positive])}"
    second_id = "proof-#{System.unique_integer([:positive])}"
    first_meta = proof_meta(first_id)
    second_meta = proof_meta(second_id)
    policy = %{blocked_tools: ["bash"]}

    first = %ExecutionCommand{
      run_id: first_id,
      session_key: session_key,
      prompt: "first",
      meta: first_meta,
      tool_policy: policy
    }

    token = %ResumeToken{engine: "lemon", value: session_key}
    assert :ok = ResumeResolver.bind_run(first)
    assert :ok = ResumeResolver.bind(token, first)

    assert :ok =
             ChatStateStore.put(session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    entry = {first_id, %{summary: %{prompt: "first", meta: first_meta}}}

    assert {:ok, ^token, :auto} =
             ResumeResolver.resolve(
               nil,
               session_key,
               second_meta,
               policy,
               LemonCore.Store,
               second_id
             )

    assert {:ok, ^token, :explicit} =
             ResumeResolver.resolve(
               token,
               session_key,
               second_meta,
               policy,
               LemonCore.Store,
               second_id
             )

    assert ResumeResolver.filter_history([entry], second_meta, policy, LemonCore.Store, second_id) ==
             [entry]

    [server] = second_meta.mcp_servers

    changed_server = %{
      server
      | headers: Map.put(server.headers, "Authorization", "${LEMON_SECRET:other/grant}")
    }

    for altered <- [
          Map.delete(second_meta, :invocation_proof_verified),
          %{second_meta | invocation_proof: first_meta.invocation_proof},
          %{second_meta | mcp_servers: [changed_server]},
          %{second_meta | memory_context_verified: false}
        ] do
      assert {:ok, nil, nil} =
               ResumeResolver.resolve(
                 nil,
                 session_key,
                 altered,
                 policy,
                 LemonCore.Store,
                 second_id
               )

      assert ResumeResolver.filter_history([entry], altered, policy, LemonCore.Store, second_id) ==
               []
    end

    second = %{first | run_id: second_id, meta: second_meta}
    assert :ok = ResumeResolver.bind_run(second)

    assert ResumeResolver.filter_history(
             [{second_id, %{summary: %{prompt: "second", meta: second_meta}}}],
             first_meta,
             policy,
             LemonCore.Store,
             first_id
           ) != []
  end

  defp proof_meta(run_id) do
    name = "lemon_bot/invocations/#{run_id}"

    servers = [
      %{
        name: "core",
        url: "https://core.invalid/mcp",
        headers: %{
          "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:#{name}}",
          "Authorization" => "${LEMON_SECRET:connector/same}"
        }
      }
    ]

    descriptor = %{
      "runId" => run_id,
      "serverName" => "core",
      "serverUrl" => "https://core.invalid/mcp",
      "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => name
    }

    assert {:ok, proof} = LemonCore.InvocationProof.validate(descriptor, run_id, servers)

    %{
      invocation_context_key: "same-actor",
      memory_context_key: "same-room",
      memory_context_verified: true,
      invocation_proof_verified: true,
      invocation_proof: proof,
      mcp_servers: servers
    }
  end
end
