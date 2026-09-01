defmodule XApi.Tools.GetXMentionsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias XApi
  alias XApi.TokenManager
  alias XApi.Tools.GetXMentions

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
    previous_req_defaults = Req.default_options()
    previous = Application.get_env(:x_api, XApi)
    previous_use_secrets = Application.get_env(:x_api, :use_secrets)
    previous_env = Map.new(@x_env_vars, fn key -> {key, System.get_env(key)} end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Application.delete_env(:x_api, XApi)
    Application.put_env(:x_api, :use_secrets, false)
    Enum.each(@x_env_vars, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:x_api, XApi)
      else
        Application.put_env(:x_api, XApi, previous)
      end

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          System.delete_env(key)
        else
          System.put_env(key, value)
        end
      end)

      if is_nil(previous_use_secrets) do
        Application.delete_env(:x_api, :use_secrets)
      else
        Application.put_env(:x_api, :use_secrets, previous_use_secrets)
      end

      Req.default_options(previous_req_defaults)
      Req.Test.set_req_test_to_private(%{})
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

  test "formats mentions with included user metadata" do
    configure_oauth2(default_account_id: "2022351619589873664")
    start_token_manager!()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path})

      case conn.request_path do
        "/2/oauth2/token" ->
          oauth_refresh_response(conn)

        "/2/users/2022351619589873664/mentions" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "data" => [
                %{
                  "id" => "1860000000000000001",
                  "author_id" => "42",
                  "text" => "Hey @lemon_agent",
                  "created_at" => "2026-05-18T01:02:03.000Z"
                }
              ],
              "includes" => %{
                "users" => [%{"id" => "42", "username" => "fan42", "name" => "Fan 42"}]
              },
              "meta" => %{"result_count" => 1}
            })
          )

        unexpected ->
          flunk("unexpected request path: #{unexpected}")
      end
    end)

    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{count: 1, mentions: [mention]}
           } = GetXMentions.execute("call-4", %{"limit" => 5}, nil, nil)

    assert text =~ "Found 1 recent mention"
    assert text =~ "@fan42 (Fan 42)"
    assert text =~ "Hey @lemon_agent"
    assert mention.id == "1860000000000000001"
    assert mention.author_id == "42"
    assert mention.author_username == "fan42"
    assert mention.author_name == "Fan 42"

    assert_receive {:req, "/2/users/2022351619589873664/mentions"}
  end

  test "formats mentions without includes by falling back to author_id" do
    configure_oauth2(default_account_id: "2022351619589873664")
    start_token_manager!()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path})

      case conn.request_path do
        "/2/oauth2/token" ->
          oauth_refresh_response(conn)

        "/2/users/2022351619589873664/mentions" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{
              "data" => [
                %{
                  "id" => "1860000000000000002",
                  "author_id" => "99",
                  "text" => "Ping",
                  "created_at" => "2026-05-18T02:02:03.000Z"
                }
              ],
              "meta" => %{"result_count" => 1}
            })
          )

        unexpected ->
          flunk("unexpected request path: #{unexpected}")
      end
    end)

    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{count: 1, mentions: [mention]}
           } = GetXMentions.execute("call-5", %{"limit" => 5}, nil, nil)

    assert text =~ "@99 (99)"
    assert mention.author_id == "99"
    assert is_nil(mention.author_username)
    assert is_nil(mention.author_name)
  end

  defp configure_oauth2(overrides) do
    config =
      Keyword.merge(
        [
          client_id: "client-id",
          client_secret: "client-secret",
          access_token: "access-token",
          refresh_token: "refresh-token",
          token_expires_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
        ],
        overrides
      )

    Application.put_env(:x_api, XApi, config)
  end

  defp start_token_manager! do
    case Process.whereis(TokenManager) do
      pid when is_pid(pid) ->
        GenServer.stop(pid)

      _ ->
        :ok
    end

    case start_supervised({TokenManager, []}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp oauth_refresh_response(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "refreshed-access-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 3600
      })
    )
  end
end
