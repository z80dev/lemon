defmodule LemonSkills.Tools.GetXMentionsTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias LemonSkills.Tools.GetXMentions

  @x_env_vars [
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_TOKEN_EXPIRES_AT",
    "X_DEFAULT_ACCOUNT_ID",
    "X_DEFAULT_ACCOUNT_USERNAME",
    "X_API_CONSUMER_KEY",
    "X_API_CONSUMER_SECRET",
    "X_API_ACCESS_TOKEN_SECRET"
  ]

  setup do
    previous = Application.get_env(:lemon_channels, LemonChannels.Adapters.XAPI)
    previous_use_secrets = Application.get_env(:lemon_channels, :x_api_use_secrets)
    previous_env = Map.new(@x_env_vars, fn key -> {key, System.get_env(key)} end)

    Application.delete_env(:lemon_channels, LemonChannels.Adapters.XAPI)
    Application.put_env(:lemon_channels, :x_api_use_secrets, false)
    Enum.each(@x_env_vars, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_channels, LemonChannels.Adapters.XAPI)
      else
        Application.put_env(:lemon_channels, LemonChannels.Adapters.XAPI, previous)
      end

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          System.delete_env(key)
        else
          System.put_env(key, value)
        end
      end)

      if is_nil(previous_use_secrets) do
        Application.delete_env(:lemon_channels, :x_api_use_secrets)
      else
        Application.put_env(:lemon_channels, :x_api_use_secrets, previous_use_secrets)
      end
    end)

    :ok
  end

  test "returns not configured error when X API is unavailable" do
    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{error: :not_configured}
           } = GetXMentions.execute("call-1", %{}, nil, nil)

    assert text =~ "X API not configured"
  end

  test "validates limit parameter type" do
    assert %AgentToolResult{
             details: %{error: "Parameter 'limit' must be a positive integer"}
           } = GetXMentions.execute("call-2", %{"limit" => "abc"}, nil, nil)
  end

  test "validates limit parameter value" do
    assert %AgentToolResult{
             details: %{error: "Parameter 'limit' must be a positive integer"}
           } = GetXMentions.execute("call-3", %{"limit" => 0}, nil, nil)
  end
end
