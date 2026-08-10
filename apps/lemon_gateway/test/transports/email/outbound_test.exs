defmodule LemonGateway.Transports.Email.OutboundTest do
  @moduledoc """
  Characterization tests for `LemonGateway.Transports.Email.Outbound`.

  Written ahead of the Phase 2.4 email port (see
  `docs/platform/transport-unification.md`). This module had **zero** dedicated
  tests despite being 715 LOC, which made it the largest single risk in moving
  email to `lemon_channels`. These tests pin *current* behaviour so the port can
  be judged a faithful move rather than a rewrite — they are deliberately
  descriptive, not prescriptive. If one fails after the port, that is a
  behaviour change to justify, not a test to update reflexively.

  Scope is the two public functions. `smtp_options/1` is pure and carries most
  of the configuration semantics; `deliver/2` is covered only on its
  no-network early-return paths, since exercising it further would require an
  SMTP relay.
  """
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Email.Outbound
  alias LemonGateway.Types.Job

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

  describe "deliver/2 — no-op paths" do
    # These are the only deliver/2 paths reachable without an SMTP relay. They
    # matter because they are the guard that keeps non-email runs from touching
    # the transport at all.
    test "is a no-op when the job carries no meta" do
      assert :ok = Outbound.deliver(%Job{run_id: "r1", meta: nil}, %{})
    end

    test "is a no-op when meta has no email_reply" do
      assert :ok = Outbound.deliver(%Job{run_id: "r1", meta: %{other: true}}, %{})
    end

    test "is a no-op when email_reply is present but not a map" do
      assert :ok = Outbound.deliver(%Job{run_id: "r1", meta: %{email_reply: "nope"}}, %{})
    end
  end
end
