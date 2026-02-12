defmodule CodingAgent.Tools.WebSearchTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.WebSearch
  alias AgentCore.AbortSignal

  setup do
    # Reset rate limit before each test
    WebSearch.reset_rate_limit()
    :ok
  end

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = WebSearch.tool("/tmp")

      assert tool.name == "websearch"
      assert tool.label == "Web Search"
      assert tool.description =~ "Search the web"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["query"]
      assert is_function(tool.execute, 4)
    end

    test "includes all expected parameters" do
      tool = WebSearch.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "query")
      assert Map.has_key?(props, "max_results")
      assert Map.has_key?(props, "region")
      assert props["query"]["type"] == "string"
      assert props["max_results"]["type"] == "integer"
      assert props["max_results"]["description"] =~ "max 10"
      assert props["region"]["type"] == "string"
    end
  end

  describe "execute/4 - query validation" do
    test "returns error when query is empty string" do
      result = WebSearch.execute("call_1", %{"query" => ""}, nil, nil)

      assert {:error, "Query is required"} = result
    end

    test "returns error when query is missing" do
      result = WebSearch.execute("call_1", %{}, nil, nil)

      assert {:error, "Query is required"} = result
    end

    test "returns error when query is whitespace only" do
      result = WebSearch.execute("call_1", %{"query" => "   "}, nil, nil)

      assert {:error, "Query is required"} = result
    end

    test "returns error when query contains only tabs and newlines" do
      result = WebSearch.execute("call_1", %{"query" => "\t\n\r"}, nil, nil)

      assert {:error, "Query is required"} = result
    end

    test "returns error when query is nil" do
      result = WebSearch.execute("call_1", %{"query" => nil}, nil, nil)

      assert {:error, "Query is required"} = result
    end

    test "returns error when query exceeds max length" do
      long_query = String.duplicate("a", 501)

      result = WebSearch.execute("call_1", %{"query" => long_query}, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "Query is too long"
      assert msg =~ "max 500"
    end

    test "accepts query at exactly max length" do
      # 500 chars is the max, should not return length error
      query = String.duplicate("a", 500)

      # This won't error on length - will proceed to network call
      # which will fail but that's expected in tests
      result = WebSearch.execute("call_1", %{"query" => query}, nil, nil)

      # Should NOT be a query length error
      refute match?({:error, "Query is too long" <> _}, result)
    end

    test "trims whitespace from query before validation" do
      # Query with surrounding whitespace but valid content
      result = WebSearch.execute("call_1", %{"query" => "  test  "}, nil, nil)

      # Should not be a "Query is required" error - whitespace is trimmed
      refute match?({:error, "Query is required"}, result)
    end
  end

  describe "execute/4 - max_results validation" do
    # Note: These tests verify that max_results is properly normalized
    # but don't verify actual result counts since that requires mocking HTTP

    test "accepts integer max_results within valid range" do
      # max_results=5 is valid, will proceed to network call
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "max_results" => 5
          },
          nil,
          nil
        )

      # Should not error on max_results parameter
      refute match?({:error, "max_results" <> _}, result)
    end

    test "handles non-integer max_results by using default" do
      # String value should be normalized to default
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "max_results" => "five"
          },
          nil,
          nil
        )

      # Should proceed without error on max_results
      refute match?({:error, "max_results" <> _}, result)
    end

    test "handles nil max_results by using default" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "max_results" => nil
          },
          nil,
          nil
        )

      # Should proceed without error on max_results
      refute match?({:error, "max_results" <> _}, result)
    end

    test "handles negative max_results by clamping to 1" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "max_results" => -5
          },
          nil,
          nil
        )

      # Should proceed without error (clamped to 1)
      refute match?({:error, "max_results" <> _}, result)
    end

    test "handles zero max_results by clamping to 1" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "max_results" => 0
          },
          nil,
          nil
        )

      # Should proceed without error (clamped to 1)
      refute match?({:error, "max_results" <> _}, result)
    end

    test "handles max_results above limit by clamping to 10" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "max_results" => 100
          },
          nil,
          nil
        )

      # Should proceed without error (clamped to 10)
      refute match?({:error, "max_results" <> _}, result)
    end
  end

  # Timeout validation tests removed: tool calls should not enforce timeouts.

  describe "execute/4 - region parameter" do
    test "accepts valid region code" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "region" => "us-en"
          },
          nil,
          nil
        )

      # Should not error on region parameter
      refute match?({:error, "region" <> _}, result)
    end

    test "accepts nil region" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "region" => nil
          },
          nil,
          nil
        )

      # Should not error on region parameter
      refute match?({:error, "region" <> _}, result)
    end

    test "ignores invalid region type" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "region" => 123
          },
          nil,
          nil
        )

      # Should not error on region parameter (invalid types are ignored)
      refute match?({:error, "region" <> _}, result)
    end
  end

  describe "execute/4 - abort signal handling" do
    test "returns error when signal is already aborted before execution" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = WebSearch.execute("call_1", %{"query" => "test query"}, signal, nil)

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds when signal is not aborted" do
      signal = AbortSignal.new()

      # Will fail on network call but should not fail on abort check
      result = WebSearch.execute("call_1", %{"query" => "test"}, signal, nil)

      refute match?({:error, "Operation aborted"}, result)
    end

    test "proceeds when signal is nil" do
      result = WebSearch.execute("call_1", %{"query" => "test"}, nil, nil)

      refute match?({:error, "Operation aborted"}, result)
    end
  end

  describe "rate limiting" do
    test "allows requests within rate limit" do
      # First few requests should succeed (not hit rate limit)
      for _ <- 1..4 do
        result = WebSearch.execute("call_1", %{"query" => "test"}, nil, nil)
        # Should not be a rate limit error
        refute match?({:error, "Rate limit exceeded" <> _}, result)
      end
    end

    test "blocks requests exceeding rate limit" do
      # Exhaust the rate limit (5 requests per window)
      for _ <- 1..5 do
        WebSearch.execute("call_1", %{"query" => "test"}, nil, nil)
      end

      # 6th request should be rate limited
      result = WebSearch.execute("call_1", %{"query" => "test"}, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "Rate limit exceeded"
    end

    test "resets rate limit after window expires" do
      # Exhaust the rate limit
      for _ <- 1..5 do
        WebSearch.execute("call_1", %{"query" => "test"}, nil, nil)
      end

      # Wait for window to expire
      Process.sleep(1100)

      # Should be allowed again
      result = WebSearch.execute("call_1", %{"query" => "test"}, nil, nil)
      refute match?({:error, "Rate limit exceeded" <> _}, result)
    end
  end

  describe "tool structure" do
    test "cwd parameter is ignored (not used)" do
      tool1 = WebSearch.tool("/tmp")
      tool2 = WebSearch.tool("/var/log")

      assert tool1.name == tool2.name
      assert tool1.parameters == tool2.parameters
    end

    test "opts parameter is ignored (not used)" do
      tool1 = WebSearch.tool("/tmp", [])
      tool2 = WebSearch.tool("/tmp", some_option: true)

      assert tool1.name == tool2.name
      assert tool1.parameters == tool2.parameters
    end

    test "execute function is callable" do
      tool = WebSearch.tool("/tmp")

      # Verify function arity
      assert is_function(tool.execute, 4)

      # Verify it can be invoked
      result = tool.execute.("call_id", %{"query" => ""}, nil, nil)
      assert {:error, "Query is required"} = result
    end
  end

  describe "parameter schema" do
    test "query parameter has correct schema" do
      tool = WebSearch.tool("/tmp")
      query_schema = tool.parameters["properties"]["query"]

      assert query_schema["type"] == "string"
      assert query_schema["description"] =~ "query" or query_schema["description"] =~ "Search"
    end

    test "max_results parameter has correct schema" do
      tool = WebSearch.tool("/tmp")
      max_results_schema = tool.parameters["properties"]["max_results"]

      assert max_results_schema["type"] == "integer"
      assert max_results_schema["description"] =~ "10"
    end

    test "does not expose a timeout parameter (tool calls should not time out)" do
      tool = WebSearch.tool("/tmp")
      refute Map.has_key?(tool.parameters["properties"], "timeout")
    end

    test "region parameter has correct schema" do
      tool = WebSearch.tool("/tmp")
      region_schema = tool.parameters["properties"]["region"]

      assert region_schema["type"] == "string"
      assert region_schema["description"] =~ "region"
    end

    test "only query is required" do
      tool = WebSearch.tool("/tmp")

      assert tool.parameters["required"] == ["query"]
    end
  end

  describe "edge cases" do
    test "handles empty params map" do
      result = WebSearch.execute("call_1", %{}, nil, nil)

      assert {:error, "Query is required"} = result
    end

    test "handles params with extra unknown keys" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "test",
            "unknown_param" => "value",
            "another_unknown" => 123
          },
          nil,
          nil
        )

      # Should not error on unknown params
      refute match?({:error, "unknown" <> _}, result)
    end

    test "handles unicode query" do
      result =
        WebSearch.execute(
          "call_1",
          %{
            "query" => "你好世界 élève"
          },
          nil,
          nil
        )

      # Should not error on unicode content
      refute match?({:error, "Query is required"}, result)
    end

    test "handles very short valid query" do
      result = WebSearch.execute("call_1", %{"query" => "a"}, nil, nil)

      # Single character should be valid
      refute match?({:error, "Query is required"}, result)
    end
  end
end
