defmodule CodingAgent.Debug.ProtocolTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.Protocol

  defp frame(message), do: message |> Protocol.encode() |> IO.iodata_to_binary()

  test "encode frames JSON with a byte-accurate Content-Length" do
    framed = frame(%{"seq" => 1, "type" => "request", "command" => "evaluate", "text" => "héllo"})
    [header, body] = String.split(framed, "\r\n\r\n", parts: 2)
    assert header == "Content-Length: #{byte_size(body)}"
    assert Jason.decode!(body)["text"] == "héllo"
  end

  test "decode handles a body split at every byte boundary" do
    message =
      frame(%{"seq" => 9, "type" => "event", "event" => "output", "body" => %{"output" => "ü"}})

    for split <- 1..(byte_size(message) - 1) do
      <<head::binary-size(^split), tail::binary>> = message
      {[], rest, ""} = Protocol.decode(head)
      assert {[%{"seq" => 9}], "", ""} = Protocol.decode(rest <> tail)
    end
  end

  test "non-protocol bytes before a header are returned as junk" do
    framed = frame(%{"seq" => 1, "type" => "event", "event" => "initialized"})

    assert {[%{"event" => "initialized"}], "", "warning: adapter noise\n"} =
             Protocol.decode("warning: adapter noise\n" <> framed)
  end

  test "a header block without a usable Content-Length is skipped" do
    framed = frame(%{"seq" => 2, "type" => "event", "event" => "terminated"})

    assert {[%{"event" => "terminated"}], "", ""} =
             Protocol.decode("Content-Length: nope\r\n\r\n" <> framed)
  end

  test "malformed JSON bodies are dropped without stalling later messages" do
    bad = "Content-Length: 5\r\n\r\n{nope"
    good = frame(%{"seq" => 3, "type" => "event", "event" => "exited"})
    assert {[%{"event" => "exited"}], "", ""} = Protocol.decode(bad <> good)
  end
end
