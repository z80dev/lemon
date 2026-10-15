defmodule CodingAgent.Executor.RemoteRequestCodecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonCore.ExecutionContext
  alias LemonGateway.ExecutionRequest

  test "both JSON and atom placement flags omit the controller cwd" do
    for meta <- [
          %{remote_cwd_explicit: false, remote_cwd: "/controller/unused"},
          %{"remote_cwd_explicit" => false, "remote_cwd" => "/controller/unused"}
        ] do
      request = %ExecutionRequest{
        run_id: "placement",
        session_key: "agent:placement:main",
        prompt: "hello",
        cwd: "/controller/only",
        execution_context: context(),
        meta: meta
      }

      assert {:ok, payload} = RemoteRequestCodec.encode(request)
      assert payload["cwd"] == nil
      refute Map.has_key?(payload["meta"], "remote_cwd")
      refute Map.has_key?(payload["meta"], "remote_cwd_explicit")
      refute inspect(payload) =~ "/controller/"
    end
  end

  test "explicit destination paths survive JSON placement metadata" do
    request = %ExecutionRequest{
      run_id: "placement",
      session_key: "agent:placement:main",
      prompt: "hello",
      cwd: "/controller/only",
      execution_context: context(),
      meta: %{"remote_cwd_explicit" => true, "remote_cwd" => "projects/lemon"}
    }

    assert {:ok, %{"cwd" => "projects/lemon"}} = RemoteRequestCodec.encode(request)
  end

  test "execution persona and HTTP credentials are JSON safe and recognized after transport" do
    instructions = %{
      "SOUL.md" => "Be precise.\nUnicode: café",
      "AGENTS.md" => "Read the project guide."
    }

    servers = [
      %{
        name: "lemon-bot",
        url: "https://bot.test/mcp",
        headers: %{"Authorization" => "Bearer execution-only"}
      }
    ]

    request = %ExecutionRequest{
      run_id: "placement",
      session_key: "agent:writer:task-1",
      prompt: "hello",
      cwd: "/controller/only",
      execution_context: context(),
      meta: %{
        remote_cwd_explicit: false,
        profile_id: "writer",
        system_prompt: "You are Writer.",
        profile_instructions: instructions,
        mcp_servers: servers
      }
    }

    assert {:ok, payload} = RemoteRequestCodec.encode(request)
    meta = RemoteRequestCodec.normalize_meta(payload["meta"])
    assert meta.profile_id == "writer"
    assert meta.system_prompt == "You are Writer."
    assert meta.profile_instructions == instructions

    assert [%{"name" => "lemon-bot", "headers" => %{"Authorization" => "Bearer execution-only"}}] =
             meta.mcp_servers

    refute Map.has_key?(meta, "system_prompt")
    assert payload["cwd"] == nil
  end

  test "normalization uses only fixed existing keys and preserves false capability flags" do
    meta =
      RemoteRequestCodec.normalize_meta(%{
        "system_prompt" => "persona",
        "acp_client_terminal" => false,
        "unrecognized" => "data"
      })

    assert meta.system_prompt == "persona"
    assert meta.acp_client_terminal == false
    assert meta["unrecognized"] == "data"
  end

  test "failed destination completion remains false after JSON decoding" do
    assert {:ok, %{ok: false, error: "denied"}} =
             RemoteRequestCodec.decode_result(%{
               "completed" => %{"ok" => false, "error" => "denied"}
             })
  end

  test "callbacks cannot cross the execution boundary" do
    request = %ExecutionRequest{
      run_id: "placement",
      session_key: "agent:placement:main",
      prompt: "hello",
      execution_context: context(),
      meta: %{stream_fn: fn -> :private end}
    }

    assert {:error, {:invalid_request_payload, _}} = RemoteRequestCodec.encode(request)
  end

  test "versioned authority intersects request policy without transporting source workspace" do
    assert {:ok, authority} =
             ExecutionContext.new(
               run_id: "placement",
               cwd: "/controller/private",
               tool_policy: %{allow: ["read", "write"], deny: ["bash"]},
               capabilities: ["read", "write"],
               limits: %{max_steps: 7}
             )

    request = %ExecutionRequest{
      run_id: "placement",
      prompt: "bounded work",
      execution_context: authority,
      tool_policy: %{allow: ["read"], require_approval: ["read"]},
      meta: %{remote_cwd_explicit: false}
    }

    assert {:ok, payload} = RemoteRequestCodec.encode(request)
    assert payload["version"] == 2
    assert {:ok, decoded} = ExecutionContext.decode(payload["executionContext"])
    assert decoded.run_id == authority.run_id
    assert decoded.attempt_id == authority.attempt_id
    assert decoded.principal == authority.principal
    assert decoded.provenance == authority.provenance
    assert decoded.capabilities == authority.capabilities
    assert decoded.limits == authority.limits
    assert decoded.workspace_scope == %{root: nil, mode: :read_write}
    assert authority.workspace_scope.root == "/controller/private"
    assert LemonCore.ToolPolicy.allowed?(decoded.tool_policy, "read")
    refute LemonCore.ToolPolicy.allowed?(decoded.tool_policy, "write")
    assert LemonCore.ToolPolicy.requires_approval?(decoded.tool_policy, "read")
    assert "bash" in decoded.tool_policy.deny
    refute inspect(payload) =~ "/controller/"
    assert {:ok, ^payload} = payload |> Jason.encode!() |> Jason.decode()
  end

  test "missing, forged, mismatched and malformed authority fail before encoding" do
    request = %ExecutionRequest{run_id: "placement", prompt: "must not cross"}
    assert {:error, :invalid_execution_context} = RemoteRequestCodec.encode(request)

    assert {:error, :invalid_execution_context} =
             RemoteRequestCodec.encode(%{request | execution_context: %{run_id: "placement"}})

    assert {:error, :execution_context_run_id_mismatch} =
             RemoteRequestCodec.encode(%{
               request
               | execution_context: %{context() | run_id: "other"}
             })

    assert {:error, {:invalid_policy_field, :allow}} =
             RemoteRequestCodec.encode(%{
               request
               | execution_context: context(),
                 tool_policy: %{"allow" => 123}
             })
  end

  defp context do
    {:ok, context} = ExecutionContext.new(run_id: "placement", cwd: "/controller/only")
    context
  end
end
