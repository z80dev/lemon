defmodule LemonSkills.Tools.PostToXTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias LemonSkills.Tools.PostToX

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
           } = PostToX.execute("call-1", %{"text" => "hello from test"}, nil, nil)

    assert text =~ "X API not configured"
  end

  test "validates missing both text and media_path parameters" do
    assert %AgentToolResult{
             details: %{error: "Either 'text' or 'media_path' must be provided"}
           } = PostToX.execute("call-2", %{}, nil, nil)
  end

  test "validates text parameter type" do
    assert %AgentToolResult{
             details: %{error: "Parameter 'text' must be a string"}
           } = PostToX.execute("call-3", %{"text" => 123}, nil, nil)
  end

  test "validates reply_to parameter type" do
    assert %AgentToolResult{
             details: %{error: "Parameter 'reply_to' must be a string"}
           } =
             PostToX.execute("call-4", %{"text" => "hello", "reply_to" => 12345}, nil, nil)
  end

  test "validates media_path parameter type" do
    assert %AgentToolResult{
             details: %{error: "Parameter 'media_path' must be a string"}
           } =
             PostToX.execute("call-5", %{"text" => "hello", "media_path" => 12345}, nil, nil)
  end

  test "allows media_path without text" do
    # When media_path is provided without text, it should pass validation
    # but fail with not_configured since X API is not set up in test
    assert %AgentToolResult{
             details: %{error: :not_configured}
           } = PostToX.execute("call-6", %{"media_path" => "/path/to/image.png"}, nil, nil)
  end
end
