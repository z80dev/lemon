defmodule LemonGateway.EmailInboundSecurityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Bitwise

  alias LemonGateway.Store
  alias LemonGateway.Transports.Email.Inbound

  @attachments_dir Path.join(System.tmp_dir!(), "lemon_gateway_email_attachments")
  @message_thread_table :email_message_threads
  @thread_state_table :email_thread_state

  setup do
    ensure_store_started()

    File.rm_rf(@attachments_dir)
    original_attachment_cap = Application.get_env(:lemon_gateway, :email_attachment_max_bytes)

    clear_table(@message_thread_table)
    clear_table(@thread_state_table)

    on_exit(fn ->
      File.rm_rf(@attachments_dir)
      restore_env(:lemon_gateway, :email_attachment_max_bytes, original_attachment_cap)
      clear_table(@message_thread_table)
      clear_table(@thread_state_table)
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

  test "copies Plug.Upload attachments to restricted temp files" do
    source =
      Path.join(System.tmp_dir!(), "email_upload_#{System.unique_integer([:positive])}.txt")

    File.write!(source, "upload-bytes")

    params = %{
      "from" => "sender@example.test",
      "to" => "bot@example.test",
      "subject" => "Upload copy",
      "text" => "hello",
      "attachments" => [
        %Plug.Upload{path: source, filename: "note.txt", content_type: "text/plain"}
      ]
    }

    assert {:ok, _} = Inbound.ingest(params, %{})
    assert {:ok, [copied]} = File.ls(@attachments_dir)

    copied_path = Path.join(@attachments_dir, copied)
    assert copied_path != source
    assert File.read!(copied_path) == "upload-bytes"

    if match?({:unix, _}, :os.type()) do
      assert {:ok, stat} = File.stat(copied_path)
      assert (stat.mode &&& 0o777) == 0o600
    end

    File.rm(source)
  end

  test "drops oversized decoded attachment data" do
    Application.put_env(:lemon_gateway, :email_attachment_max_bytes, 8)

    params = %{
      "from" => "sender@example.test",
      "to" => "bot@example.test",
      "subject" => "Large data",
      "text" => "hello",
      "attachments" => [%{"filename" => "big.txt", "content" => String.duplicate("A", 64)}]
    }

    assert {:ok, _} = Inbound.ingest(params, %{})
    assert File.ls(@attachments_dir) in [{:error, :enoent}, {:ok, []}]
  end

  test "drops oversized Plug.Upload attachments" do
    Application.put_env(:lemon_gateway, :email_attachment_max_bytes, 8)

    source =
      Path.join(System.tmp_dir!(), "email_upload_large_#{System.unique_integer([:positive])}.txt")

    File.write!(source, String.duplicate("Z", 64))

    params = %{
      "from" => "sender@example.test",
      "to" => "bot@example.test",
      "subject" => "Large upload",
      "text" => "hello",
      "attachments" => [
        %Plug.Upload{path: source, filename: "big-upload.txt", content_type: "text/plain"}
      ]
    }

    assert {:ok, _} = Inbound.ingest(params, %{})
    assert File.ls(@attachments_dir) in [{:error, :enoent}, {:ok, []}]

    File.rm(source)
  end

  test "reuses thread id from in-reply-to message-id and appends references" do
    first_message_id = "msg-#{System.unique_integer([:positive])}@example.test"

    first = %{
      "from" => "sender@example.test",
      "to" => "bot@example.test",
      "subject" => "Thread one",
      "text" => "hello",
      "message-id" => "<#{first_message_id}>"
    }

    assert {:ok, %{thread_id: thread_id}} = Inbound.ingest(first, %{})

    second = %{
      "from" => "sender@example.test",
      "to" => "bot@example.test",
      "subject" => "Re: Thread one",
      "text" => "follow up",
      "in-reply-to" => "<#{first_message_id}>",
      "references" => "<#{first_message_id}>"
    }

    assert {:ok, %{thread_id: second_thread_id}} = Inbound.ingest(second, %{})
    assert second_thread_id == thread_id

    assert %{"references" => refs} = Store.get(@thread_state_table, thread_id)
    assert first_message_id in refs
  end

  defp clear_table(table) do
    table
    |> Store.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(table, key)
    end)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp ensure_store_started do
    if is_nil(Process.whereis(LemonCore.Store)) do
      case start_supervised(LemonCore.Store) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
