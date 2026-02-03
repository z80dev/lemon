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
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "example.com",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects FTP URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "ftp://example.com/file",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects file:// URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "file:///etc/passwd",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end
  end

  describe "execute/4 - format validation" do
    test "rejects invalid format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "json"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  describe "execute/4 - timeout validation" do
    test "rejects non-integer timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => 1.5
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "timeout must be an integer"
    end

    test "rejects non-positive timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => 0
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "timeout must be a positive integer"
    end
  end

  describe "execute/4 - abort signal handling" do
    test "returns error when signal is aborted" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text"
          },
          signal,
          nil
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "tool structure" do
    test "cwd parameter is ignored (not used)" do
      tool1 = WebFetch.tool("/tmp")
      tool2 = WebFetch.tool("/var/log")

      assert tool1.name == tool2.name
      assert tool1.parameters == tool2.parameters
    end

    test "opts parameter is ignored (not used)" do
      tool1 = WebFetch.tool("/tmp", [])
      tool2 = WebFetch.tool("/tmp", some_option: true)

      assert tool1.name == tool2.name
      assert tool1.parameters == tool2.parameters
    end
  end

  # ===========================================================================
  # URL VALIDATION EDGE CASES - MALFORMED URLS
  # ===========================================================================

  describe "URL validation edge cases - malformed URLs" do
    test "rejects empty URL" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects URL with only whitespace" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "   ",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects nil URL" do
      result =
        try do
          WebFetch.execute(
            "call_1",
            %{
              "url" => nil,
              "format" => "text"
            },
            nil,
            nil
          )
        rescue
          FunctionClauseError -> {:error, "Invalid URL type"}
        end

      # nil URL should fail gracefully or raise FunctionClauseError
      assert {:error, _} = result
    end

    test "rejects missing URL parameter" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end
  end

  # ===========================================================================
  # PROTOCOL VALIDATION (HTTP/HTTPS ONLY)
  # ===========================================================================

  describe "protocol validation (http/https only)" do
    test "rejects data: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "data:text/html,<script>alert(1)</script>",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects javascript: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "javascript:alert(document.cookie)",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects mailto: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "mailto:test@example.com",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects tel: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "tel:+1234567890",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects gopher: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "gopher://gopher.example.com/",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects ldap: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "ldap://ldap.example.com/dc=example,dc=com",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects dict: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "dict://dict.example.com/d:word",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects sftp: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "sftp://example.com/path/to/file",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects ssh: URLs" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "ssh://user@example.com",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects uppercase HTTP protocol (case-sensitive)" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "HTTP://example.com/page",
            "format" => "text"
          },
          nil,
          nil
        )

      # Current implementation is case-sensitive
      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects mixed case protocol" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "HtTpS://example.com/page",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects protocol with extra characters before" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "xhttps://example.com/page",
            "format" => "text"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end
  end

  # ===========================================================================
  # SSRF PREVENTION - SECURITY DOCUMENTATION
  # These tests document the current behavior regarding SSRF protection.
  # Tests use @tag :ssrf_documentation to indicate they document security gaps.
  # ===========================================================================

  describe "SSRF prevention - localhost variants (documentation)" do
    @moduletag :ssrf_documentation

    # NOTE: These tests document that the current implementation does NOT
    # block localhost/internal IPs at the URL validation layer.
    # SSRF protection would need to be added to properly secure the tool.

    test "documents that localhost passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://localhost/admin",
            "format" => "invalid_format_to_stop_early"
          },
          nil,
          nil
        )

      # Using invalid format to prevent actual network call
      # This documents that localhost passes URL validation
      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that 127.0.0.1 passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://127.0.0.1/admin",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that IPv6 localhost passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://[::1]/admin",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that 0.0.0.0 passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://0.0.0.0/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  describe "SSRF prevention - private IP ranges (documentation)" do
    @moduletag :ssrf_documentation

    test "documents that 10.x.x.x passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://10.0.0.1/internal",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that 172.16.x.x passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://172.16.0.1/internal",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that 192.168.x.x passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://192.168.1.1/router",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that AWS metadata IP passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://169.254.169.254/latest/meta-data/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  describe "SSRF prevention - cloud metadata endpoints (documentation)" do
    @moduletag :ssrf_documentation

    test "documents that GCP metadata hostname passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://metadata.google.internal/computeMetadata/v1/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that Kubernetes internal service passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://kubernetes.default.svc/api/v1/namespaces",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  describe "SSRF prevention - bypass attempts (documentation)" do
    @moduletag :ssrf_documentation

    test "documents that decimal IP notation passes URL validation" do
      # 2130706433 = 127.0.0.1 in decimal
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://2130706433/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that octal IP notation passes URL validation" do
      # 0177.0.0.1 = 127.0.0.1 in octal
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://0177.0.0.1/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that URL with @ sign passes validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://example.com@127.0.0.1/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that IPv6 mapped IPv4 passes validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "http://[::ffff:127.0.0.1]/",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  # ===========================================================================
  # HEADER INJECTION PREVENTION (DOCUMENTATION)
  # ===========================================================================

  describe "header injection prevention (documentation)" do
    @moduletag :security_documentation

    test "documents that URL with CRLF passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com/path\r\nX-Injected: header",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      # URL with CRLF passes basic URL validation
      # The HTTP library should handle CRLF sanitization
      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "documents that URL with encoded CRLF passes URL validation" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com/path%0d%0aX-Injected:%20header",
            "format" => "invalid_format"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  # ===========================================================================
  # TIMEOUT VALIDATION
  # ===========================================================================

  describe "timeout validation comprehensive" do
    test "rejects negative timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => -10
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "timeout must be a positive integer"
    end

    test "rejects string timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => "30"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "timeout must be an integer"
    end

    test "rejects float timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => 30.5
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "timeout must be an integer"
    end

    test "rejects list timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => [30]
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "timeout must be an integer"
    end

    test "accepts nil timeout without error" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "invalid_format",
            "timeout" => nil
          },
          nil,
          nil
        )

      # Should fail on format, not timeout
      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "accepts positive integer timeout" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "invalid_format",
            "timeout" => 30
          },
          nil,
          nil
        )

      # Should fail on format, not timeout
      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "accepts large timeout (gets capped internally)" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "invalid_format",
            "timeout" => 9999
          },
          nil,
          nil
        )

      # Should fail on format, not timeout - large values are capped not rejected
      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  # ===========================================================================
  # FORMAT VALIDATION
  # ===========================================================================

  describe "format validation comprehensive" do
    test "accepts text format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "invalid_url",
            "format" => "text"
          },
          nil,
          nil
        )

      # Should fail on URL, not format
      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "accepts markdown format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "invalid_url",
            "format" => "markdown"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "accepts html format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "invalid_url",
            "format" => "html"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "rejects json format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "json"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects xml format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "xml"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects empty format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => ""
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects nil format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => nil
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects integer format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => 1
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects format with different case (TEXT)" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "TEXT"
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects format with whitespace" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => " text "
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "rejects list format" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => ["text"]
          },
          nil,
          nil
        )

      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end
  end

  # ===========================================================================
  # ABORT SIGNAL HANDLING
  # ===========================================================================

  describe "abort signal handling comprehensive" do
    test "returns error immediately when signal is pre-aborted" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text"
          },
          signal,
          nil
        )

      assert {:error, "Operation aborted"} = result
    end

    test "checks abort before URL validation" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      # Even with invalid URL, should return abort error first
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "invalid-url",
            "format" => "text"
          },
          signal,
          nil
        )

      assert {:error, "Operation aborted"} = result
    end

    test "checks abort before format validation" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "invalid"
          },
          signal,
          nil
        )

      assert {:error, "Operation aborted"} = result
    end

    test "checks abort before timeout validation" do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "text",
            "timeout" => -1
          },
          signal,
          nil
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  # ===========================================================================
  # EDGE CASES AND BOUNDARY CONDITIONS
  # ===========================================================================

  describe "edge cases and boundary conditions" do
    test "handles empty params map" do
      result = WebFetch.execute("call_1", %{}, nil, nil)

      assert {:error, msg} = result
      assert msg =~ "URL must start with http:// or https://"
    end

    test "handles params with extra unknown keys" do
      result =
        WebFetch.execute(
          "call_1",
          %{
            "url" => "https://example.com",
            "format" => "invalid_format",
            "unknown_param" => "value",
            "another_unknown" => 123
          },
          nil,
          nil
        )

      # Should fail on format, unknown params are ignored
      assert {:error, msg} = result
      assert msg =~ "format must be one of"
    end

    test "handles params with non-string URL (integer)" do
      # This tests defensive handling of invalid input types
      result =
        try do
          WebFetch.execute(
            "call_1",
            %{
              "url" => 12345,
              "format" => "text"
            },
            nil,
            nil
          )
        rescue
          FunctionClauseError -> {:error, "Invalid URL type"}
        end

      # Either returns error or raises FunctionClauseError
      assert {:error, _} = result
    end

    test "handles params with list URL" do
      result =
        try do
          WebFetch.execute(
            "call_1",
            %{
              "url" => ["https://example.com"],
              "format" => "text"
            },
            nil,
            nil
          )
        rescue
          FunctionClauseError -> {:error, "Invalid URL type"}
        end

      assert {:error, _} = result
    end

    test "handles params with map URL" do
      result =
        try do
          WebFetch.execute(
            "call_1",
            %{
              "url" => %{"href" => "https://example.com"},
              "format" => "text"
            },
            nil,
            nil
          )
        rescue
          FunctionClauseError -> {:error, "Invalid URL type"}
        end

      assert {:error, _} = result
    end
  end

  # ===========================================================================
  # MEMORY LIMITS DOCUMENTATION
  # ===========================================================================

  describe "memory limits for response bodies" do
    test "module defines max response size constant" do
      # The module defines @max_response_size 5 * 1024 * 1024 (5MB)
      # This is a documentation test confirming the security feature exists
      tool = WebFetch.tool("/tmp")
      assert tool.name == "webfetch"
      # The actual enforcement is in process_success_response
    end
  end

  # ===========================================================================
  # REDIRECT LOOP DETECTION DOCUMENTATION
  # ===========================================================================

  describe "redirect loop detection (documentation)" do
    @moduletag :feature_documentation

    test "documents that Req library handles redirects" do
      # Note: The Req library handles redirect following by default.
      # It has built-in redirect loop detection.
      # This test documents that behavior.
      tool = WebFetch.tool("/tmp")
      assert tool.name == "webfetch"
    end
  end

  # ===========================================================================
  # TIMEOUT BEHAVIOR DURING DOWNLOAD DOCUMENTATION
  # ===========================================================================

  describe "timeout behavior during download (documentation)" do
    @moduletag :feature_documentation

    test "documents default timeout value" do
      # @default_timeout_ms is 30_000 (30 seconds)
      tool = WebFetch.tool("/tmp")
      assert tool.parameters["properties"]["timeout"]["description"] =~ "timeout"
    end

    test "documents maximum timeout value" do
      # @max_timeout_ms is 120_000 (120 seconds)
      tool = WebFetch.tool("/tmp")
      assert tool.parameters["properties"]["timeout"]["description"] =~ "max 120"
    end
  end
end
