defmodule LemonSkills.HttpClientGuardTest do
  # Swaps the application's HTTP client and registry URL, so it runs alone.
  use ExUnit.Case, async: false

  alias LemonSkills.HttpClient

  setup do
    saved = Application.get_all_env(:lemon_skills) |> Keyword.take([:http_client, :registry_url])
    Application.delete_env(:lemon_skills, :http_client)
    Application.delete_env(:lemon_skills, :registry_url)

    on_exit(fn ->
      Application.delete_env(:lemon_skills, :registry_url)
      Enum.each(saved, fn {key, value} -> Application.put_env(:lemon_skills, key, value) end)
    end)

    # The production default, whatever module implements it.
    {:ok, client: HttpClient.impl()}
  end

  # Serves `routes` (path => raw response) and reports every request.
  defp start_server(routes) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()
    pid = spawn_link(fn -> accept_loop(listen, test, port, routes) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept_loop(listen, test, port, routes) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, head} = read_head(socket, "")
    [line | _] = String.split(head, "\r\n")
    [_method, path, _] = String.split(line, " ")
    send(test, {:hit, port, path, head})
    _ = :gen_tcp.send(socket, Map.fetch!(routes, path))
    :gen_tcp.close(socket)
    accept_loop(listen, test, port, routes)
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 5_000), do: read_head(socket, buffer <> chunk)
    end
  end

  defp ok(body), do: ["HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n", body]

  defp redirect(location),
    do: "HTTP/1.1 302 Found\r\nlocation: #{location}\r\ncontent-length: 0\r\n\r\n"

  test "unconfigured loopback and private destinations are refused", %{client: client} do
    port = start_server(%{"/secret" => ok("secret")})

    for url <- [
          "http://127.0.0.1:#{port}/secret",
          "http://localhost:#{port}/secret",
          "http://169.254.169.254/latest/meta-data/"
        ] do
      assert {:error, _} = client.fetch(url, [{"User-Agent", "t"}])
    end

    refute_receive {:hit, ^port, _, _}, 300
  end

  test "a configured registry cannot redirect to another private host", %{client: client} do
    target = start_server(%{"/secret" => ok("secret")})
    port = start_server(%{"/search" => redirect("http://localhost:#{target}/secret")})
    Application.put_env(:lemon_skills, :registry_url, "http://127.0.0.1:#{port}")

    assert {:error, _} =
             client.fetch("http://127.0.0.1:#{port}/search", [{"Authorization", "Bearer t"}])

    assert_receive {:hit, ^port, "/search", _}
    refute_receive {:hit, ^target, _, _}, 300
  end

  test "the configured registry is reachable and its bodies are bounded", %{client: client} do
    small = ~s({"items": []})
    large = :binary.copy("x", 9 * 1024 * 1024)
    port = start_server(%{"/small" => ok(small), "/large" => ok(large)})
    Application.put_env(:lemon_skills, :registry_url, "http://127.0.0.1:#{port}")

    assert {:ok, ^small} = client.fetch("http://127.0.0.1:#{port}/small", [])
    assert {:error, {:body_too_large, _}} = client.fetch("http://127.0.0.1:#{port}/large", [])
  end
end
