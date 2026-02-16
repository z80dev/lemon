defmodule CodingAgent.Tools.BrowserTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools.Browser

  @moduletag :tmp_dir
  @server_key {__MODULE__, :server_request}

  defmodule BrowserServerStub do
    @server_key {CodingAgent.Tools.BrowserTest, :server_request}

    def request(method, args, timeout_ms) do
      case Process.get(@server_key) do
        request_fun when is_function(request_fun, 3) ->
          request_fun.(method, args, timeout_ms)

        _ ->
          {:error, :missing_browser_server_stub}
      end
    end
  end

  setup do
    on_exit(fn -> Process.delete(@server_key) end)
    :ok
  end

  test "marks browser results as untrusted and includes trust metadata", %{tmp_dir: tmp_dir} do
    Process.put(@server_key, fn method, args, timeout_ms ->
      assert method == "browser.navigate"
      assert args == %{"url" => "https://example.com"}
      assert timeout_ms == 30_000

      {:ok, %{"url" => "https://example.com", "status" => 200, "title" => "Example Domain"}}
    end)

    tool = Browser.tool(tmp_dir, browser_server: BrowserServerStub)

    result =
      tool.execute.(
        "call_1",
        %{"method" => "navigate", "args" => %{"url" => "https://example.com"}},
        nil,
        nil
      )

    assert %AgentToolResult{} = result
    assert result.trust == :untrusted

    payload = decode_payload(result)

    assert payload["ok"] == true
    assert payload["result"]["title"] == "Example Domain"
    assert payload["trustMetadata"]["untrusted"] == true
    assert payload["trustMetadata"]["source"] == "browser"
    assert payload["trustMetadata"]["sourceLabel"] == "Browser"
    assert payload["trustMetadata"]["wrappingApplied"] == true
    assert payload["trustMetadata"]["warningIncluded"] == false
    assert payload["trustMetadata"]["wrappedFields"] == ["result"]
    assert payload["trust_metadata"]["untrusted"] == true
    assert payload["trust_metadata"]["source"] == "browser"
    assert payload["trust_metadata"]["source_label"] == "Browser"
    assert payload["trust_metadata"]["wrapped_fields"] == ["result"]
  end

  test "marks getContent html payloads as untrusted and preserves truncation fields", %{
    tmp_dir: tmp_dir
  } do
    html = "<html><body>" <> String.duplicate("x", 40) <> "</body></html>"

    Process.put(@server_key, fn method, args, timeout_ms ->
      assert method == "browser.getContent"
      assert args == %{"maxChars" => 10}
      assert timeout_ms == 30_000

      {:ok, %{"html" => html}}
    end)

    tool = Browser.tool(tmp_dir, browser_server: BrowserServerStub)

    result =
      tool.execute.(
        "call_2",
        %{"method" => "getContent", "args" => %{"maxChars" => 10}},
        nil,
        nil
      )

    assert %AgentToolResult{} = result
    assert result.trust == :untrusted

    payload = decode_payload(result)

    assert payload["ok"] == true
    assert payload["result"]["html"] == String.slice(html, 0, 10) <> "..."
    assert payload["result"]["truncated"] == true
    assert payload["result"]["originalChars"] == String.length(html)
    assert payload["trustMetadata"]["wrappedFields"] == ["result.html"]
    assert payload["trust_metadata"]["wrapped_fields"] == ["result.html"]
  end

  test "marks screenshot payloads as untrusted and keeps screenshot details", %{tmp_dir: tmp_dir} do
    png = <<0x89, 0x50, 0x4E, 0x47>>

    Process.put(@server_key, fn method, args, timeout_ms ->
      assert method == "browser.screenshot"
      assert args == %{"url" => "https://example.com/screenshot"}
      assert timeout_ms == 30_000

      {:ok, %{"contentType" => "image/png", "base64" => Base.encode64(png)}}
    end)

    tool = Browser.tool(tmp_dir, browser_server: BrowserServerStub)

    result =
      tool.execute.(
        "call_3",
        %{"method" => "screenshot", "args" => %{"url" => "https://example.com/screenshot"}},
        nil,
        nil
      )

    assert %AgentToolResult{} = result
    assert result.trust == :untrusted

    payload = decode_payload(result)
    out = payload["result"]

    assert payload["ok"] == true
    assert payload["trustMetadata"]["untrusted"] == true
    assert payload["trustMetadata"]["wrappedFields"] == ["result"]
    assert payload["trust_metadata"]["wrapped_fields"] == ["result"]
    assert out["contentType"] == "image/png"
    assert out["bytes"] == byte_size(png)
    assert is_binary(out["path"])
    assert File.read!(Path.join(tmp_dir, out["path"])) == png

    assert [%{path: path, caption: caption}] = result.details.auto_send_files
    assert path == out["path"]
    assert caption == "Browser screenshot (https://example.com/screenshot)"
    assert result.details.screenshot == out
  end

  defp decode_payload(result) do
    [content] = result.content
    Jason.decode!(content.text)
  end
end
