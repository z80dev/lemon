defmodule LemonCore.TerminalBackends.Docker.Sandbox do
  @moduledoc """
  Network-enforced Docker terminal broker lifecycle.

  Docker has no external network; a public Unix socket is its sole egress.
  The operator-selected image must contain Python 3. Broker configuration is
  `config :lemon_core, :egress_broker` (allowlist and secret-reference bindings),
  never command-controlled options. See `docs/security/egress-broker.md`.
  """

  alias LemonCore.{EgressBroker, ToolPolicy}

  def policy(opts) do
    ToolPolicy.resolve(Keyword.get(opts, :tool_policy), ToolPolicy.from_profile(:full_access))
  end

  def backend(opts) do
    with {:ok, policy} <- policy(opts) do
      LemonCore.TerminalBackends.validate(
        if(policy.sandbox, do: :docker, else: Keyword.get(opts, :backend, :local))
      )
    end
  end

  def start do
    directory =
      Path.join(
        "/tmp",
        "lemon-egress-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    try do
      File.write!(Path.join(directory, "adapter.py"), adapter())
      opts = Application.get_env(:lemon_core, :egress_broker, [])
      opts = Keyword.merge(opts, directory: directory, owner: self())

      case EgressBroker.start_link(opts) do
        {:ok, pid} ->
          # The broker monitors its owner; owner death, including :kill, closes
          # all connections. No link exit may be swallowed by ProcessSession.
          Process.unlink(pid)
          stat = File.stat!(directory)

          Map.merge(EgressBroker.info(pid), %{
            pid: pid,
            directory: directory,
            uid: stat.uid,
            gid: stat.gid
          })

        {:error, _} ->
          File.rm_rf(directory)
          raise "egress broker unavailable"
      end
    rescue
      exception ->
        File.rm_rf(directory)
        reraise exception, __STACKTRACE__
    end
  end

  def stop(nil), do: :ok

  def stop(%{pid: pid, directory: directory}) do
    try do
      GenServer.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    after
      File.rm_rf(directory)
    end
  end

  @doc false
  def adapter do
    """
    import os, socket, socketserver, subprocess, sys, threading
    class Proxy(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True
    class Bridge(socketserver.BaseRequestHandler):
        def handle(self):
            upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                upstream.connect('/run/lemon-egress/proxy.sock')
                def pump(source, target):
                    try:
                        while True:
                            data = source.recv(65536)
                            if not data: break
                            target.sendall(data)
                    except OSError: pass
                    finally:
                        try: target.shutdown(socket.SHUT_WR)
                        except OSError: pass
                writer = threading.Thread(target=pump, args=(self.request, upstream), daemon=True)
                writer.start()
                pump(upstream, self.request)
                writer.join()
            finally: upstream.close()
    ca = '/run/lemon-egress/ca.pem'
    bundle = '/tmp/lemon-egress-ca.pem'
    with open(bundle, 'wb') as out:
        system_ca = '/etc/ssl/certs/ca-certificates.crt'
        if os.path.isfile(system_ca):
            with open(system_ca, 'rb') as source: out.write(source.read())
        with open(ca, 'rb') as source: out.write(source.read())
    proxy = Proxy(('127.0.0.1', 18080), Bridge)
    url = 'http://127.0.0.1:18080'
    env = os.environ.copy()
    for key in ('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy'):
        env[key] = url
    env['NO_PROXY'] = env['no_proxy'] = ''
    for key in ('SSL_CERT_FILE', 'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS'):
        env[key] = bundle
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    try: sys.exit(subprocess.call(['/bin/sh', '-lc', sys.argv[1]], env=env))
    finally: proxy.shutdown(); proxy.server_close()
    """
  end
end
