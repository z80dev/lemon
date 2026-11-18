defmodule LemonHoncho.SessionNameTest do
  @moduledoc """
  The interesting cases here are not the happy strategies but the rules that
  protect other people's memory: an id is always a readable label plus a digest
  of the full place and identity, sanitization must not produce an empty id or
  merge distinct inputs, and nothing but identical inputs share a session.
  """

  use ExUnit.Case, async: false

  alias LemonHoncho.Config
  alias LemonHoncho.SessionName

  @max_length 100

  defp label!(id) do
    assert [_, label] = Regex.run(~r/\A(.+)-[0-9a-f]{32}\z/, id)
    assert String.length(id) <= @max_length
    label
  end

  describe "strategies" do
    test "per_session labels with the Lemon session id" do
      config = %Config{session_strategy: :per_session}
      id = SessionName.resolve(config, session_id: "sess_abc123", session_key: "cli:local")

      assert label!(id) == "sess_abc123"
      refute id == SessionName.resolve(config, session_id: "sess_other", session_key: "cli:local")
    end

    test "per_session falls back to the session key when there is no session id" do
      config = %Config{session_strategy: :per_session}

      assert label!(SessionName.resolve(config, session_key: "telegram-4815162342")) ==
               "telegram-4815162342"
    end

    test "per_directory labels with the basename but is keyed by the full path" do
      config = %Config{session_strategy: :per_directory}
      id = SessionName.resolve(config, cwd: "/home/z80/dev/lemon", session_key: "agent:a:main")

      assert label!(id) == "lemon"

      assert id ==
               SessionName.resolve(config,
                 cwd: "/home/z80/dev/lemon",
                 session_key: "agent:a:main"
               )

      refute id ==
               SessionName.resolve(config, cwd: "/srv/other/lemon", session_key: "agent:a:main")
    end

    test "the owner and a channel conversation each separate" do
      config = %Config{session_strategy: :per_directory}
      owner = LemonHoncho.Owner.new(config, "agent:a:main", nil, "legacy")
      base = [cwd: "/srv/workspace", session_key: "agent:a:main", owner: owner]
      id = SessionName.resolve(config, base)

      for {key, value} <- [
            session_key: "agent:a:telegram:default:dm:1",
            owner: LemonHoncho.Owner.new(config, "agent:b:main", nil, "legacy"),
            owner:
              LemonHoncho.Owner.new(
                config,
                "agent:a:main",
                %{channel_id: "telegram", sender_id: "1"},
                "legacy"
              ),
            owner: LemonHoncho.Owner.new(config, "agent:a:main", nil, "private:actor-a")
          ] do
        refute id == SessionName.resolve(config, Keyword.put(base, key, value))
      end

      # A main session's subagent stays in the main session's memory.
      assert id ==
               SessionName.resolve(config, Keyword.put(base, :session_key, "agent:a:main:sub:x"))
    end

    test "global labels with the workspace name and is still partitioned by owner" do
      config = %Config{session_strategy: :global, workspace: "lemon"}
      id = SessionName.resolve(config, cwd: "/home/z80/dev/lemon", session_id: "sess_1")
      other = LemonHoncho.Owner.new(config, "agent:b:main", nil, "legacy")

      assert label!(id) == "lemon"
      assert id == SessionName.resolve(config, cwd: "/elsewhere", session_id: "sess_2")
      refute id == SessionName.resolve(config, cwd: "/elsewhere", owner: other)
    end

    test "per_repo falls back to the directory outside a repository" do
      config = %Config{session_strategy: :per_repo}
      cwd = Path.join(System.tmp_dir!(), "lemon-honcho-not-a-repo")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      assert label!(SessionName.resolve(config, cwd: cwd)) == "lemon-honcho-not-a-repo"
    end

    @tag :tmp_dir
    test "per_repo names the repository root, not the subdirectory", %{tmp_dir: tmp_dir} do
      if System.find_executable("git") do
        repo = Path.join(tmp_dir, "my repo")
        nested = Path.join(repo, "apps/deep")
        File.mkdir_p!(nested)
        {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)

        config = %Config{session_strategy: :per_repo}
        id = SessionName.resolve(config, cwd: nested)

        assert label!(id) == "my-repo"
        assert id == SessionName.resolve(config, cwd: repo)
      end
    end
  end

  describe "per_repo native-process provenance" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      original_ledger = Application.fetch_env(:lemon_core, :native_process_ledger)
      original_path = System.get_env("PATH")
      bin = Path.join(tmp_dir, "bin")
      cwd = Path.join(tmp_dir, "fallback-directory")
      File.mkdir_p!(bin)
      File.mkdir_p!(cwd)

      git = Path.join(bin, "git")

      File.write!(git, """
      #!/bin/sh
      printf '%s\\n' "$@" > git-ran
      printf '/repo/provenance-root\\n'
      """)

      File.chmod!(git, 0o755)
      System.put_env("PATH", bin <> ":" <> (original_path || ""))

      on_exit(fn ->
        if pid = Process.whereis(LemonCore.NativeProcess), do: GenServer.stop(pid)

        if :dets.info(:lemon_native_processes_dets) != :undefined,
          do: :dets.close(:lemon_native_processes_dets)

        case original_ledger do
          {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
          :error -> Application.delete_env(:lemon_core, :native_process_ledger)
        end

        if original_path,
          do: System.put_env("PATH", original_path),
          else: System.delete_env("PATH")
      end)

      %{cwd: cwd, ledger: Path.join(tmp_dir, "native-processes.dets")}
    end

    test "records the git lookup before returning the repository name", context do
      :ok = LemonCore.NativeProcess.configure!(context.ledger)
      config = %Config{session_strategy: :per_repo}

      assert label!(SessionName.resolve(config, cwd: context.cwd)) == "provenance-root"
      assert File.read!(Path.join(context.cwd, "git-ran")) == "rev-parse\n--show-toplevel\n"

      assert [{_id, %{backend: :local, workload_identity: identity}, %{}}] =
               LemonCore.NativeProcess.snapshot()

      assert LemonCore.ProcessGroup.valid_identity?(identity)
    end

    test "an unavailable ledger prevents git execution but allows directory fallback", context do
      Application.put_env(:lemon_core, :native_process_ledger, context.ledger)
      refute Process.whereis(LemonCore.NativeProcess)
      config = %Config{session_strategy: :per_repo}

      assert label!(SessionName.resolve(config, cwd: context.cwd)) == "fallback-directory"
      refute File.exists?(Path.join(context.cwd, "git-ran"))
      refute File.exists?(context.ledger)
    end
  end

  describe "sanitization" do
    test "collapses anything outside [A-Za-z0-9_-] in the label and trims the edges" do
      config = %Config{session_strategy: :per_session}

      assert label!(SessionName.resolve(config, session_id: "  chat/42 ✨ notes  ")) ==
               "chat-42-notes"

      assert label!(SessionName.resolve(config, session_id: "!room:matrix.org")) ==
               "room-matrix-org"
    end

    test "inputs that sanitize to the same label are still different sessions" do
      config = %Config{session_strategy: :per_session}

      refute SessionName.resolve(config, session_id: "a:b") ==
               SessionName.resolve(config, session_id: "a/b")
    end

    test "never returns an empty label, falling back to the workspace" do
      config = %Config{session_strategy: :per_session, workspace: "lemon"}

      assert label!(SessionName.resolve(config, session_id: "///")) == "lemon"
    end

    test "falls back past an unusable workspace to a constant" do
      config = %Config{session_strategy: :per_session, workspace: "***"}

      assert SessionName.resolve(config, session_id: "!!!") =~ ~r/\A[A-Za-z0-9_-]+\z/
    end
  end

  describe "the 100-character limit" do
    test "an over-long key is truncated to the limit" do
      config = %Config{session_strategy: :per_session}
      id = SessionName.resolve(config, session_id: String.duplicate("a", 200))

      assert String.length(id) == @max_length
      assert id =~ ~r/-[0-9a-f]{32}\z/
    end

    test "two long keys sharing a prefix do not collide" do
      config = %Config{session_strategy: :per_session}
      shared = String.duplicate("a", 150)

      first = SessionName.resolve(config, session_id: shared <> String.duplicate("b", 50))
      second = SessionName.resolve(config, session_id: shared <> String.duplicate("c", 50))

      assert String.length(first) == @max_length
      assert String.length(second) == @max_length
      assert first != second
    end

    test "resolution is deterministic for the same key" do
      config = %Config{session_strategy: :per_session}
      key = String.duplicate("session-key-", 30)

      assert SessionName.resolve(config, session_id: key) ==
               SessionName.resolve(config, session_id: key)
    end
  end
end
