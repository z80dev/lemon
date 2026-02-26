defmodule CodingAgent.Tools.WebDownloadTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.WebDownload

  @moduletag :tmp_dir

  test "tool schema exposes url + optional path/maxBytes/overwrite", %{tmp_dir: tmp_dir} do
    tool = build_tool(tmp_dir)

    assert tool.name == "webdownload"
    assert tool.parameters["required"] == ["url"]
    assert Map.has_key?(tool.parameters["properties"], "url")
    assert Map.has_key?(tool.parameters["properties"], "path")
    assert Map.has_key?(tool.parameters["properties"], "maxBytes")
    assert Map.has_key?(tool.parameters["properties"], "overwrite")
  end

  test "returns disabled error when configured off", %{tmp_dir: tmp_dir} do
    tool =
      build_tool(tmp_dir,
        settings_manager: %{tools: %{web: %{download: %{enabled: false}}}}
      )

    assert {:error, "webdownload is disabled by configuration"} =
             tool.execute.("id", %{"url" => "https://example.com/file"}, nil, nil)
  end

  test "rejects invalid URL scheme", %{tmp_dir: tmp_dir} do
    tool = build_tool(tmp_dir)

    assert {:error, "Invalid URL: must be http or https"} =
             tool.execute.("id", %{"url" => "file:///etc/passwd"}, nil, nil)
  end

  test "blocks localhost SSRF targets", %{tmp_dir: tmp_dir} do
    tool = build_tool(tmp_dir)

    assert {:error, message} = tool.execute.("id", %{"url" => "http://localhost/admin"}, nil, nil)
    assert message =~ "Blocked hostname"
  end

  test "downloads binary to specified path and returns metadata", %{tmp_dir: tmp_dir} do
    data = <<0x89, 0x50, 0x4E, 0x47>>

    http_get = fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "image/png"}],
         body: data
       }}
    end

    tool = build_tool(tmp_dir, http_get: http_get)

    out = Path.join(tmp_dir, "out.png")

    result = tool.execute.("id", %{"url" => "https://8.8.8.8/file.png", "path" => out}, nil, nil)
    assert result.trust == :untrusted
    payload = decode_payload(result)

    assert payload["status"] == 200
    assert payload["contentType"] == "image/png"
    assert payload["path"] == out
    assert payload["bytes"] == byte_size(data)
    assert is_binary(payload["sha256"])
    assert payload["trustMetadata"]["untrusted"] == true
    assert payload["trustMetadata"]["source"] == "web_fetch"
    assert payload["trustMetadata"]["sourceLabel"] == "Web Fetch"
    assert payload["trustMetadata"]["wrappingApplied"] == true
    assert payload["trustMetadata"]["warningIncluded"] == false
    assert payload["trustMetadata"]["wrappedFields"] == []
    assert payload["trust_metadata"]["untrusted"] == true
    assert payload["trust_metadata"]["source"] == "web_fetch"
    assert payload["trust_metadata"]["source_label"] == "Web Fetch"
    assert payload["trust_metadata"]["wrapping_applied"] == true
    assert payload["trust_metadata"]["warning_included"] == false
    assert payload["trust_metadata"]["wrapped_fields"] == []
    assert File.read!(out) == data
  end

  test "generates a default path when path is omitted", %{tmp_dir: tmp_dir} do
    data = "hello"

    http_get = fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "text/plain"}],
         body: data
       }}
    end

    tool = build_tool(tmp_dir, http_get: http_get)

    result = tool.execute.("id", %{"url" => "https://8.8.8.8/hello"}, nil, nil)
    assert result.trust == :untrusted
    payload = decode_payload(result)

    assert payload["status"] == 200
    assert payload["bytes"] == byte_size(data)
    assert String.contains?(payload["path"], Path.join(tmp_dir, "downloads"))
    assert File.read!(payload["path"]) == data
  end

  test "rejects downloads that exceed maxBytes", %{tmp_dir: tmp_dir} do
    data = :crypto.strong_rand_bytes(2048)

    http_get = fn _url, _opts ->
      {:ok, %Req.Response{status: 200, headers: [], body: data}}
    end

    tool = build_tool(tmp_dir, http_get: http_get)

    assert {:error, message} =
             tool.execute.(
               "id",
               %{"url" => "https://8.8.8.8/blob", "maxBytes" => 1024},
               nil,
               nil
             )

    assert message =~ "exceeds maxBytes"
  end

  defp decode_payload(result) do
    [content] = result.content
    Jason.decode!(content.text)
  end

  defp build_tool(cwd, opts \\ []) do
    WebDownload.tool(cwd, opts)
  end
end
