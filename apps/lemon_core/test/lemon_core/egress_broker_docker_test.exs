defmodule LemonCore.EgressBrokerDocker606Test do
  use ExUnit.Case, async: false

  alias LemonCore.EgressBroker.Certificates
  alias LemonCore.TerminalBackends.Docker
  alias LemonCore.TerminalBackends.Docker.Sandbox

  @moduletag :docker
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  test "container inspection cannot find broker credentials while TLS requests authenticate", %{
    tmp_dir: workspace
  } do
    docker = Docker.docker_path()
    assert is_binary(docker), "Docker and a locally installed Python-equipped image are required"
    ca = Certificates.create()
    leaf = Certificates.leaf(ca, "localhost")

    {:ok, listener} =
      :ssl.listen(0,
        cert: leaf.cert,
        key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, leaf.key)},
        active: false,
        reuseaddr: true,
        mode: :binary
      )

    on_exit(fn -> :ssl.close(listener) end)
    {:ok, {_address, port}} = :ssl.sockname(listener)
    secret = "lemon-test-secret-" <> Base.encode16(:crypto.strong_rand_bytes(24))
    reference = "LEMON_EGRESS_DOCKER_TEST_TOKEN"

    upstream =
      Task.async(fn ->
        {:ok, transport} = :ssl.transport_accept(listener, 60_000)
        {:ok, socket} = :ssl.handshake(transport, 15_000)
        request = headers(socket, "")

        assert String.contains?(
                 String.downcase(request),
                 "authorization: bearer " <> String.downcase(secret)
               )

        response = "authenticated " <> secret

        :ok =
          :ssl.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(response)}\r\nX-Echo: #{secret}\r\nConnection: close\r\n\r\n" <>
              response
          )

        :ssl.close(socket)
      end)

    on_exit(fn -> if Process.alive?(upstream.pid), do: Process.exit(upstream.pid, :kill) end)

    previous = Application.fetch_env(:lemon_core, :egress_broker)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :egress_broker, value)
        :error -> Application.delete_env(:lemon_core, :egress_broker)
      end
    end)

    Application.put_env(:lemon_core, :egress_broker,
      allowlist: [{"localhost", port}],
      bindings: %{"localhost" => %{secret: reference, header: "authorization", prefix: "Bearer "}},
      secrets_opts: [prefer_env: true, env_getter: fn ^reference -> secret end],
      upstream_tls: [cacerts: [ca.cert]]
    )

    broker = Sandbox.start()
    on_exit(fn -> Sandbox.stop(broker) end)
    # The inspected token is random per test and is never supplied to Docker.
    # Its hash is enough to prove the container cannot locate its raw bytes.
    digest = :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

    inspection = """
    import glob, hashlib, os, pathlib, socket, urllib.request
    digest = '#{digest}'
    def inspect_container():
        candidates = [k.encode() + b'=' + v.encode() for k,v in os.environ.items()]
        for pattern in ('/proc/[0-9]*/environ', '/proc/[0-9]*/cmdline', '/run/lemon-egress/*', '/tmp/*'):
            for name in glob.glob(pattern):
                try:
                    if pathlib.Path(name).is_file(): candidates.append(pathlib.Path(name).read_bytes())
                except (OSError, PermissionError): pass
        for blob in candidates:
            for offset in range(max(0, len(blob) - #{byte_size(secret)} + 1)):
                assert hashlib.sha256(blob[offset:offset+#{byte_size(secret)}]).hexdigest() != digest
    inspect_container()
    try:
        socket.create_connection(('1.1.1.1', 443), timeout=1)
    except OSError: pass
    else: raise AssertionError('direct network route escaped sandbox')
    try:
        urllib.request.urlopen('https://not-allowlisted.invalid/', timeout=10)
    except OSError: pass
    else: raise AssertionError('CONNECT allowlist bypassed')
    response = urllib.request.urlopen('https://localhost:#{port}/', timeout=20)
    body = response.read().decode()
    assert body == 'authenticated [REDACTED]', repr(body)
    assert response.headers['X-Echo'] == '[REDACTED]'
    inspect_container()
    print('inspection, authentication, redaction and egress isolation passed')
    """

    command = "python3 -c " <> quote_shell(inspection)

    {output, status} =
      System.cmd(docker, Docker.args(command, workspace, %{}, broker), stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "inspection, authentication, redaction and egress isolation passed"
    refute output =~ secret
    Task.await(upstream, 5_000)
  end

  defp headers(socket, data) do
    if String.contains?(data, "\r\n\r\n") do
      data
    else
      assert byte_size(data) < 32_768
      {:ok, chunk} = :ssl.recv(socket, 0, 15_000)
      headers(socket, data <> chunk)
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
