defmodule CodingAgent.Tools.WebGuardBodyLimitTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Tools.WebGuard

  test "halts on the first chunk exceeding the limit without reading subsequent chunks" do
    parent = self()

    get = fn _, opts ->
      into = Keyword.fetch!(opts, :into)

      {_, response} =
        Enum.reduce_while(["123", "456", "never"], {Req.new(), Req.Response.new()}, fn chunk,
                                                                                       acc ->
          send(parent, {:chunk, chunk})
          into.({:data, chunk}, acc)
        end)

      {:ok, response}
    end

    assert {:error, {:body_too_large, %{max_body_bytes: 5}}} =
             WebGuard.guarded_get("https://8.8.8.8", http_get: get, max_body_bytes: 5)

    assert_received {:chunk, "123"}
    assert_received {:chunk, "456"}
    refute_received {:chunk, "never"}
  end

  test "assembles ordered chunks exactly at the cap" do
    get = fn _, opts ->
      into = Keyword.fetch!(opts, :into)
      {:cont, acc} = into.({:data, "12"}, {Req.new(), Req.Response.new()})
      {:cont, {_, response}} = into.({:data, "345"}, acc)
      {:ok, response}
    end

    assert {:ok, %{body: "12345"}, _} =
             WebGuard.guarded_get("https://8.8.8.8", http_get: get, max_body_bytes: 5)
  end

  test "default is five MiB and injected nonstreaming responses are also bounded" do
    get = fn _, _ -> {:ok, Req.Response.new(body: :binary.copy("a", 5 * 1024 * 1024 + 1))} end

    assert {:error, {:body_too_large, %{max_body_bytes: 5_242_880}}} =
             WebGuard.guarded_get("https://8.8.8.8", http_get: get)
  end
end
