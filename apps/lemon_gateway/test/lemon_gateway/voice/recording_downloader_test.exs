defmodule LemonGateway.Voice.RecordingDownloaderTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Voice.RecordingDownloader

  @moduletag :tmp_dir
  @public {54, 172, 60, 0}
  @unguarded [LemonCore.Httpc, :httpc, Req]

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:lemon_gateway, :voice_recordings_dir)
    Application.put_env(:lemon_gateway, :voice_recordings_dir, tmp_dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_gateway, :voice_recordings_dir, previous),
        else: Application.delete_env(:lemon_gateway, :voice_recordings_dir)
    end)

    :ok
  end

  defp params do
    %{
      "RecordingUrl" => "https://api.twilio.com/2010-04-01/Accounts/AC1/Recordings/RE1",
      "RecordingSid" => "RE1",
      "CallSid" => "CA1",
      "From" => "+15550001111",
      "RecordingDuration" => "12"
    }
  end

  defp net_opts(send_fun) do
    [resolver: fn "api.twilio.com" -> {:ok, [@public]} end, send: send_fun]
  end

  # Read from the module's compiled beam on the code path (`:code.which/1` is
  # `:cover_compiled` under `--cover`).
  defp remote_calls(module) do
    {^module, beam, _path} = :code.get_object_code(module)

    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    collect(forms, [])
  end

  defp collect({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc),
    do: collect(args, [{m, f} | acc])

  defp collect(node, acc) when is_tuple(node), do: collect(Tuple.to_list(node), acc)
  defp collect(node, acc) when is_list(node), do: Enum.reduce(node, acc, &collect/2)
  defp collect(_node, acc), do: acc

  test "recordings are fetched only through the guarded fetcher" do
    assert Enum.filter(remote_calls(RecordingDownloader), fn {m, _} -> m in @unguarded end) ==
             []
  end

  test "the recording streams to disk from the pinned Twilio address", %{tmp_dir: tmp_dir} do
    test = self()

    send_fun = fn request ->
      send(test, {:request, request})
      File.write!(request.into, "RIFF-audio")
      {:ok, %{status: 200, headers: [], body: ""}}
    end

    assert {:ok, path} = RecordingDownloader.download(params(), net_opts(send_fun))
    assert String.starts_with?(path, tmp_dir)
    assert File.read!(path) == "RIFF-audio"
    assert_receive {:request, request}
    assert request.address == @public
    assert request.host == "api.twilio.com"
    assert request.path == "/2010-04-01/Accounts/AC1/Recordings/RE1.wav"
    assert {"authorization", "Basic " <> _} = List.keyfind(request.headers, "authorization", 0)
    assert request.max_body_bytes <= 512 * 1024 * 1024
  end

  test "a same-host redirect is followed without credentials; others are refused" do
    test = self()

    send_fun = fn request ->
      send(test, {:request, request.path, request.headers})

      case request.path do
        "/2010-04-01/Accounts/AC1/Recordings/RE1.wav" ->
          {:ok, %{status: 302, headers: [{"location", "/media/RE1.wav"}], body: ""}}

        "/media/RE1.wav" ->
          {:ok, %{status: 307, headers: [{"location", "http://10.0.0.5/x"}], body: ""}}
      end
    end

    assert {:error, {:redirect_not_allowed, "http://10.0.0.5/x"}} =
             RecordingDownloader.download(params(), net_opts(send_fun))

    assert_receive {:request, "/2010-04-01/Accounts/AC1/Recordings/RE1.wav", first}
    assert List.keymember?(first, "authorization", 0)
    assert_receive {:request, "/media/RE1.wav", second}
    refute List.keymember?(second, "authorization", 0)
    refute_receive {:request, _, _}, 100
    refute File.exists?(RecordingDownloader.recording_path(params()))
  end

  test "an oversized recording is refused and leaves no file" do
    send_fun = fn _request -> {:error, {:body_too_large, 1}} end

    assert {:error, {:body_too_large, 1}} =
             RecordingDownloader.download(params(), net_opts(send_fun))

    path = RecordingDownloader.recording_path(params())
    refute File.exists?(path)
    assert File.ls!(Path.dirname(path)) == []
  end
end
