defmodule CodingAgent.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.WebFetch
  alias AgentCore.AbortSignal

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = WebFetch.tool("/tmp")

      assert tool.name == "webfetch"
      assert tool.label == "Web Fetch"
      assert tool.description =~ "Fetch content"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["url", "format"]
      assert is_function(tool.execute, 4)
    end

    test "includes all expected parameters" do
      tool = WebFetch.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "url")
      assert Map.has_key?(props, "format")
      assert Map.has_key?(props, "timeout")
      assert props["format"]["enum"] == ["text", "markdown", "html"]
    end
  end

  describe "execute/4 - URL validation" do
    test "rejects URLs without protocol" do
      result = WebFetch.execute("call_1", %{
        "url" => "example.com",
        "format" => "text"
      }, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects FTP URLs" do
      result = WebFetch.execute("call_1", %{
        "url" => "ftp://example.com/file",
        "format" => "text"
      }, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects file:// URLs" do
      result = WebFetch.execute("call_1", %{
        "url" => "file:///etc/passwd",
        "format" => "text"
      }, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end
  end

  describe "execute/4 - format validation" do
    test "rejects invalid format" do
      result = WebFetch.execute("call_1", %{
        "url" => "https://example.com",
        "format" => "json"
      }, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  describe "execute/4 - timeout validation" do
    test "rejects non-integer timeout" do
      result = WebFetch.execute("call_1", %{
        "url" => "https://example.com",
        "format" => "text",
        "timeout" => 1.5
      }, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "timeout must be an integer"
    end

    test "rejects non-positive timeout" do
      result = WebFetch.execute("call_1", %{
        "url" => "https://example.com",
        "format" => "text",
        "timeout" => 0
      }, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "timeout must be a positive integer"
    end
  end

  describe "execute/4 - abort signal handling" do
    test "returns error when signal is aborted" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = WebFetch.execute("call_1", %{
        "url" => "https://example.com",
        "format" => "text"
      }, signal, nil)

      assert {:error, "Operation aborted"} = result
    end
  end

  # Note: The following tests would require mocking HTTP requests in a real test suite.
  # For now, we test the validation and structure aspects that don't require network access.

  describe "tool structure" do
    test "cwd parameter is ignored (not used)" do
      tool1 = WebFetch.tool("/tmp")
      tool2 = WebFetch.tool("/var/log")

      # Tool definition should be the same regardless of cwd
      assert tool1.name == tool2.name
      assert tool1.parameters == tool2.parameters
    end

    test "opts parameter is ignored (not used)" do
      tool1 = WebFetch.tool("/tmp", [])
      tool2 = WebFetch.tool("/tmp", [some_option: true])

      assert tool1.name == tool2.name
      assert tool1.parameters == tool2.parameters
    end
  end
end
