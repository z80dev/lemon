defmodule LemonChannels.Adapters.Email.OutboundTest do
  @moduledoc """
  Characterization tests for the ported email outbound path.

  The `smtp_options/1` blocks are carried over unchanged from
  `apps/lemon_gateway/test/transports/email/outbound_test.exs`, which was
  written against the gateway implementation *before* the port precisely so
  this file could prove the move was faithful. They are descriptive, not
  prescriptive: a failure here is a behaviour change to justify.

  The `deliver/1` blocks are new, because the entrypoint changed. The gateway
  took a finished run and no-oped on anything that was not an email reply; a
  `LemonChannels.Plugin` takes an `OutboundPayload` and is only ever called for
  its own channel, so the same guards become explicit errors.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Email
  alias LemonChannels.Adapters.Email.Outbound
  alias LemonChannels.OutboundPayload

  setup do
    previous = Application.get_env(:lemon_channels, Email)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:lemon_channels, Email)
  defp restore(previous), do: Application.put_env(:lemon_channels, Email, previous)

  defp configure(opts), do: Application.put_env(:lemon_channels, Email, opts)

  defp payload(overrides \\ []) do
    [
      channel_id: "email",
      account_id: "agent@lemon.test",
      peer: %{kind: :dm, id: "alice@example.com", thread_id: nil},
      kind: :text,
      content: "here you go"
    ]
    |> Keyword.merge(overrides)
    |> OutboundPayload.new()
  end

  describe "smtp_options/1 — rejection" do
    test "rejects a non-map config" do
      assert {:error, :invalid_smtp_config} = Outbound.smtp_options("nope")
      assert {:error, :invalid_smtp_config} = Outbound.smtp_options(nil)
    end

    test "requires a relay" do
      assert {:error, :missing_smtp_relay} = Outbound.smtp_options(%{})
    end

    test "treats a blank relay as missing" do
      assert {:error, :missing_smtp_relay} = Outbound.smtp_options(%{smtp_relay: "   "})
    end
  end

  describe "smtp_options/1 — defaults" do
    test "a relay alone yields plaintext-submission defaults" do
      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "mail.example.com"})

      assert opts[:relay] == "mail.example.com"
      assert opts[:port] == 587
      assert opts[:ssl] == false
      assert opts[:tls] == :if_available
      assert opts[:no_mx_lookups] == true
    end

    test "auth defaults to :never without both username and password" do
      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r"})
      assert opts[:auth] == :never

      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_username: "u"})
      assert opts[:auth] == :never
    end

    test "auth defaults to :if_available once both credentials are present" do
      assert {:ok, opts} =
               Outbound.smtp_options(%{smtp_relay: "r", smtp_username: "u", smtp_password: "p"})

      assert opts[:auth] == :if_available
    end

    test "omits credential keys entirely when blank rather than sending empties" do
      assert {:ok, opts} =
               Outbound.smtp_options(%{smtp_relay: "r", smtp_username: "  ", smtp_password: nil})

      refute Keyword.has_key?(opts, :username)
      refute Keyword.has_key?(opts, :password)
      refute Keyword.has_key?(opts, :hostname)
    end
  end

  describe "smtp_options/1 — ssl and port" do
    test "ssl switches the default port to the implicit-TLS submission port" do
      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_ssl: true})
      assert opts[:ssl] == true
      assert opts[:port] == 465
    end

    test "ssl accepts the documented truthy strings" do
      for value <- ["true", "TRUE", "1", "yes", "on", " on "] do
        assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_ssl: value})
        assert opts[:ssl] == true, "expected #{inspect(value)} to be truthy"
      end
    end

    test "anything else is falsey, including other strings and zero" do
      for value <- ["no", "maybe", "", 0, nil, %{}] do
        assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_ssl: value})
        assert opts[:ssl] == false, "expected #{inspect(value)} to be falsey"
      end
    end

    test "an explicit port wins, as an integer or a numeric string" do
      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_port: 2525})
      assert opts[:port] == 2525

      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_port: " 2525 "})
      assert opts[:port] == 2525
    end

    test "an unparseable or non-positive port falls back to the default" do
      for value <- ["not-a-port", "0", 0, -1] do
        assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_port: value})
        assert opts[:port] == 587, "expected #{inspect(value)} to fall back"
      end
    end
  end

  describe "smtp_options/1 — key resolution" do
    test "nested :outbound config takes precedence over the flat key" do
      cfg = %{
        smtp_relay: "flat.example.com",
        outbound: %{relay: "nested.example.com"}
      }

      assert {:ok, opts} = Outbound.smtp_options(cfg)
      assert opts[:relay] == "nested.example.com"
    end

    test "string keys resolve as well as atom keys" do
      assert {:ok, opts} = Outbound.smtp_options(%{"smtp_relay" => "string.example.com"})
      assert opts[:relay] == "string.example.com"

      assert {:ok, opts} = Outbound.smtp_options(%{"outbound" => %{"relay" => "nested.example"}})
      assert opts[:relay] == "nested.example"
    end

    test "falls back through the flat aliases for relay" do
      assert {:ok, opts} = Outbound.smtp_options(%{relay: "bare.example.com"})
      assert opts[:relay] == "bare.example.com"
    end

    test "reads a whole TOML-shaped email block the way the config loader emits it" do
      # Carried over from LemonGateway.ConfigLoaderTest, which asserted this
      # before the port. The loader preserves the block verbatim — untrimmed
      # strings, string-typed numbers and booleans, nested beside flat — so the
      # trimming and coercion all have to happen here.
      cfg = %{
        smtp_relay: "flat-relay.example.test",
        smtp_port: "2525",
        smtp_ssl: true,
        smtp_tls: "always",
        smtp_auth: "never",
        smtp_username: "flat-user",
        smtp_password: "flat-pass",
        outbound: %{
          relay: " nested-relay.example.test ",
          port: "587",
          ssl: false,
          tls: "never",
          auth: "if_available",
          username: " nested-user ",
          password: " nested-pass ",
          hostname: " mail.example.test ",
          tls_versions: ["tlsv1.2", "tlsv1.3"]
        }
      }

      assert {:ok, opts} = Outbound.smtp_options(cfg)
      assert Keyword.fetch!(opts, :relay) == "nested-relay.example.test"
      assert Keyword.fetch!(opts, :port) == 587
      assert Keyword.fetch!(opts, :ssl) == false
      assert Keyword.fetch!(opts, :tls) == :never
      assert Keyword.fetch!(opts, :auth) == :if_available
      assert Keyword.fetch!(opts, :username) == "nested-user"
      assert Keyword.fetch!(opts, :password) == "nested-pass"
      assert Keyword.fetch!(opts, :hostname) == "mail.example.test"
      assert {:tls_options, [versions: [:"tlsv1.2", :"tlsv1.3"]]} in opts
    end
  end

  describe "smtp_options/1 — tls and auth modes" do
    test "recognises the three documented modes, case- and space-insensitively" do
      for {input, expected} <- [
            {"always", :always},
            {"NEVER", :never},
            {" if_available ", :if_available}
          ] do
        assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_tls: input})
        assert opts[:tls] == expected
      end
    end

    test "an unrecognised mode string falls back to the default" do
      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_tls: "sometimes"})
      assert opts[:tls] == :if_available
    end

    test "an atom is passed through unvalidated" do
      assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_tls: :whatever})
      assert opts[:tls] == :whatever
    end

    test "an explicit auth mode overrides the credential-derived default" do
      cfg = %{smtp_relay: "r", smtp_username: "u", smtp_password: "p", smtp_auth: "never"}
      assert {:ok, opts} = Outbound.smtp_options(cfg)
      assert opts[:auth] == :never
    end
  end

  describe "smtp_options/1 — tls_versions" do
    test "maps version strings into :tls_options" do
      cfg = %{smtp_relay: "r", smtp_tls_versions: ["tlsv1.2", "TLSv1.3"]}

      assert {:ok, opts} = Outbound.smtp_options(cfg)
      assert opts[:tls_options] == [versions: [:"tlsv1.2", :"tlsv1.3"]]
    end

    test "an unknown version string degrades to tlsv1.2 rather than failing" do
      cfg = %{smtp_relay: "r", smtp_tls_versions: ["sslv3"]}

      assert {:ok, opts} = Outbound.smtp_options(cfg)
      assert opts[:tls_options] == [versions: [:"tlsv1.2"]]
    end

    test "an empty or non-list value omits the key" do
      for value <- [[], "tlsv1.2", nil] do
        assert {:ok, opts} = Outbound.smtp_options(%{smtp_relay: "r", smtp_tls_versions: value})
        refute Keyword.has_key?(opts, :tls_options)
      end
    end
  end

  describe "deliver/1 — payloads that never reach the network" do
    test "refuses a kind email has no way to express" do
      for kind <- [:edit, :delete, :reaction, :voice] do
        assert {:error, {:unsupported_kind, ^kind}} = Outbound.deliver(payload(kind: kind))
      end
    end

    test "refuses something that is not an outbound payload at all" do
      assert {:error, :invalid_payload} = Outbound.deliver(%{})
      assert {:error, :invalid_payload} = Outbound.deliver(nil)
    end

    test "reports a peer id that is not an address rather than guessing" do
      payload = payload(peer: %{kind: :dm, id: "not-an-address", thread_id: nil})

      assert {:error, :missing_recipient} = Outbound.deliver(payload)
    end

    test "reports a missing sender when neither config nor account id names one" do
      configure(from: "", outbound: %{from: ""})

      assert {:error, :missing_sender} = Outbound.deliver(payload(account_id: "not-an-address"))
    end

    test "refuses an empty body instead of mailing a blank message" do
      assert {:error, :empty_body} = Outbound.deliver(payload(content: "   "))
    end

    test "refuses a file payload whose file is not on disk" do
      payload = payload(kind: :file, content: %{path: "/nonexistent/nope.txt"})

      assert {:error, :no_readable_attachment} = Outbound.deliver(payload)
    end

    test "stops at the missing relay once the envelope is sound" do
      # The last gate before SMTP: everything about the message is fine, there
      # is simply nowhere to submit it. This is the default state of the
      # adapter, and it is why the compliance suite's deliver probe is safe.
      assert {:error, :missing_smtp_relay} = Outbound.deliver(payload())
    end
  end

  describe "deliver/1 — SMTP transport failures" do
    # These drive the whole `deliver/1` path through `:gen_smtp_client` to a
    # relay that fails, proving each failure comes back as `{:error, reason}`
    # rather than a crash or a hang. The relay is a throwaway TCP server bound
    # to loopback on an ephemeral port, so nothing leaves the machine.

    test "a refused connection is reported, not raised" do
      # Point at a port nobody is listening on. The kernel answers with
      # ECONNREFUSED immediately, so this is also the fast, deterministic case.
      port = closed_port()
      configure(from: "agent@lemon.test", smtp_relay: "127.0.0.1", smtp_port: port)

      assert {:error, {:smtp, _reason}} = Outbound.deliver(payload())
    end

    test "a relay that refuses at the greeting comes back as an error" do
      # A 5xx banner is a permanent failure: the relay is up but declining to
      # serve us. gen_smtp gives up without retrying other hosts.
      {port, server} = smtp_server(fn socket -> tcp_send(socket, "554 no service here") end)

      configure(from: "agent@lemon.test", smtp_relay: "127.0.0.1", smtp_port: port)

      assert {:error, {:smtp, _reason}} = Outbound.deliver(payload())
      await(server)
    end

    test "a relay that rejects authentication comes back as an error" do
      # Advertise AUTH PLAIN so gen_smtp attempts it in a single command, then
      # answer 535. Credentials in config are what make it try at all.
      {port, server} =
        smtp_server(fn socket ->
          tcp_send(socket, "220 fake ESMTP")
          _ehlo = tcp_recv(socket)
          tcp_send(socket, "250-fake\r\n250 AUTH PLAIN")
          _auth = tcp_recv(socket)
          tcp_send(socket, "535 5.7.8 authentication failed")
        end)

      configure(
        from: "agent@lemon.test",
        smtp_relay: "127.0.0.1",
        smtp_port: port,
        smtp_username: "u",
        smtp_password: "p",
        smtp_auth: "always"
      )

      assert {:error, {:smtp, _reason}} = Outbound.deliver(payload())
      await(server)
    end

    test "a relay that accepts the connection then never speaks is bounded, not a hang" do
      # The dangerous case: the TCP connect succeeds, so the 5s connect timeout
      # never fires, and gen_smtp then reads the banner with a hardcoded 20-min
      # timeout. Without our own deadline this call would block for that long.
      # The server accepts and goes silent; `smtp_timeout` caps the exchange.
      {port, server} =
        smtp_server(fn socket ->
          # Hold the connection open, saying nothing, until the test tears down.
          :gen_tcp.recv(socket, 0, 2_000)
        end)

      configure(
        from: "agent@lemon.test",
        smtp_relay: "127.0.0.1",
        smtp_port: port,
        smtp_timeout: 300
      )

      {elapsed_us, result} = :timer.tc(fn -> Outbound.deliver(payload()) end)

      assert {:error, {:smtp, :timeout}} = result
      # Comfortably under gen_smtp's 20-minute read timeout: the deadline fired.
      assert elapsed_us < 5_000_000, "deliver/1 took #{div(elapsed_us, 1000)}ms — deadline did not fire"

      await(server)
    end
  end

  describe "build_envelope/2 — reply headers" do
    test "addresses the reply to the peer and from the configured sender" do
      configure(from: "Agent <AGENT@Lemon.test>")

      assert {:ok, envelope} = Outbound.build_envelope(payload())
      assert envelope.to == "alice@example.com"
      assert envelope.from == "agent@lemon.test"
    end

    test "falls back to the account the message arrived at when no sender is configured" do
      configure([])

      assert {:ok, envelope} = Outbound.build_envelope(payload())
      assert envelope.from == "agent@lemon.test"
    end

    test "nested outbound config outranks the flat sender" do
      configure(from: "flat@lemon.test", outbound: %{from: "nested@lemon.test"})

      assert {:ok, envelope} = Outbound.build_envelope(payload())
      assert envelope.from == "nested@lemon.test"
    end

    test "sets Reply-To only when configured" do
      configure(from: "agent@lemon.test")
      assert {:ok, envelope} = Outbound.build_envelope(payload())
      assert envelope.reply_to == nil

      configure(from: "agent@lemon.test", reply_to: "inbox@lemon.test")
      assert {:ok, envelope} = Outbound.build_envelope(payload())
      assert envelope.reply_to == "inbox@lemon.test"
    end

    test "prefixes the subject with Re: exactly once" do
      assert {:ok, envelope} =
               Outbound.build_envelope(payload(meta: %{subject: "Deploy plan"}), %{})

      assert envelope.subject == "Re: Deploy plan"

      assert {:ok, already} =
               Outbound.build_envelope(payload(meta: %{subject: "RE: Deploy plan"}), %{})

      assert already.subject == "RE: Deploy plan"
    end

    test "names a subject rather than sending none when nothing supplies one" do
      assert {:ok, envelope} = Outbound.build_envelope(payload(), %{})
      assert envelope.subject == "Re: (no subject)"
    end

    test "replies to the id the payload names" do
      payload = payload(reply_to: "<parent@example.com>")

      assert {:ok, envelope} = Outbound.build_envelope(payload, %{})
      assert envelope.in_reply_to == "parent@example.com"
      assert envelope.references == ["parent@example.com"]
    end
  end

  describe "build_envelope/2 — thread continuity" do
    setup do
      # A thread the inbound half has already seen, which is the only place a
      # reply's subject and reference chain can come from: OutboundPayload
      # carries neither. The id is unique per run because the thread tables are
      # shared process state for the whole suite.
      {:ok, message} =
        Email.normalize_inbound(%{
          "from" => "alice@example.com",
          "to" => "agent@lemon.test",
          "subject" => "Deploy plan",
          "text" => "when does it ship?",
          "message_id" => "<deploy-#{System.unique_integer([:positive])}@example.com>"
        })

      %{thread_id: message.peer.thread_id, message_id: message.message.id}
    end

    test "carries the thread's subject into the reply", %{thread_id: thread_id} do
      payload = payload(peer: %{kind: :dm, id: "alice@example.com", thread_id: thread_id})

      assert {:ok, envelope} = Outbound.build_envelope(payload, %{})
      assert envelope.subject == "Re: Deploy plan"
    end

    test "builds References from the stored chain", %{
      thread_id: thread_id,
      message_id: message_id
    } do
      payload = payload(peer: %{kind: :dm, id: "alice@example.com", thread_id: thread_id})

      assert {:ok, envelope} = Outbound.build_envelope(payload, %{})
      assert envelope.references == [message_id]
    end

    test "replies to the thread's last message when the payload names none", %{
      thread_id: thread_id,
      message_id: message_id
    } do
      payload = payload(peer: %{kind: :dm, id: "alice@example.com", thread_id: thread_id})

      assert {:ok, envelope} = Outbound.build_envelope(payload, %{})
      assert envelope.in_reply_to == message_id
    end

    test "the payload's own reply_to still wins over the stored one", %{thread_id: thread_id} do
      payload =
        payload(
          peer: %{kind: :dm, id: "alice@example.com", thread_id: thread_id},
          reply_to: "later@example.com"
        )

      assert {:ok, envelope} = Outbound.build_envelope(payload, %{})
      assert envelope.in_reply_to == "later@example.com"
      assert "later@example.com" in envelope.references
    end
  end

  # ---------------------------------------------------------------------------
  # Throwaway SMTP relay
  # ---------------------------------------------------------------------------

  # A loopback TCP listener on an ephemeral port whose accepted connection is
  # handled by `fun`, letting a test script exactly the failing dialogue a real
  # relay would speak. Returns the port and the server task to await.
  defp smtp_server(fun) when is_function(fun, 1) do
    {:ok, listen} =
      :gen_tcp.listen(0,
        mode: :binary,
        packet: :line,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      )

    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        try do
          case :gen_tcp.accept(listen, 5_000) do
            {:ok, socket} ->
              try do
                fun.(socket)
              after
                :gen_tcp.close(socket)
              end

            {:error, _} ->
              :ok
          end
        after
          :gen_tcp.close(listen)
        end
      end)

    {port, server}
  end

  defp tcp_send(socket, line), do: :gen_tcp.send(socket, line <> "\r\n")

  defp tcp_recv(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> data
      {:error, _} = error -> error
    end
  end

  # Wait for the relay task so a failed dialogue surfaces here rather than as a
  # stray log line after the test has moved on.
  defp await(server), do: Task.await(server, 10_000)

  # A loopback port with nothing listening: bind one, read its number, release
  # it. A connect there gets ECONNREFUSED rather than hanging.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: true)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
