defmodule LemonChannels.Adapters.Telegram.FileAccessTest do
  @moduledoc """
  `/file` and `/cwd` stay inside operator-configured projects: symlinks,
  secrets, traversal in upload names, DM senders and chat-written projects,
  exercised through the real Telegram transport with a fake Bot API.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.BindingResolver
  alias LemonCore.{ChatScope, ProjectBindingStore, Store}

  defmodule MockAPI do
    @updates_key {__MODULE__, :updates}
    @pid_key {__MODULE__, :pid}
    @download_key {__MODULE__, :download}

    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)
    def register(pid), do: :persistent_term.put(@pid_key, pid)
    def set_download(name), do: :persistent_term.put(@download_key, name)

    def get_updates(_token, _offset, _timeout_ms) do
      case :persistent_term.get(@updates_key, []) do
        [first | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [first]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def get_file(_token, _file_id),
      do: {:ok, %{"ok" => true, "result" => %{"file_path" => "doc.bin"}}}

    def download_file(_token, _file_path), do: {:ok, "UPLOADED_BYTES"}

    # Capture the bytes at send time: the transport may send a private copy.
    def send_document(_token, _chat_id, {:path, path}, _opts) do
      notify({:send_document, Path.basename(path), File.read!(path)})
      {:ok, %{"ok" => true}}
    end

    def send_message(_token, _chat_id, text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      notify({:sent, text})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end

    def get_chat_member(_token, _chat_id, _user_id),
      do: {:ok, %{"ok" => true, "result" => %{"status" => "member"}}}

    defp notify(msg) do
      if pid = :persistent_term.get(@pid_key, nil), do: send(pid, msg)
      :ok
    end
  end

  @gateway_config_key :gateway_test_config

  @user_id 4_200_001

  setup do
    unless Process.whereis(LemonChannels.Adapters.Telegram.AsyncSupervisor) do
      start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor})
    end

    stop_transport()
    MockAPI.register(self())
    previous = Application.get_env(:lemon_core, @gateway_config_key)

    root = fresh_dir!("lemon-file-access-root")
    outside = fresh_dir!("lemon-file-access-outside")
    File.write!(Path.join(outside, "secret.txt"), "OUTSIDE_SECRET")

    case LemonChannels.Registry.register(LemonChannels.Adapters.Telegram) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    on_exit(fn ->
      stop_transport()
      _ = LemonChannels.Registry.unregister("telegram")
      :persistent_term.erase({MockAPI, :updates})
      :persistent_term.erase({MockAPI, :pid})

      if previous,
        do: Application.put_env(:lemon_core, @gateway_config_key, previous),
        else: Application.delete_env(:lemon_core, @gateway_config_key)

      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    %{root: root, outside: outside}
  end

  describe "/file get" do
    test "refuses a symlinked file and a symlinked directory inside the workspace", %{
      root: root,
      outside: outside
    } do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "link.txt"))
      File.ln_s!(outside, Path.join(root, "linkdir"))
      start_files(root, %{})

      send_dm("/file get link.txt")
      assert_receive {:sent, text}, 2_000
      assert text =~ "Symlinks are not allowed"
      refute text =~ outside

      send_dm("/file get linkdir/secret.txt")
      assert_receive {:sent, text}, 2_000
      assert text =~ "Symlinks are not allowed"

      refute_receive {:send_document, _, _}, 200
    end

    test "a directory archive never contains secrets, VCS metadata or symlink targets", %{
      root: root,
      outside: outside
    } do
      File.write!(Path.join(root, "readme.md"), "hello")
      File.write!(Path.join(root, ".env"), "API_KEY=1")
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/config"), "[core]")
      File.mkdir_p!(Path.join(root, "src"))
      File.write!(Path.join(root, "src/app.ex"), "code")
      File.write!(Path.join(root, "src/.env.local"), "LOCAL=1")
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "src/leak.txt"))
      # A symlinked folder inside the archived directory is skipped, not followed.
      File.ln_s!(outside, Path.join(root, "src/linkdir"))
      start_files(root, %{})

      send_dm("/file get .")
      assert_receive {:send_document, _name, zip}, 2_000
      {:ok, entries} = :zip.unzip(zip, [:memory])
      names = entries |> Enum.map(fn {name, _} -> to_string(name) end) |> Enum.sort()

      assert names == ["readme.md", "src/app.ex"]
      refute Enum.any?(entries, fn {_, bytes} -> bytes == "OUTSIDE_SECRET" end)
    end

    test "a .env file is refused directly even without configured deny globs", %{root: root} do
      File.write!(Path.join(root, ".env"), "API_KEY=1")
      start_files(root, %{})

      send_dm("/file get .env")
      assert_receive {:sent, "Access denied for that path."}, 2_000
      refute_receive {:send_document, _, _}, 200
    end

    test "a DM from a sender outside allowed_user_ids is refused", %{root: root} do
      File.write!(Path.join(root, "out.txt"), "hello")
      start_files(root, %{allowed_user_ids: [@user_id + 1]}, allow_all_chats: true)

      send_dm("/file get out.txt")
      assert_receive {:sent, "File downloads are restricted."}, 2_000
      refute_receive {:send_document, _, _}, 200
    end

    test "an allowlisted DM sender still downloads", %{root: root} do
      File.write!(Path.join(root, "out.txt"), "hello")
      start_files(root, %{allowed_user_ids: [@user_id]}, allow_all_chats: true)

      send_dm("/file get out.txt")
      assert_receive {:send_document, "out.txt", "hello"}, 2_000
    end
  end

  describe "/file put" do
    test "refuses a symlinked destination file and directory", %{root: root, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "target.txt"))
      File.ln_s!(outside, Path.join(root, "linkdir"))
      start_files(root, %{})

      send_dm_document("/file put --force target.txt", "doc.txt")
      assert_receive {:sent, text}, 2_000
      assert text =~ "Symlinks are not allowed"

      send_dm_document("/file put linkdir/new.txt", "doc.txt")
      assert_receive {:sent, text}, 2_000
      assert text =~ "Symlinks are not allowed"

      assert File.read!(Path.join(outside, "secret.txt")) == "OUTSIDE_SECRET"
      refute File.exists?(Path.join(outside, "new.txt"))
    end

    test "an upload file name is reduced to its basename", %{root: root} do
      File.mkdir_p!(Path.join(root, ".git/hooks"))
      start_files(root, %{})

      send_dm_document("/file put", "../.git/hooks/pre-commit")
      assert_receive {:sent, "Saved: incoming/pre-commit"}, 2_000

      assert File.read!(Path.join(root, "incoming/pre-commit")) == "UPLOADED_BYTES"
      refute File.exists?(Path.join(root, ".git/hooks/pre-commit"))
    end

    test "uploads into .git or a newly named denied file are refused", %{root: root} do
      start_files(root, %{deny_globs: ["**/*.pem"]})

      send_dm_document("/file put .git/hooks/pre-commit", "x")
      assert_receive {:sent, "Access denied for that path."}, 2_000

      send_dm_document("/file put keys/new.pem", "x")
      assert_receive {:sent, "Access denied for that path."}, 2_000

      refute File.exists?(Path.join(root, ".git"))
      refute File.exists?(Path.join(root, "keys/new.pem"))
    end
  end

  describe "case-insensitive filesystem" do
    @describetag :case_insensitive_fs

    test "/file get of .ENV and .GiT/config is denied", %{root: root} do
      File.write!(Path.join(root, ".env"), "API_KEY=1")
      File.write!(Path.join(root, ".env.local"), "LOCAL=1")
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/config"), "[core]")
      start_files(root, %{})

      for path <- [".ENV", ".GiT/config", ".Env.Local"] do
        send_dm("/file get #{path}")
        assert_receive {:sent, "Access denied for that path."}, 2_000
      end

      refute_receive {:send_document, _, _}, 200
    end

    test "/file put of .ENV and .GiT/config is denied", %{root: root} do
      File.write!(Path.join(root, ".env"), "API_KEY=1")
      File.mkdir_p!(Path.join(root, ".git/hooks"))
      File.write!(Path.join(root, ".git/config"), "[core]")
      start_files(root, %{})

      for caption <- [
            "/file put --force .ENV",
            "/file put .GiT/config",
            "/file put --force .GiT/config",
            "/file put .GIT/hooks/pre-commit"
          ] do
        send_dm_document(caption, "doc.txt")
        assert_receive {:sent, "Access denied for that path."}, 2_000
      end

      assert File.read!(Path.join(root, ".env")) == "API_KEY=1"
      assert File.read!(Path.join(root, ".git/config")) == "[core]"
      refute File.exists?(Path.join(root, ".git/hooks/pre-commit"))
    end
  end

  describe "deny_globs grammar" do
    setup %{root: root} do
      File.mkdir_p!(Path.join(root, "keys"))
      File.write!(Path.join(root, "keys/server.key"), "KEY")
      File.write!(Path.join(root, "cert.pem"), "PEM")
      File.write!(Path.join(root, "UPPER.PEM"), "PEM")
      File.write!(Path.join(root, "secret1.txt"), "S1")
      File.write!(Path.join(root, "secretx.txt"), "SX")
      File.write!(Path.join(root, "readme.md"), "hello")
      :ok
    end

    test "brace alternatives and character classes deny /file get", %{root: root} do
      start_files(root, %{deny_globs: ["**/*.{pem,key}", "secret[0-9].txt"]})

      for path <- ["keys/server.key", "cert.pem", "UPPER.PEM", "secret1.txt"] do
        send_dm("/file get #{path}")
        assert_receive {:sent, "Access denied for that path."}, 2_000
      end

      refute_receive {:send_document, _, _}, 200

      send_dm("/file get secretx.txt")
      assert_receive {:send_document, "secretx.txt", "SX"}, 2_000
    end

    test "brace alternatives and character classes deny /file put of a new file", %{
      root: root
    } do
      start_files(root, %{deny_globs: ["**/*.{pem,key}", "secret[0-9].txt"]})

      for caption <- [
            "/file put keys/new.key",
            "/file put nested/new.pem",
            "/file put secret2.txt"
          ] do
        send_dm_document(caption, "doc.txt")
        assert_receive {:sent, "Access denied for that path."}, 2_000
      end

      refute File.exists?(Path.join(root, "keys/new.key"))
      refute File.exists?(Path.join(root, "nested"))
      refute File.exists?(Path.join(root, "secret2.txt"))
    end

    test "brace alternatives and character classes are excluded from directory archives", %{
      root: root
    } do
      start_files(root, %{deny_globs: ["**/*.{pem,key}", "secret[0-9].txt"]})

      send_dm("/file get .")
      assert_receive {:send_document, _name, zip}, 2_000
      {:ok, entries} = :zip.unzip(zip, [:memory])
      names = entries |> Enum.map(fn {name, _} -> to_string(name) end) |> Enum.sort()

      assert names == ["readme.md", "secretx.txt"]
    end

    test "** excludes entries below directory names containing newlines from archives", %{
      root: root
    } do
      dir = Path.join(root, "nested\ndir")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "hidden.key"), "NEWLINE_KEY")
      start_files(root, %{deny_globs: ["**/*.{pem,key}", "secret[0-9].txt"]})

      send_dm("/file get .")
      assert_receive {:send_document, _name, zip}, 2_000
      {:ok, entries} = :zip.unzip(zip, [:memory])
      names = entries |> Enum.map(fn {name, _} -> to_string(name) end) |> Enum.sort()

      assert names == ["readme.md", "secretx.txt"]
    end

    test "a malformed glob fails closed", %{root: root} do
      for globs <- [["{readme,notes"], ["secret[0-9.txt"], ["{a,{b,c}}"]] do
        stop_transport()
        start_files(root, %{deny_globs: globs})

        send_dm("/file get readme.md")
        assert_receive {:sent, "Access denied for that path."}, 2_000

        send_dm_document("/file put fresh.txt", "doc.txt")
        assert_receive {:sent, "Access denied for that path."}, 2_000
      end

      refute_receive {:send_document, _, _}, 200
      refute File.exists?(Path.join(root, "fresh.txt"))
    end
  end

  describe "/cwd" do
    test "host paths are refused and never create a global project", %{root: root} do
      chat_id = @user_id
      start_files(root, %{}, bind: false)
      before = Store.list(:projects_dynamic)

      for selector <- ["/", "../../", Path.dirname(root)] do
        send_dm("/cwd #{selector}")
        assert_receive {:sent, text}, 2_000
        assert text =~ "configured project"
        refute text =~ Path.dirname(root)
      end

      assert Store.list(:projects_dynamic) == before
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}
      assert BindingResolver.get_project_override(scope) == nil
      assert BindingResolver.resolve_cwd(scope) == nil
    end

    test "a configured project id resolves and cannot be shadowed by a dynamic row", %{
      root: root,
      outside: outside
    } do
      start_files(root, %{}, projects: %{"lemonproj" => %{root: root}}, bind: false)
      # A legacy chat-written row with the configured id must not win.
      :ok = Store.put(:projects_dynamic, "lemonproj", %{root: outside})
      on_exit(fn -> Store.delete(:projects_dynamic, "lemonproj") end)

      send_dm("/cwd lemonproj")
      assert_receive {:sent, text}, 2_000
      assert text =~ "Working directory set"

      scope = %ChatScope{transport: :telegram, chat_id: @user_id, topic_id: nil}
      assert BindingResolver.resolve_cwd(scope) == Path.expand(root)
    end
  end

  defp start_files(root, files_overrides, opts \\ []) do
    projects = Keyword.get(opts, :projects, %{"fileproj" => %{root: root}})
    token = "file-access-#{System.unique_integer([:positive])}"

    Application.put_env(:lemon_core, @gateway_config_key, %{
      projects: projects,
      bindings: [],
      telegram: %{bot_token: token, api_mod: MockAPI}
    })

    scope = %ChatScope{transport: :telegram, chat_id: @user_id, topic_id: nil}

    if Keyword.get(opts, :bind, true) do
      :ok = ProjectBindingStore.put_override(scope, "fileproj")
    end

    on_exit(fn -> ProjectBindingStore.delete_override(scope) end)

    allowlist =
      if Keyword.get(opts, :allow_all_chats, false),
        do: %{allow_all_chats: true},
        else: %{allowed_chat_ids: [@user_id]}

    config =
      %{
        account_id: "default",
        bot_token: token,
        api_mod: MockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10,
        deny_unbound_chats: false,
        files:
          Map.merge(%{enabled: true, auto_put: false, uploads_dir: "incoming"}, files_overrides)
      }
      |> Map.merge(allowlist)

    {:ok, _pid} = LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
    :ok
  end

  defp send_dm(text) do
    MockAPI.set_updates([
      %{
        "update_id" => System.unique_integer([:positive]),
        "message" => %{
          "message_id" => System.unique_integer([:positive]),
          "date" => 1,
          "chat" => %{"id" => @user_id, "type" => "private"},
          "from" => %{"id" => @user_id, "username" => "owner", "first_name" => "O"},
          "text" => text
        }
      }
    ])
  end

  defp send_dm_document(caption, file_name) do
    MockAPI.set_updates([
      %{
        "update_id" => System.unique_integer([:positive]),
        "message" => %{
          "message_id" => System.unique_integer([:positive]),
          "date" => 1,
          "chat" => %{"id" => @user_id, "type" => "private"},
          "from" => %{"id" => @user_id, "username" => "owner", "first_name" => "O"},
          "caption" => caption,
          "document" => %{
            "file_id" => "doc-#{System.unique_integer([:positive])}",
            "file_name" => file_name,
            "mime_type" => "text/plain",
            "file_size" => 14
          }
        }
      }
    ])
  end

  defp fresh_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp stop_transport do
    if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end
end
