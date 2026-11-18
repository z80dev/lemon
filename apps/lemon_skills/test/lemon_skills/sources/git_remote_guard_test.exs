defmodule LemonSkills.Sources.GitRemoteGuardTest do
  # Mutates PATH and GIT_* environment variables, so it runs alone.
  use ExUnit.Case, async: false

  alias LemonSkills.Sources.Git

  @moduletag :tmp_dir

  @public {93, 184, 216, 34}

  setup %{tmp_dir: tmp_dir} do
    saved = System.get_env()
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)

    on_exit(fn ->
      for {name, _} <- System.get_env(),
          not Map.has_key?(saved, name),
          do: System.delete_env(name)

      System.put_env(saved)
    end)

    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    {:ok, bin: bin}
  end

  defp resolver, do: fn "skills.example" -> {:ok, [@public]} end

  # An `ssh` that records its arguments, then serves the requested repository
  # with the local `git upload-pack`, so ssh clones run without a network.
  defp fake_ssh!(bin, tmp_dir) do
    log = Path.join(tmp_dir, "ssh-args")

    write_script!(Path.join(bin, "ssh"), """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{log}'
    for last; do :; done
    exec sh -c "git ${last#git-}"
    """)

    log
  end

  defp write_script!(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp create_repo!(tmp_dir, name, extra \\ %{}) do
    repo = Path.join(tmp_dir, name)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "SKILL.md"), "---\nname: #{name}\ndescription: d\n---\nBody\n")
    Enum.each(extra, fn {file, bytes} -> File.write!(Path.join(repo, file), bytes) end)
    git!(repo, ["init", "--quiet", "--initial-branch=main"])
    git!(repo, ["add", "."])
    git!(repo, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "init"])
    repo
  end

  defp git!(repo, args) do
    {out, 0} =
      System.cmd("git", args,
        cd: repo,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
      )

    String.trim(out)
  end

  defp start_listener do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    test = self()

    pid =
      spawn_link(fn ->
        Stream.repeatedly(fn -> :gen_tcp.accept(listen) end)
        |> Enum.each(fn
          {:ok, socket} ->
            send(test, :connected)
            :gen_tcp.close(socket)

          _ ->
            :ok
        end)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  test "loopback and private destinations are refused before git connects", %{tmp_dir: tmp_dir} do
    port = start_listener()
    dest = Path.join(tmp_dir, "installed")

    for url <- [
          "http://127.0.0.1:#{port}/skill.git",
          "http://localhost:#{port}/skill.git",
          "https://10.0.0.5/skill.git",
          "https://169.254.169.254/latest"
        ] do
      assert {:error, _} = Git.fetch(url, dest, timeout_ms: 5_000)
      assert {:error, _} = Git.upstream_hash(url, timeout_ms: 5_000)
    end

    refute_receive :connected, 300
    refute File.exists?(dest)
  end

  test "local, file and helper transports are refused", %{tmp_dir: tmp_dir} do
    repo = create_repo!(tmp_dir, "local")
    dest = Path.join(tmp_dir, "installed")

    for url <- [repo, "file://" <> repo, "ext::sh -c true", "fd::3", "--upload-pack=x"] do
      assert {:error, :invalid_git_url} = Git.fetch(url, dest, [])
      assert {:error, :invalid_git_url} = Git.upstream_hash(url, [])
      refute File.exists?(Path.join(dest, "SKILL.md"))
    end
  end

  test "option-injection, credential and address-alias forms are refused", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "installed")

    for url <- [
          "https://user@skills.example/acme/skill.git",
          "https://evil.example#@skills.example/x",
          "ssh://-oProxyCommand=touch/x",
          "-oProxyCommand=touch@skills.example:x",
          "git@skills.example:-oProxyCommand=touch",
          "ssh://git@[::1]/x"
        ] do
      assert {:error, :invalid_git_url} = Git.fetch(url, dest, resolver: resolver())
    end

    for url <- ["https://2130706433/x", "https://0x7f.1/x", "ssh://git@[::ffff:127.0.0.1]/x"] do
      assert {:error, _} = Git.fetch(url, dest, timeout_ms: 2_000)
    end

    assert {:error, :invalid_branch} =
             Git.fetch("ssh://git@skills.example/x", dest,
               resolver: resolver(),
               branch: "--upload-pack=touch"
             )

    refute File.exists?(dest)
  end

  describe "operator-allowed private git hosts" do
    setup do
      path = LemonCore.Paths.global_config()
      previous = File.read(path)
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      [skills]
      allowed_private_git_hosts = ["Gitea.Internal"]
      """)

      LemonCore.Config.reload()

      on_exit(fn ->
        case previous do
          {:ok, content} -> File.write!(path, content)
          _ -> File.rm(path)
        end

        LemonCore.Config.reload()
      end)

      :ok
    end

    test "a listed host may be private and is still pinned; others are refused",
         %{tmp_dir: tmp_dir, bin: bin} do
      log = fake_ssh!(bin, tmp_dir)
      repo = create_repo!(tmp_dir, "internal")
      dest = Path.join(tmp_dir, "installed")

      resolver = fn
        "gitea.internal" -> {:ok, [{10, 0, 0, 5}]}
        "other.internal" -> {:ok, [{10, 0, 0, 6}]}
      end

      assert {:ok, ^dest} =
               Git.fetch("ssh://git@gitea.internal#{repo}", dest, resolver: resolver)

      assert File.exists?(Path.join(dest, "SKILL.md"))
      args = log |> File.read!() |> String.split("\n", trim: true)
      assert "HostName=10.0.0.5" in args
      assert "HostKeyAlias=gitea.internal" in args

      assert {:ok, remote} =
               LemonSkills.GitRemote.authorize("https://gitea.internal/acme/skill.git",
                 resolver: resolver
               )

      assert {"http.curloptResolve", "gitea.internal:443:10.0.0.5"} in LemonSkills.GitRemote.config(
               remote
             )

      other = Path.join(tmp_dir, "other")

      assert {:error, :destination_not_public} =
               Git.fetch("ssh://git@other.internal#{repo}", other, resolver: resolver)

      refute File.exists?(other)
    end

    test "metadata stays refused even under a listed name", %{tmp_dir: tmp_dir} do
      assert {:error, :metadata_blocked} =
               Git.fetch("ssh://git@gitea.internal/x", Path.join(tmp_dir, "installed"),
                 resolver: fn _ -> {:ok, [{169, 254, 169, 254}]} end
               )
    end

    test "project config cannot list private git hosts", %{tmp_dir: tmp_dir} do
      {merged, rejected} =
        LemonCore.Config.ProjectLayer.merge(%{}, %{
          "skills" => %{"allowed_private_git_hosts" => ["other.internal"]}
        })

      refute get_in(merged, ["skills", "allowed_private_git_hosts"])
      assert {"skills.allowed_private_git_hosts", :operator_only} in rejected

      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(Path.join(project, ".lemon"))

      File.write!(Path.join([project, ".lemon", "config.toml"]), """
      [skills]
      allowed_private_git_hosts = ["other.internal"]
      """)

      assert {:error, :destination_not_public} =
               Git.fetch("ssh://git@other.internal/x", Path.join(tmp_dir, "installed"),
                 cwd: project,
                 resolver: fn _ -> {:ok, [{10, 0, 0, 6}]} end
               )
    end
  end

  test "inherited GIT_* environment cannot select a program", %{tmp_dir: tmp_dir, bin: bin} do
    fake_ssh!(bin, tmp_dir)
    repo = create_repo!(tmp_dir, "envsafe")
    marker = Path.join(tmp_dir, "marker")
    hostile = Path.join(tmp_dir, "hostile-ssh")
    write_script!(hostile, "#!/bin/sh\ntouch '#{marker}'\nexit 1\n")
    System.put_env("GIT_SSH_COMMAND", hostile)
    System.put_env("GIT_SSH", hostile)
    dest = Path.join(tmp_dir, "installed")

    assert {:ok, ^dest} =
             Git.fetch("ssh://git@skills.example#{repo}", dest, resolver: resolver())

    assert File.exists?(Path.join(dest, "SKILL.md"))
    refute File.exists?(marker)
  end

  test "ssh clones are pinned to the authorized address and keep the host identity",
       %{tmp_dir: tmp_dir, bin: bin} do
    log = fake_ssh!(bin, tmp_dir)
    repo = create_repo!(tmp_dir, "pinned")
    dest = Path.join(tmp_dir, "installed")
    head = git!(repo, ["rev-parse", "HEAD"])

    assert {:ok, ^dest} = Git.fetch("git@skills.example:#{repo}", dest, resolver: resolver())
    assert File.read!(Path.join(dest, "SKILL.md")) =~ "pinned"
    refute File.exists?(Path.join(dest, ".git"))

    args = log |> File.read!() |> String.split("\n", trim: true)
    assert "HostName=93.184.216.34" in args
    assert "HostKeyAlias=skills.example" in args
    assert "BatchMode=yes" in args
    assert "ProxyCommand=none" in args

    assert {:ok, ^head} =
             Git.upstream_hash("ssh://git@skills.example#{repo}", resolver: resolver())
  end

  test "http(s) remotes are pinned through curl, without redirects or proxies" do
    alias LemonSkills.GitRemote

    assert {:ok, remote} =
             GitRemote.authorize("https://skills.example/acme/skill.git", resolver: resolver())

    config = GitRemote.config(remote)
    assert {"http.curloptResolve", "skills.example:443:93.184.216.34"} in config
    assert {"http.followRedirects", "false"} in config
    assert {"http.proxy", ""} in config
    assert {"protocol.allow", "never"} in config
    assert {"protocol.https.allow", "always"} in config
    refute Enum.any?(config, fn {key, _} -> key == "protocol.file.allow" end)

    System.put_env("HTTPS_PROXY", "http://10.0.0.1:3128")
    System.put_env("GIT_CONFIG_PARAMETERS", "'core.sshCommand'='touch /tmp/x'")
    env = GitRemote.env("/tmp/lemon-git-1")
    assert {~c"HTTPS_PROXY", false} in env
    assert {~c"GIT_CONFIG_PARAMETERS", false} in env
    assert {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"} in env
  end

  test "falls back to the remote HEAD when the requested branch is absent",
       %{tmp_dir: tmp_dir, bin: bin} do
    fake_ssh!(bin, tmp_dir)
    repo = create_repo!(tmp_dir, "fallback")
    dest = Path.join(tmp_dir, "installed")

    assert {:ok, ^dest} =
             Git.fetch("ssh://git@skills.example#{repo}", dest,
               resolver: resolver(),
               branch: "missing-branch"
             )

    assert File.exists?(Path.join(dest, "SKILL.md"))
    refute File.exists?(Path.join(dest, ".git"))
  end

  test "returns bounded source errors for unavailable repositories",
       %{tmp_dir: tmp_dir, bin: bin} do
    fake_ssh!(bin, tmp_dir)
    url = "ssh://git@skills.example#{Path.join(tmp_dir, "missing-repository")}"
    dest = Path.join(tmp_dir, "installed")

    assert {:error, {:clone_failed, message}} = Git.fetch(url, dest, resolver: resolver())
    assert is_binary(message) and message != ""
    refute File.exists?(dest)

    assert {:error, {:ls_remote_failed, remote_message}} =
             Git.upstream_hash(url, resolver: resolver())

    assert is_binary(remote_message) and remote_message != ""
  end

  test "a stalled remote is killed at the deadline", %{tmp_dir: tmp_dir, bin: bin} do
    write_script!(Path.join(bin, "ssh"), "#!/bin/sh\nexec sleep 15\n")
    dest = Path.join(tmp_dir, "installed")

    task =
      Task.async(fn ->
        Git.fetch("ssh://git@skills.example/stall.git", dest,
          resolver: resolver(),
          timeout_ms: 1_000
        )
      end)

    assert {:ok, {:error, :timeout}} =
             Task.yield(task, 8_000) || Task.shutdown(task, :brutal_kill)

    refute File.exists?(dest)
  end

  test "a clone larger than the cap is refused and removed", %{tmp_dir: tmp_dir, bin: bin} do
    fake_ssh!(bin, tmp_dir)
    big = :crypto.strong_rand_bytes(2 * 1024 * 1024)
    repo = create_repo!(tmp_dir, "large", %{"blob.bin" => big})
    dest = Path.join(tmp_dir, "installed")

    assert {:error, :clone_too_large} =
             Git.fetch("ssh://git@skills.example#{repo}", dest,
               resolver: resolver(),
               max_bytes: 512 * 1024
             )

    refute File.exists?(dest)
  end

  # A transfer that keeps writing progress while the pack grows must still be
  # cut off by size, not only at the deadline.
  test "constant remote output cannot postpone the size cap", %{tmp_dir: tmp_dir, bin: bin} do
    write_script!(Path.join(bin, "git"), """
    #!/bin/sh
    for last; do :; done
    mkdir -p "$last/.git/objects/pack"
    while :; do
      echo "remote: Counting objects: still going"
      head -c 65536 /dev/zero >> "$last/.git/objects/pack/tmp_pack"
      sleep 0.01
    done
    """)

    dest = Path.join(tmp_dir, "installed")
    started = System.monotonic_time(:millisecond)

    assert {:error, :clone_too_large} =
             Git.fetch("ssh://git@skills.example/flood.git", dest,
               resolver: resolver(),
               max_bytes: 512 * 1024,
               timeout_ms: 20_000
             )

    assert System.monotonic_time(:millisecond) - started < 10_000
    refute File.exists?(dest)
  end

  test "user ssh configuration cannot forward, proxy or redirect the pinned connection",
       %{tmp_dir: tmp_dir} do
    hostile = Path.join(tmp_dir, "ssh_config")

    File.write!(hostile, """
    Host *
      HostName evil.example
      ProxyCommand nc evil.example 22
      ProxyJump jump.example
      ForwardAgent yes
      ForwardX11 yes
      LocalForward 9999 localhost:22
      RemoteForward 9998 localhost:22
      DynamicForward 9997
      ControlMaster auto
      ControlPath #{tmp_dir}/cm-%r
      PermitLocalCommand yes
      LocalCommand touch #{tmp_dir}/pwned
      BatchMode no
    """)

    {:ok, remote} =
      LemonSkills.GitRemote.authorize("git@skills.example:acme/skill.git", resolver: resolver())

    {"core.sshCommand", command} =
      List.keyfind(LemonSkills.GitRemote.config(remote), "core.sshCommand", 0)

    # `-F` stands in for the operator's ~/.ssh/config; `-G` prints the
    # effective options without connecting.
    {output, 0} =
      System.cmd("sh", ["-c", "#{command} -F '#{hostile}' -G git@skills.example"],
        stderr_to_stdout: true
      )

    lines = String.split(output, "\n", trim: true)

    for expected <- [
          "hostname 93.184.216.34",
          "hostkeyalias skills.example",
          "batchmode yes",
          "forwardagent no",
          "forwardx11 no",
          "clearallforwardings yes",
          "permitlocalcommand no",
          "controlmaster false"
        ],
        do: assert(expected in lines, expected)

    for prefix <- ~w(proxycommand proxyjump localforward remoteforward dynamicforward controlpath),
        do: refute(Enum.any?(lines, &String.starts_with?(&1, prefix <> " ")), prefix)
  end
end
