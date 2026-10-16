defmodule LemonHoncho.SessionNameTest do
  @moduledoc """
  The interesting cases here are not the happy strategies but the two rules
  that protect other people's memory: sanitization must not produce an empty
  id, and truncation must not merge two distinct long keys into one session.
  """

  use ExUnit.Case, async: false

  alias LemonHoncho.Config
  alias LemonHoncho.SessionName

  @max_length 100

  describe "strategies" do
    test "per_session uses the Lemon session id" do
      config = %Config{session_strategy: :per_session}

      assert SessionName.resolve(config, session_id: "sess_abc123", session_key: "cli:local") ==
               "sess_abc123"
    end

    test "per_session falls back to the session key when there is no session id" do
      config = %Config{session_strategy: :per_session}

      assert SessionName.resolve(config, session_key: "telegram-4815162342") ==
               "telegram-4815162342"
    end

    test "per_directory uses the directory basename and ignores the session key" do
      config = %Config{session_strategy: :per_directory}

      assert SessionName.resolve(config, cwd: "/home/z80/dev/lemon", session_key: "cli:local") ==
               "lemon"
    end

    test "global uses the workspace name" do
      config = %Config{session_strategy: :global, workspace: "lemon"}

      assert SessionName.resolve(config, cwd: "/home/z80/dev/lemon", session_id: "sess_1") ==
               "lemon"
    end

    test "per_repo falls back to the directory basename outside a repository" do
      config = %Config{session_strategy: :per_repo}
      cwd = Path.join(System.tmp_dir!(), "lemon-honcho-not-a-repo")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf(cwd) end)

      assert SessionName.resolve(config, cwd: cwd) == "lemon-honcho-not-a-repo"
    end

    @tag :tmp_dir
    test "per_repo names the repository root, not the subdirectory", %{tmp_dir: tmp_dir} do
      if System.find_executable("git") do
        repo = Path.join(tmp_dir, "my repo")
        nested = Path.join(repo, "apps/deep")
        File.mkdir_p!(nested)
        {_output, 0} = System.cmd("git", ["init", "--quiet", repo], stderr_to_stdout: true)

        config = %Config{session_strategy: :per_repo}

        assert SessionName.resolve(config, cwd: nested) == "my-repo"
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

      assert SessionName.resolve(config, cwd: context.cwd) == "provenance-root"
      assert File.read!(Path.join(context.cwd, "git-ran")) == "rev-parse\n--show-toplevel\n"

      assert [{_id, %{backend: :local, workload_identity: identity}, %{}}] =
               LemonCore.NativeProcess.snapshot()

      assert LemonCore.ProcessGroup.valid_identity?(identity)
    end

    test "an unavailable ledger prevents git execution but allows directory fallback", context do
      Application.put_env(:lemon_core, :native_process_ledger, context.ledger)
      refute Process.whereis(LemonCore.NativeProcess)
      config = %Config{session_strategy: :per_repo}

      assert SessionName.resolve(config, cwd: context.cwd) == "fallback-directory"
      refute File.exists?(Path.join(context.cwd, "git-ran"))
      refute File.exists?(context.ledger)
    end
  end

  describe "sanitization" do
    test "collapses anything outside [A-Za-z0-9_-] and trims the edges" do
      config = %Config{session_strategy: :per_session}

      assert SessionName.resolve(config, session_id: "  chat/42 ✨ notes  ") == "chat-42-notes"
      assert SessionName.resolve(config, session_id: "!room:matrix.org") == "room-matrix-org"
    end

    test "never returns an empty id, falling back to the workspace" do
      config = %Config{session_strategy: :per_session, workspace: "lemon"}

      assert SessionName.resolve(config, session_id: "///") == "lemon"
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

      assert String.length(id) <= @max_length
      assert id =~ ~r/-[0-9a-f]{8}\z/
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

    test "a short key is returned untouched" do
      config = %Config{session_strategy: :per_session}

      assert SessionName.resolve(config, session_id: "sess_short") == "sess_short"
    end
  end
end
