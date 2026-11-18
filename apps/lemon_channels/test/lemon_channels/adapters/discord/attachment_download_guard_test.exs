defmodule LemonChannels.Adapters.Discord.AttachmentDownloadGuardTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Discord.FileOperations

  @public {162, 159, 128, 233}
  @cdn "https://cdn.discordapp.com/attachments/1/2/notes.txt"

  defp start_server(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()

    pid =
      spawn_link(fn ->
        Stream.repeatedly(fn -> :gen_tcp.accept(listen) end)
        |> Enum.each(fn {:ok, socket} ->
          {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
          send(test, {:hit, port})

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
          )

          :gen_tcp.close(socket)
        end)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp net_opts(send_fun) do
    [resolver: fn "cdn.discordapp.com" -> {:ok, [@public]} end, send: send_fun]
  end

  test "only Discord CDN attachment URLs are fetched" do
    port = start_server("secret")

    for url <- [
          "http://127.0.0.1:#{port}/a",
          "https://127.0.0.1:#{port}/a",
          "http://cdn.discordapp.com/attachments/1/2/a",
          "https://cdn.discordapp.com:8443/attachments/1/2/a",
          "https://user@cdn.discordapp.com/attachments/1/2/a",
          "https://cdn.discordapp.com.evil.example/a",
          "https://169.254.169.254/latest/meta-data/"
        ] do
      assert {:error, message} = FileOperations.download_attachment_bytes(url)
      assert is_binary(message)
    end

    refute_receive {:hit, ^port}, 300
  end

  test "a CDN download is pinned to the authorized address" do
    test = self()

    send_fun = fn request ->
      send(test, {:request, request})
      {:ok, %{status: 200, headers: [], body: "bytes"}}
    end

    assert {:ok, "bytes"} =
             FileOperations.download_attachment_bytes(@cdn, 1_024, net_opts(send_fun))

    assert_receive {:request, request}
    assert request.address == @public
    assert request.host == "cdn.discordapp.com"
    assert request.path == "/attachments/1/2/notes.txt"
    assert request.timeout_ms <= 60_000
    assert request.max_body_bytes == 1_024
  end

  test "redirects are returned as failures, never followed" do
    test = self()

    send_fun = fn request ->
      send(test, {:request, request.path})
      {:ok, %{status: 302, headers: [{"location", "http://10.0.0.5/admin"}], body: ""}}
    end

    assert {:error, _} = FileOperations.download_attachment_bytes(@cdn, 1_024, net_opts(send_fun))
    assert_receive {:request, "/attachments/1/2/notes.txt"}
    refute_receive {:request, _}, 100
  end

  test "attachments over the upload cap are refused" do
    send_fun = fn request ->
      {:ok, %{status: 200, headers: [], body: :binary.copy("x", request.max_body_bytes + 1)}}
    end

    assert {:error, message} =
             FileOperations.download_attachment_bytes(@cdn, 10, net_opts(send_fun))

    assert message =~ "too large"
  end
end
