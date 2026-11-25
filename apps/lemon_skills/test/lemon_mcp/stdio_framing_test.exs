defmodule LemonMCP.StdioFramingTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Framing.Stdio
  alias LemonMCP.Protocol

  test "encodes protocol structs and response maps with exactly one newline" do
    request = Protocol.tool_list_request(id: "request")
    assert {:ok, bytes} = Stdio.encode(request)
    assert String.ends_with?(bytes, "\n")
    refute String.ends_with?(bytes, "\n\n")
    assert {:ok, [%{"id" => "request", "method" => "tools/list"}], ""} = Stdio.decode(bytes)

    response = Protocol.create_error_response("request", -1, "rejected")
    assert {:ok, bytes} = Stdio.encode(response)
    assert {:ok, [%{"id" => "request", "error" => %{"code" => -1}}], ""} = Stdio.decode(bytes)
  end

  test "assembles split frames and skips merged stderr without losing coalesced responses" do
    first = %{"jsonrpc" => "2.0", "id" => "first", "result" => %{"tools" => []}}
    second = %{"jsonrpc" => "2.0", "id" => "second", "result" => %{"contents" => []}}
    {:ok, first_bytes} = Stdio.encode(first)
    {:ok, second_bytes} = Stdio.encode(second)
    <<prefix::binary-size(9), suffix::binary>> = first_bytes

    assert {:ok, [], ^prefix} = Stdio.decode("stderr startup log\n\nnull\n{}\n" <> prefix)

    assert {:ok, [^first, ^second], "partial log"} =
             Stdio.decode(prefix <> suffix <> "stderr warning\n" <> second_bytes <> "partial log")
  end

  test "bounds both complete and incomplete frames at eight MiB" do
    limit = String.duplicate("x", 8 * 1024 * 1024)
    assert {:ok, [], ^limit} = Stdio.decode(limit)
    assert {:error, :frame_too_large} = Stdio.decode(limit <> "x")
    assert {:error, :frame_too_large} = Stdio.decode(limit <> "x\n")
    assert {:ok, [], ""} = Stdio.decode(limit <> "\n")
  end
end
