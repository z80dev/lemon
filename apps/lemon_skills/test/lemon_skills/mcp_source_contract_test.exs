defmodule LemonSkills.McpSourceContractTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config
  alias LemonSkills.McpSource

  setup do
    previous_app = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_env = System.get_env("LEMON_MCP_DISABLED")

    on_exit(fn ->
      restore_app_env(:mcp_disabled, previous_app)
      restore_system_env("LEMON_MCP_DISABLED", previous_env)
    end)

    :ok
  end

  test "accepts supported stdio, HTTP, and SSE configurations" do
    valid_configs = [
      {:stdio, "npx", ["-y", "server"]},
      {:stdio, "npx", ["server"],
       allow_tools: ["echo"],
       block_resources: ["secret://*"],
       ready_timeout_ms: 1_000,
       timeout_ms: 2_000,
       sampling_policy: [
         mode: :reviewed_model,
         reviewer: :ops_approval,
         max_tokens: 100,
         allowed_models: ["small"],
         approval_timeout_ms: 500
       ]},
      {:http, "http://localhost:3000/mcp"},
      {:sse, "https://example.test/events"},
      {:http, "https://example.test/mcp",
       headers: [{"X-Test", "value"}],
       persist_oauth_tokens: true,
       oauth_token_secret: "mcp_token",
       oauth: [
         client_id: "client",
         client_secret: "secret",
         scopes: ["tools"],
         authorization_timeout_ms: 5_000,
         token_auth_method: :client_secret_basic
       ]},
      {:http, "https://example.test/mcp",
       oauth: [
         flow: :authorization_code_pkce,
         client_id: "public-client",
         redirect_uri: "http://127.0.0.1/callback",
         scope: "tools"
       ]}
    ]

    Enum.each(valid_configs, &assert_validation_parity(&1, :ok))
  end

  test "rejects invalid base transport values" do
    assert_validation_parity(
      {:stdio, "  ", []},
      {:error, "stdio command cannot be empty"}
    )

    assert_validation_parity(
      {:http, "ftp://example.test/mcp"},
      {:error, "invalid HTTP URL: ftp://example.test/mcp"}
    )

    assert_validation_parity(
      {:unknown, "value"},
      {:error, ~s(invalid MCP server config: {:unknown, "value"})}
    )
  end

  test "rejects malformed filters, timeouts, and sampling policies" do
    invalid_cases = [
      {[allow_tools: [:echo]], "allow_tools must be a list of strings"},
      {[ready_timeout_ms: 0], "ready_timeout_ms must be a positive integer"},
      {[timeout_ms: "slow"], "timeout_ms must be a positive integer"},
      {[sampling_policy: :deny], "sampling_policy must be a keyword list"},
      {[sampling_policy: [mode: :unknown]],
       "sampling_policy.mode must be model, reviewed_model, or deny"},
      {[sampling_policy: [reviewer: :unknown]],
       "sampling_policy.reviewer must be a function or ops_approval"},
      {[sampling_policy: [max_tokens: 0]],
       "sampling_policy.max_tokens must be a positive integer"},
      {[sampling_policy: [allowed_models: [:small]]],
       "sampling_policy.allowed_models must be a list of strings"},
      {[sampling_policy: [approval_timeout_ms: 0]],
       "sampling_policy.approval_timeout_ms must be a positive integer"}
    ]

    Enum.each(invalid_cases, fn {opts, expected} ->
      Enum.each([:stdio, :http, :sse], fn transport ->
        assert_validation_parity(config_for(transport, opts), {:error, expected})
      end)
    end)
  end

  test "rejects malformed HTTP headers, persistence, and OAuth options" do
    invalid_cases = [
      {[headers: :invalid], "headers must be a list of string tuples"},
      {[headers: [{:atom, "value"}]], "headers must be a list of string tuples"},
      {[persist_oauth_tokens: "yes"], "persist_oauth_tokens must be a boolean"},
      {[oauth_token_secret: ""], "oauth_token_secret must be a non-empty string"},
      {[oauth: :invalid], "oauth must be a keyword list"},
      {[oauth: [client_id: "client"]], "oauth.client_secret must be a non-empty string"},
      {[oauth: [client_id: "client", client_secret_secret: ""]],
       "oauth.client_secret must be a non-empty string"},
      {[oauth: [client_id: "client", client_secret: "secret", token_secret: ""]],
       "oauth.token_secret must be a non-empty string"},
      {[oauth: [client_id: "client", client_secret: "secret", flow: :unknown]],
       "oauth.flow must be client_credentials or authorization_code_pkce"},
      {[oauth: [client_id: "client", client_secret: "secret", redirect_uri: 1]],
       "oauth.redirect_uri must be a string"},
      {[oauth: [client_id: "client", client_secret: "secret", scope: [:tools]]],
       "oauth.scope must be a string"},
      {[oauth: [client_id: "client", client_secret: "secret", scopes: [:tools]]],
       "oauth.scopes must be a list of strings"},
      {[oauth: [client_id: "client", client_secret: "secret", authorization_timeout_ms: 0]],
       "oauth.authorization_timeout_ms must be a positive integer"},
      {[oauth: [client_id: "client", client_secret: "secret", token_auth_method: :unknown]],
       "oauth.token_auth_method must be client_secret_post or client_secret_basic"}
    ]

    Enum.each(invalid_cases, fn {opts, expected} ->
      Enum.each([:http, :sse], fn transport ->
        assert_validation_parity(config_for(transport, opts), {:error, expected})
      end)
    end)
  end

  test "explicit application and environment settings disable MCP" do
    Application.put_env(:lemon_skills, :mcp_disabled, true)
    System.delete_env("LEMON_MCP_DISABLED")
    refute McpSource.mcp_enabled?()

    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.put_env("LEMON_MCP_DISABLED", "YES")
    refute McpSource.mcp_enabled?()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:lemon_skills, key)
  defp restore_app_env(key, value), do: Application.put_env(:lemon_skills, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp config_for(:stdio, opts), do: {:stdio, "server", [], opts}
  defp config_for(transport, opts), do: {transport, "https://example.test/mcp", opts}

  defp assert_validation_parity(config, :ok) do
    assert :ok = McpSource.validate_config(config)
    assert {:ok, [^config]} = Config.validate_mcp_servers([config])
  end

  defp assert_validation_parity(config, {:error, reason} = expected) do
    assert McpSource.validate_config(config) == expected
    assert Config.validate_mcp_servers([config]) == {:error, [{:invalid, config, reason}]}
  end
end
