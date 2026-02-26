defmodule CodingAgent.Tools.ToolAuthTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.ToolAuth
  alias LemonCore.{Secrets, Store}

  @moduletag :tmp_dir

  setup do
    clear_secrets_table()
    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("WASM_TOOL_AUTH_TEST_TOKEN")
    end)

    :ok
  end

  test "returns no_auth_required when no auth block exists", %{tmp_dir: tmp_dir} do
    write_capabilities(tmp_dir, "no_auth_tool", %{
      "http" => %{"allowlist" => [%{"host" => "api.example.com"}]}
    })

    tool = ToolAuth.tool(tmp_dir, settings_manager: %SettingsManager{})
    result = tool.execute.("call-1", %{"name" => "no_auth_tool"}, nil, nil)

    assert %AgentToolResult{} = result
    assert result.details["status"] == "no_auth_required"
    assert result.details["awaiting_token"] == false
  end

  test "imports env_var into secret store when present", %{tmp_dir: tmp_dir} do
    System.put_env("WASM_TOOL_AUTH_TEST_TOKEN", "env-token-value")

    write_capabilities(tmp_dir, "env_auth_tool", %{
      "auth" => %{
        "secret_name" => "env_auth_tool_secret",
        "display_name" => "Env Tool",
        "env_var" => "WASM_TOOL_AUTH_TEST_TOKEN"
      }
    })

    tool = ToolAuth.tool(tmp_dir, settings_manager: %SettingsManager{})
    result = tool.execute.("call-2", %{"name" => "env_auth_tool"}, nil, nil)

    assert %AgentToolResult{} = result
    assert result.details["status"] == "authenticated"

    assert {:ok, "env-token-value", :store} =
             Secrets.resolve("env_auth_tool_secret", prefer_env: false, env_fallback: false)
  end

  test "returns awaiting_token with instructions when token is missing", %{tmp_dir: tmp_dir} do
    write_capabilities(tmp_dir, "manual_auth_tool", %{
      "auth" => %{
        "secret_name" => "manual_auth_tool_secret",
        "display_name" => "Manual Tool",
        "instructions" => "Create a token and store it in Lemon secrets.",
        "setup_url" => "https://example.com/setup"
      }
    })

    tool = ToolAuth.tool(tmp_dir, settings_manager: %SettingsManager{})
    result = tool.execute.("call-3", %{"name" => "manual_auth_tool"}, nil, nil)

    assert %AgentToolResult{} = result
    assert result.details["status"] == "awaiting_token"
    assert result.details["awaiting_token"] == true
    assert result.details["instructions"] =~ "Create a token"
    assert result.details["setup_url"] == "https://example.com/setup"
  end

  test "reports authenticated when the secret already exists", %{tmp_dir: tmp_dir} do
    assert {:ok, _metadata} = Secrets.set("existing_auth_secret", "stored-token")

    write_capabilities(tmp_dir, "existing_auth_tool", %{
      "auth" => %{
        "secret_name" => "existing_auth_secret",
        "display_name" => "Existing Tool"
      }
    })

    tool = ToolAuth.tool(tmp_dir, settings_manager: %SettingsManager{})
    result = tool.execute.("call-4", %{"name" => "existing_auth_tool"}, nil, nil)

    assert %AgentToolResult{} = result
    assert result.details["status"] == "authenticated"
    assert result.details["awaiting_token"] == false
  end

  defp write_capabilities(tmp_dir, name, payload) do
    tool_dir = Path.join(tmp_dir, ".lemon/wasm-tools")
    File.mkdir_p!(tool_dir)
    cap_path = Path.join(tool_dir, "#{name}.capabilities.json")
    File.write!(cap_path, Jason.encode!(payload))
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end
