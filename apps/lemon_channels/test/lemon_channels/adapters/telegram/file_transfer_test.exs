defmodule LemonChannels.Adapters.Telegram.FileTransferTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  defmodule LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI do
    @updates_key {__MODULE__, :updates}
    @sent_key {__MODULE__, :sent}

    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)
    def register_sent(pid), do: :persistent_term.put(@sent_key, pid)

    def get_updates(_token, _offset, _timeout_ms) do
      updates = :persistent_term.get(@updates_key, [])

      case updates do
        [first | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [first]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def get_file(_token, _file_id) do
      {:ok, %{"ok" => true, "result" => %{"file_path" => "doc.bin"}}}
    end

    def download_file(_token, _file_path) do
      {:ok, "FILE_BYTES"}
    end

    def send_document(_token, _chat_id, {:path, path}, opts) do
      if pid = :persistent_term.get(@sent_key, nil) do
        send(pid, {:send_document, path, opts})
      end

      {:ok, %{"ok" => true}}
    end

    def send_message(_token, _chat_id, text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      if pid = :persistent_term.get(@sent_key, nil) do
        send(pid, {:sent, text})
      end

      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end

    def edit_message_text(_token, _chat_id, _message_id, _text, _parse_mode_or_opts \\ nil) do
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
    def answer_callback_query(_token, _cb_id, _opts \\ %{}), do: {:ok, %{"ok" => true}}

    # For admin checks (not needed in these DM tests).
    def get_chat_member(_token, _chat_id, _user_id),
      do: {:ok, %{"ok" => true, "result" => %{"status" => "administrator"}}}
  end

  setup do
    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.register_sent(self())

    on_exit(fn ->
      if pid = Process.whereis(Elixir.LemonChannels.Adapters.Telegram.Transport) do
        Process.unlink(pid)

        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal)
          rescue
            ArgumentError -> :ok
          catch
            :exit, _ -> :ok
          end
        end
      end

      :persistent_term.erase({Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI, :sent})
      :persistent_term.erase({Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI, :updates})
    end)

    :ok
  end

  defp bind_project!(chat_id, root) do
    scope = %Elixir.LemonChannels.Types.ChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}

    LemonCore.Store.put(:channels_projects_dynamic, "testproj", %{
      root: root,
      default_engine: nil
    })

    LemonCore.Store.put(:channels_project_overrides, scope, "testproj")
  end

  defp document_update(chat_id, caption) do
    base =
      %{
        "update_id" => System.unique_integer([:positive]),
        "message" => %{
          "message_id" => System.unique_integer([:positive]),
          "date" => 1,
          "chat" => %{"id" => chat_id, "type" => "private"},
          "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
          "document" => %{
            "file_id" => "doc-1",
            "file_name" => "example.txt",
            "mime_type" => "text/plain",
            "file_size" => 9
          }
        }
      }

    if is_binary(caption) do
      put_in(base, ["message", "caption"], caption)
    else
      base
    end
  end

  defp document_update_media_group(chat_id, media_group_id, filename, caption \\ nil) do
    base =
      %{
        "update_id" => System.unique_integer([:positive]),
        "message" => %{
          "message_id" => System.unique_integer([:positive]),
          "date" => 1,
          "chat" => %{"id" => chat_id, "type" => "private"},
          "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
          "media_group_id" => media_group_id,
          "document" => %{
            "file_id" => "doc-#{filename}",
            "file_name" => filename,
            "mime_type" => "text/plain",
            "file_size" => 9
          }
        }
      }

    if is_binary(caption) do
      put_in(base, ["message", "caption"], caption)
    else
      base
    end
  end

  defp fresh_root!(prefix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  test "/file put saves document into bound project" do
    chat_id = 12_345
    root = fresh_root!("lemon-file-put")
    bind_project!(chat_id, root)

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([document_update(chat_id, "/file put incoming/example.txt")])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: false,
            uploads_dir: "incoming",
            deny_globs: [".git/**"]
          }
        }
      )

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Saved: incoming/example.txt")

    assert File.read!(Path.join(root, "incoming/example.txt")) == "FILE_BYTES"
  end

  test "/file put defaults to channels.default_cwd when no project is bound" do
    chat_id = 12_346
    root = Elixir.LemonChannels.Cwd.default_cwd()

    rel =
      Path.join("incoming", "lemon-file-put-default-#{System.unique_integer([:positive])}.txt")

    on_exit(fn ->
      _ = File.rm(Path.join(root, rel))
    end)

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([document_update(chat_id, "/file put #{rel}")])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: false, uploads_dir: "incoming"}
        }
      )

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Saved: #{rel}")
    assert File.read!(Path.join(root, rel)) == "FILE_BYTES"
  end

  test "/file get sends a file back to Telegram" do
    chat_id = 22_222
    root = fresh_root!("lemon-file-get")
    bind_project!(chat_id, root)

    File.write!(Path.join(root, "out.txt"), "hello")

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([
      %{
        "update_id" => 1,
        "message" => %{
          "message_id" => 11,
          "date" => 1,
          "chat" => %{"id" => chat_id, "type" => "private"},
          "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
          "text" => "/file get out.txt"
        }
      }
    ])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true}
        }
      )

    assert_receive {:send_document, path, _opts}, 300
    assert String.ends_with?(path, "/out.txt")
  end

  test "/file get defaults to channels.default_cwd when no project is bound" do
    chat_id = 22_223
    root = Elixir.LemonChannels.Cwd.default_cwd()

    rel =
      Path.join("incoming", "lemon-file-get-default-#{System.unique_integer([:positive])}.txt")

    full = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "hello")

    on_exit(fn ->
      _ = File.rm(full)
    end)

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([
      %{
        "update_id" => 2,
        "message" => %{
          "message_id" => 12,
          "date" => 1,
          "chat" => %{"id" => chat_id, "type" => "private"},
          "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
          "text" => "/file get #{rel}"
        }
      }
    ])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true}
        }
      )

    assert_receive {:send_document, path, _opts}, 300
    assert String.starts_with?(path, Path.expand(root))
    assert String.ends_with?(path, Path.basename(rel))
  end

  test "auto-put stores document with no caption into uploads_dir" do
    chat_id = 33_333
    root = fresh_root!("lemon-auto-put")
    bind_project!(chat_id, root)

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([document_update(chat_id, nil)])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: true, uploads_dir: "incoming"}
        }
      )

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Uploaded: incoming/example.txt")
    assert File.read!(Path.join(root, "incoming/example.txt")) == "FILE_BYTES"
  end

  test "auto-put batches media_group_id documents into uploads_dir" do
    chat_id = 44_444
    root = fresh_root!("lemon-auto-put-mg")
    bind_project!(chat_id, root)

    mg = "mg-1"

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([
      document_update_media_group(chat_id, mg, "a.txt"),
      document_update_media_group(chat_id, mg, "b.txt")
    ])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: true,
            uploads_dir: "incoming",
            media_group_debounce_ms: 50
          }
        }
      )

    assert_receive {:sent, text}, 800
    assert String.contains?(text, "Uploaded 2 files")
    assert File.read!(Path.join(root, "incoming/a.txt")) == "FILE_BYTES"
    assert File.read!(Path.join(root, "incoming/b.txt")) == "FILE_BYTES"
  end

  test "/file put batches media_group_id documents into a directory path" do
    chat_id = 55_555
    root = fresh_root!("lemon-file-put-mg")
    bind_project!(chat_id, root)

    mg = "mg-2"

    Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI.set_updates([
      document_update_media_group(chat_id, mg, "c.txt", "/file put incoming/"),
      document_update_media_group(chat_id, mg, "d.txt")
    ])

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: Elixir.LemonChannels.Adapters.Telegram.FileTransferTest.MockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: true,
            uploads_dir: "incoming",
            media_group_debounce_ms: 50
          }
        }
      )

    assert_receive {:sent, text}, 800
    assert String.contains?(text, "Saved 2 files")
    assert File.read!(Path.join(root, "incoming/c.txt")) == "FILE_BYTES"
    assert File.read!(Path.join(root, "incoming/d.txt")) == "FILE_BYTES"
  end
end
