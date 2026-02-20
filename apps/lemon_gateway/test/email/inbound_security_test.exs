defmodule LemonGateway.EmailInboundSecurityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonGateway.Transports.Email.Inbound

  @attachments_dir Path.join(System.tmp_dir!(), "lemon_gateway_email_attachments")

  setup do
    File.rm_rf(@attachments_dir)

    on_exit(fn ->
      File.rm_rf(@attachments_dir)
    end)

    :ok
  end

  test "rejects attachment path references from structured webhook payloads" do
    source =
      Path.join(
        System.tmp_dir!(),
        "email_inbound_source_#{System.unique_integer([:positive])}.txt"
      )

    File.write!(source, "sensitive-data")

    params = %{
      "from" => "sender@example.test",
      "to" => "bot@example.test",
      "subject" => "Path test",
      "text" => "hello",
      "attachments" => [
        %{"filename" => "loot.txt", "path" => source},
        source
      ]
    }

    assert {:ok, _} = Inbound.ingest(params, %{})

    assert File.ls(@attachments_dir) in [{:error, :enoent}, {:ok, []}]

    File.rm(source)
  end

  test "disables webhook startup on non-loopback bind when token is missing" do
    cfg = %{"inbound" => %{"enabled" => true, "bind" => "0.0.0.0", "port" => 0}}

    log =
      capture_log(fn ->
        assert :ignore = Inbound.start_link(config: cfg)
      end)

    assert log =~ "email inbound webhook disabled: missing token for non-loopback bind"
  end

  test "respects explicit false for inbound webhook enable flags" do
    configs = [
      %{"inbound_enabled" => false, "inbound" => %{"bind" => "127.0.0.1", "port" => 0}},
      %{"webhook_enabled" => false, "inbound" => %{"bind" => "127.0.0.1", "port" => 0}},
      %{"inbound" => %{"enabled" => false, "bind" => "127.0.0.1", "port" => 0}}
    ]

    Enum.each(configs, fn cfg ->
      log =
        capture_log(fn ->
          assert :ignore = Inbound.start_link(config: cfg)
        end)

      assert log =~ "email inbound webhook server disabled"
    end)
  end

  test "subject fallback thread id includes sender when message-id is missing" do
    params = %{
      "to" => "bot@example.test",
      "subject" => "Daily update",
      "text" => "hello"
    }

    assert {:ok, %{thread_id: thread_a, message_id: nil}} =
             Inbound.ingest(Map.put(params, "from", "alice@example.test"), %{})

    assert {:ok, %{thread_id: thread_b, message_id: nil}} =
             Inbound.ingest(Map.put(params, "from", "bob@example.test"), %{})

    assert thread_a != thread_b
  end
end
