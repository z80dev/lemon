defmodule LemonSkills.Tools.XSearchTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias LemonChannels.Adapters.XAPI
  alias LemonSkills.Tools.XSearch

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
    previous = Application.get_env(:lemon_channels, XAPI)
    previous_use_secrets = Application.get_env(:lemon_channels, :x_api_use_secrets)
    previous_env = Map.new(@x_env_vars, fn key -> {key, System.get_env(key)} end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Application.delete_env(:lemon_channels, XAPI)
    Application.put_env(:lemon_channels, :x_api_use_secrets, false)
    Enum.each(@x_env_vars, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_channels, XAPI)
      else
        Application.put_env(:lemon_channels, XAPI, previous)
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

      Req.default_options(previous_req_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "tool exposes Hermes-compatible x_search shape" do
    tool = XSearch.tool()

    assert tool.name == "x_search"
    assert tool.description =~ "Search recent public posts on X"
    assert tool.description =~ "read-only"
    assert tool.parameters["required"] == ["query"]
    assert Map.has_key?(tool.parameters["properties"], "next_token")
  end

  test "returns not configured error when X search is unavailable" do
    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{error: :not_configured}
           } = XSearch.execute("call-1", %{"query" => "lemon"}, nil, nil)

    assert text =~ "X search is not configured"
  end

  test "validates query parameter" do
    assert %AgentToolResult{details: %{error: "Missing required parameter: query"}} =
             XSearch.execute("call-2", %{}, nil, nil)

    assert %AgentToolResult{details: %{error: "Parameter 'query' cannot be empty"}} =
             XSearch.execute("call-3", %{"query" => "  "}, nil, nil)

    assert %AgentToolResult{details: %{error: "Parameter 'query' must be a string"}} =
             XSearch.execute("call-4", %{"query" => 123}, nil, nil)
  end

  test "validates optional parameters" do
    assert %AgentToolResult{
             details: %{error: "Parameter 'limit' must be a positive integer"}
           } = XSearch.execute("call-5", %{"query" => "lemon", "limit" => "bad"}, nil, nil)

    assert %AgentToolResult{
             details: %{error: "Parameter 'sort_order' must be recency or relevancy"}
           } =
             XSearch.execute(
               "call-6",
               %{"query" => "lemon", "sort_order" => "popular"},
               nil,
               nil
             )

    assert %AgentToolResult{details: %{error: "Parameter 'since_id' must be a string"}} =
             XSearch.execute("call-7", %{"query" => "lemon", "since_id" => 123}, nil, nil)
  end

  test "searches X with bearer token and formats posts" do
    Application.put_env(:lemon_channels, XAPI, bearer_token: "search-bearer-token")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => [
            %{
              "id" => "1860000000000000001",
              "author_id" => "42",
              "text" => "Lemon on BEAM",
              "created_at" => "2026-05-18T01:02:03.000Z",
              "public_metrics" => %{"like_count" => 7}
            }
          ],
          "includes" => %{
            "users" => [%{"id" => "42", "username" => "lemon_agent", "name" => "Lemon"}]
          },
          "meta" => %{"result_count" => 1, "next_token" => "next-page"}
        })
      )
    end)

    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{
               query: "lemon lang:en",
               count: 1,
               result_count: 1,
               next_token: "next-page",
               results: [result]
             }
           } =
             XSearch.execute(
               "call-8",
               %{
                 "query" => " lemon lang:en ",
                 "limit" => 2,
                 "sort_order" => "recency",
                 "next_token" => "cursor"
               },
               nil,
               nil
             )

    assert text =~ "Found 1 X post"
    assert text =~ "@lemon_agent"
    assert text =~ "Next token: next-page"
    assert result.text == "Lemon on BEAM"
    assert result.url == "https://x.com/lemon_agent/status/1860000000000000001"

    assert_receive {:req, "/2/tweets/search/recent", query}
    decoded = URI.decode_query(query)
    assert decoded["query"] == "lemon lang:en"
    assert decoded["max_results"] == "10"
    assert decoded["next_token"] == "cursor"
  end
end
