defmodule LemonChannels.Telegram.APIDownloadTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Telegram.API

  @public {149, 154, 167, 220}
  @unguarded [LemonCore.Httpc, :httpc, Req, LemonChannels.ImageDownload]

  # Remote calls made by `name/arity`, read from the module's compiled beam on
  # the code path (`:code.which/1` is `:cover_compiled` under `--cover`).
  defp remote_calls(module, name, arity) do
    {^module, beam, _path} = :code.get_object_code(module)

    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])

    forms
    |> Enum.filter(&match?({:function, _, ^name, ^arity, _}, &1))
    |> collect([])
  end

  defp collect({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args} = _node, acc),
    do: collect(args, [{m, f} | acc])

  defp collect(node, acc) when is_tuple(node), do: collect(Tuple.to_list(node), acc)
  defp collect(node, acc) when is_list(node), do: Enum.reduce(node, acc, &collect/2)
  defp collect(_node, acc), do: acc

  defp net_opts(send_fun) do
    [resolver: fn "api.telegram.org" -> {:ok, [@public]} end, send: send_fun]
  end

  test "both download arities go through the guarded fetcher only" do
    for arity <- [2, 3] do
      calls = remote_calls(API, :download_file, arity)
      assert Enum.filter(calls, fn {m, _} -> m in @unguarded end) == []
    end
  end

  test "a file download is pinned to the authorized Bot API address" do
    test = self()

    send_fun = fn request ->
      send(test, {:request, request})
      {:ok, %{status: 200, headers: [], body: "voice"}}
    end

    assert {:ok, "voice"} =
             API.download_file("123:abc", "voice/file_1.oga", 1_024, net_opts(send_fun))

    assert_receive {:request, request}
    assert request.address == @public
    assert request.host == "api.telegram.org"
    assert request.scheme == "https"
    assert request.path == "/file/bot123:abc/voice/file_1.oga"
    assert request.timeout_ms <= 60_000
  end

  test "redirects are returned as failures, never followed" do
    test = self()

    send_fun = fn request ->
      send(test, {:request, request.path})
      {:ok, %{status: 302, headers: [{"location", "http://10.0.0.5/x"}], body: ""}}
    end

    assert {:error, {:http_error, 302}} =
             API.download_file("123:abc", "documents/f.bin", 1_024, net_opts(send_fun))

    assert_receive {:request, _}
    refute_receive {:request, _}, 100
  end

  test "downloads over the cap are refused" do
    send_fun = fn _request -> {:ok, %{status: 200, headers: [], body: :binary.copy("x", 11)}} end

    assert {:error, {:body_too_large, 10}} =
             API.download_file("123:abc", "documents/f.bin", 10, net_opts(send_fun))
  end
end
