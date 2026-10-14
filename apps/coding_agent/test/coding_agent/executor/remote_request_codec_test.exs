defmodule CodingAgent.Executor.RemoteRequestCodecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonGateway.ExecutionRequest

  test "both JSON and atom placement flags omit the controller cwd" do
    for meta <- [
          %{remote_cwd_explicit: false, remote_cwd: "/controller/unused"},
          %{"remote_cwd_explicit" => false, "remote_cwd" => "/controller/unused"}
        ] do
      request = %ExecutionRequest{run_id: "placement", session_key: "agent:placement:main", prompt: "hello", cwd: "/controller/only", meta: meta}
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
      meta: %{"remote_cwd_explicit" => true, "remote_cwd" => "projects/lemon"}
    }

    assert {:ok, %{"cwd" => "projects/lemon"}} = RemoteRequestCodec.encode(request)
  end

  test "execution persona and HTTP credentials are JSON safe and recognized after transport" do
    instructions = %{"SOUL.md" => "Be precise.\nUnicode: café", "AGENTS.md" => "Read the project guide."}
    servers = [%{name: "lemon-bot", url: "https://bot.test/mcp", headers: %{"Authorization" => "Bearer execution-only"}}]
    request = %ExecutionRequest{
      run_id: "placement",
      session_key: "agent:writer:task-1",
      prompt: "hello",
      cwd: "/controller/only",
      meta: %{remote_cwd_explicit: false, profile_id: "writer", system_prompt: "You are Writer.", profile_instructions: instructions, mcp_servers: servers}
    }

    assert {:ok, payload} = RemoteRequestCodec.encode(request)
    meta = RemoteRequestCodec.normalize_meta(payload["meta"])
    assert meta.profile_id == "writer"
    assert meta.system_prompt == "You are Writer."
    assert meta.profile_instructions == instructions
    assert [%{"name" => "lemon-bot", "headers" => %{"Authorization" => "Bearer execution-only"}}] = meta.mcp_servers
    refute Map.has_key?(meta, "system_prompt")
    assert payload["cwd"] == nil
  end

  test "normalization uses only fixed existing keys and preserves false capability flags" do
    meta = RemoteRequestCodec.normalize_meta(%{"system_prompt" => "persona", "acp_client_terminal" => false, "unrecognized" => "data"})
    assert meta.system_prompt == "persona"
    assert meta.acp_client_terminal == false
    assert meta["unrecognized"] == "data"
  end

  test "failed destination completion remains false after JSON decoding" do
    assert {:ok, %{ok: false, error: "denied"}} =
             RemoteRequestCodec.decode_result(%{"completed" => %{"ok" => false, "error" => "denied"}})
  end

  test "callbacks cannot cross the execution boundary" do
    request = %ExecutionRequest{run_id: "placement", session_key: "agent:placement:main", prompt: "hello", meta: %{stream_fn: fn -> :private end}}
    assert {:error, {:invalid_request_payload, _}} = RemoteRequestCodec.encode(request)
  end
end
