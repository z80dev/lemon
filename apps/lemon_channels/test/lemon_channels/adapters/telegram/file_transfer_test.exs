defmodule LemonChannels.Adapters.Telegram.FileTransferTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  defmodule FileTransferMockAPI do
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
    FileTransferMockAPI.register_sent(self())
    previous_telegram_env = Application.get_env(:lemon_channels, :telegram)

    Application.put_env(:lemon_channels, :telegram, %{
      bot_token: "token",
      api_mod: FileTransferMockAPI
    })

    case LemonChannels.Registry.register(LemonChannels.Adapters.Telegram) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

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

      _ = LemonChannels.Registry.unregister("telegram")

      if previous_telegram_env == nil do
        Application.delete_env(:lemon_channels, :telegram)
      else
        Application.put_env(:lemon_channels, :telegram, previous_telegram_env)
      end

      :persistent_term.erase({FileTransferMockAPI, :sent})
      :persistent_term.erase({FileTransferMockAPI, :updates})
    end)

    :ok
  end

  defp bind_project!(chat_id, root) do
    scope = %LemonCore.ChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}

    LemonCore.Store.put(:projects_dynamic, "testproj", %{
      root: root,
      default_engine: nil
    })

    LemonCore.Store.put(:project_overrides, scope, "testproj")
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

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: false,
            uploads_dir: "incoming",
            deny_globs: [".git/**"]
          }
        }
      )

    FileTransferMockAPI.set_updates([document_update(chat_id, "/file put incoming/example.txt")])

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

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: false, uploads_dir: "incoming"}
        }
      )

    FileTransferMockAPI.set_updates([document_update(chat_id, "/file put #{rel}")])

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Saved: #{rel}")
    assert File.read!(Path.join(root, rel)) == "FILE_BYTES"
  end

  test "/file get sends a file back to Telegram" do
    chat_id = 22_222
    root = fresh_root!("lemon-file-get")
    bind_project!(chat_id, root)

    File.write!(Path.join(root, "out.txt"), "hello")

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true}
        }
      )

    FileTransferMockAPI.set_updates([
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

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true}
        }
      )

    FileTransferMockAPI.set_updates([
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

    assert_receive {:send_document, path, _opts}, 300
    assert String.starts_with?(path, Path.expand(root))
    assert String.ends_with?(path, Path.basename(rel))
  end

  test "auto-put stores document with no caption into uploads_dir" do
    chat_id = 33_333
    root = fresh_root!("lemon-auto-put")
    bind_project!(chat_id, root)

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: true, uploads_dir: "incoming"}
        }
      )

    FileTransferMockAPI.set_updates([document_update(chat_id, nil)])

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Uploaded: incoming/example.txt")
    assert File.read!(Path.join(root, "incoming/example.txt")) == "FILE_BYTES"
  end

  test "auto-put batches media_group_id documents into uploads_dir" do
    chat_id = 44_444
    root = fresh_root!("lemon-auto-put-mg")
    bind_project!(chat_id, root)

    mg = "mg-1"

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: true,
            uploads_dir: "incoming",
            media_group_debounce_ms: 50
          }
        }
      )

    FileTransferMockAPI.set_updates([
      document_update_media_group(chat_id, mg, "a.txt"),
      document_update_media_group(chat_id, mg, "b.txt")
    ])

    assert_receive {:sent, text}, 800
    assert String.contains?(text, "Uploaded 2 files")
    assert File.read!(Path.join(root, "incoming/a.txt")) == "FILE_BYTES"
    assert File.read!(Path.join(root, "incoming/b.txt")) == "FILE_BYTES"
  end

  # ---------------------------------------------------------------------------
  # Helpers for new media types
  # ---------------------------------------------------------------------------

  defp photo_update(chat_id, caption \\ nil) do
    base = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "photo" => [
          %{"file_id" => "photo-sm", "width" => 90, "height" => 90, "file_size" => 1000},
          %{"file_id" => "photo-lg", "width" => 800, "height" => 600, "file_size" => 50_000}
        ]
      }
    }

    if is_binary(caption), do: put_in(base, ["message", "caption"], caption), else: base
  end

  defp video_update(chat_id, caption \\ nil) do
    base = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "video" => %{
          "file_id" => "vid-1",
          "file_name" => "clip.mp4",
          "mime_type" => "video/mp4",
          "file_size" => 50_000,
          "duration" => 10,
          "width" => 1920,
          "height" => 1080
        }
      }
    }

    if is_binary(caption), do: put_in(base, ["message", "caption"], caption), else: base
  end

  defp animation_update(chat_id, caption \\ nil) do
    base = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "animation" => %{
          "file_id" => "anim-1",
          "mime_type" => "video/mp4",
          "file_size" => 20_000,
          "duration" => 3,
          "width" => 320,
          "height" => 240
        }
      }
    }

    if is_binary(caption), do: put_in(base, ["message", "caption"], caption), else: base
  end

  defp video_note_update(chat_id, caption \\ nil) do
    base = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "video_note" => %{
          "file_id" => "vnote-1",
          "file_size" => 15_000,
          "duration" => 5,
          "length" => 240
        }
      }
    }

    if is_binary(caption), do: put_in(base, ["message", "caption"], caption), else: base
  end

  defp photo_update_media_group(chat_id, media_group_id, caption \\ nil) do
    base = %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 999, "username" => "tester", "first_name" => "Test"},
        "media_group_id" => media_group_id,
        "photo" => [
          %{"file_id" => "photo-mg-#{System.unique_integer([:positive])}", "width" => 800, "height" => 600, "file_size" => 50_000}
        ]
      }
    }

    if is_binary(caption), do: put_in(base, ["message", "caption"], caption), else: base
  end

  # ---------------------------------------------------------------------------
  # Photo / video / animation / video_note auto-put tests
  # ---------------------------------------------------------------------------

  test "auto-put stores photo with generated filename into uploads_dir" do
    chat_id = 60_001
    root = fresh_root!("lemon-auto-put-photo")
    bind_project!(chat_id, root)

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: true, uploads_dir: "incoming"}
        }
      )

    FileTransferMockAPI.set_updates([photo_update(chat_id)])

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Uploaded: incoming/photo_")
    assert String.contains?(text, ".jpg")

    files = Path.wildcard(Path.join(root, "incoming/photo_*.jpg"))
    assert length(files) == 1
    assert File.read!(hd(files)) == "FILE_BYTES"
  end

  test "auto-put stores video preserving Telegram filename" do
    chat_id = 60_002
    root = fresh_root!("lemon-auto-put-video")
    bind_project!(chat_id, root)

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: true, uploads_dir: "incoming"}
        }
      )

    FileTransferMockAPI.set_updates([video_update(chat_id)])

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Uploaded: incoming/clip.mp4")
    assert File.read!(Path.join(root, "incoming/clip.mp4")) == "FILE_BYTES"
  end

  test "auto-put stores animation with generated filename" do
    chat_id = 60_003
    root = fresh_root!("lemon-auto-put-anim")
    bind_project!(chat_id, root)

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: true, uploads_dir: "incoming"}
        }
      )

    FileTransferMockAPI.set_updates([animation_update(chat_id)])

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Uploaded: incoming/animation_")
    assert String.contains?(text, ".mp4")

    files = Path.wildcard(Path.join(root, "incoming/animation_*.mp4"))
    assert length(files) == 1
    assert File.read!(hd(files)) == "FILE_BYTES"
  end

  test "auto-put stores video_note with generated filename" do
    chat_id = 60_004
    root = fresh_root!("lemon-auto-put-vnote")
    bind_project!(chat_id, root)

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{enabled: true, auto_put: true, uploads_dir: "incoming"}
        }
      )

    FileTransferMockAPI.set_updates([video_note_update(chat_id)])

    assert_receive {:sent, text}, 300
    assert String.contains?(text, "Uploaded: incoming/videonote_")
    assert String.contains?(text, ".mp4")

    files = Path.wildcard(Path.join(root, "incoming/videonote_*.mp4"))
    assert length(files) == 1
    assert File.read!(hd(files)) == "FILE_BYTES"
  end

  test "auto-put batches photo album (media group) into uploads_dir" do
    chat_id = 60_005
    root = fresh_root!("lemon-auto-put-photo-mg")
    bind_project!(chat_id, root)

    mg = "mg-photo-1"

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: true,
            uploads_dir: "incoming",
            media_group_debounce_ms: 50
          }
        }
      )

    FileTransferMockAPI.set_updates([
      photo_update_media_group(chat_id, mg),
      photo_update_media_group(chat_id, mg)
    ])

    assert_receive {:sent, text}, 800
    assert String.contains?(text, "Uploaded 2 files")

    files = Path.wildcard(Path.join(root, "incoming/photo_*.jpg"))
    assert length(files) == 2
    Enum.each(files, fn f -> assert File.read!(f) == "FILE_BYTES" end)
  end

  # ---------------------------------------------------------------------------
  # Inbound normalization tests for new media types
  # ---------------------------------------------------------------------------

  test "inbound normalizes video into meta" do
    update = video_update(70_001)

    {:ok, inbound} =
      LemonChannels.Adapters.Telegram.Inbound.normalize(update)

    assert inbound.meta[:video] != nil
    assert inbound.meta[:video][:file_id] == "vid-1"
    assert inbound.meta[:video][:file_name] == "clip.mp4"
    assert inbound.meta[:video][:mime_type] == "video/mp4"
    assert inbound.meta[:video][:duration] == 10
    assert inbound.meta[:video][:width] == 1920
  end

  test "inbound normalizes animation into meta" do
    update = animation_update(70_002)

    {:ok, inbound} =
      LemonChannels.Adapters.Telegram.Inbound.normalize(update)

    assert inbound.meta[:animation] != nil
    assert inbound.meta[:animation][:file_id] == "anim-1"
    assert inbound.meta[:animation][:mime_type] == "video/mp4"
    assert inbound.meta[:animation][:duration] == 3
  end

  test "inbound normalizes video_note into meta" do
    update = video_note_update(70_003)

    {:ok, inbound} =
      LemonChannels.Adapters.Telegram.Inbound.normalize(update)

    assert inbound.meta[:video_note] != nil
    assert inbound.meta[:video_note][:file_id] == "vnote-1"
    assert inbound.meta[:video_note][:duration] == 5
    assert inbound.meta[:video_note][:length] == 240
  end

  test "/file put batches media_group_id documents into a directory path" do
    chat_id = 55_555
    root = fresh_root!("lemon-file-put-mg")
    bind_project!(chat_id, root)

    mg = "mg-2"

    {:ok, _pid} =
      Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: "token",
          api_mod: FileTransferMockAPI,
          poll_interval_ms: 10,
          files: %{
            enabled: true,
            auto_put: true,
            uploads_dir: "incoming",
            media_group_debounce_ms: 50
          }
        }
      )

    FileTransferMockAPI.set_updates([
      document_update_media_group(chat_id, mg, "c.txt", "/file put incoming/"),
      document_update_media_group(chat_id, mg, "d.txt")
    ])

    assert_receive {:sent, text}, 800
    assert String.contains?(text, "Saved 2 files")
    assert File.read!(Path.join(root, "incoming/c.txt")) == "FILE_BYTES"
    assert File.read!(Path.join(root, "incoming/d.txt")) == "FILE_BYTES"
  end
end
