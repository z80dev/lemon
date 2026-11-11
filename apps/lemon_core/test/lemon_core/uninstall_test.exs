defmodule LemonCore.UninstallTest do
  use ExUnit.Case, async: true

  alias LemonCore.Uninstall

  @moduletag :tmp_dir

  @comment "# added by the lemon installer"
  @path_line ~s(export PATH="$HOME/.lemon/bin:$PATH")

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    launcher = Path.join(tmp_dir, "lemon")
    File.write!(launcher, "#!/bin/sh\n")
    File.chmod!(launcher, 0o755)

    manifest = Path.join(tmp_dir, "manifest")
    File.write!(manifest, "")
    File.chmod!(manifest, 0o600)

    {:ok, home: home, launcher: launcher, manifest: manifest}
  end

  # Default options keep every outside seam injected and silent: no service
  # manager, no launcher command, no rc file and no manifest unless a test
  # asks for one.
  defp opts(ctx, overrides \\ []) do
    Keyword.merge(
      [
        home: ctx.home,
        env: %{},
        os: :linux,
        cli_launcher: :release,
        units: [],
        rc_files: [],
        launcher: ctx.launcher,
        manifest_path: ctx.manifest,
        status_fn: fn _roles, _opts -> {:ok, %{schema: 1, units: []}} end,
        uninstall_fn: fn _roles, _opts -> {:ok, %{schema: 1, units: []}} end,
        command_runner: fn _executable, args, _opts ->
          case args do
            ["__update-daemon", "snapshot"] -> {"stopped\n", 0}
            _ -> {"", 0}
          end
        end
      ],
      overrides
    )
  end

  defp installed_release(home) do
    for dir <- ~w(versions bin updates tmp) do
      File.mkdir_p!(Path.join([home, ".lemon", dir]))
    end

    File.mkdir_p!(Path.join([home, ".lemon", "lemon_bot", "versions"]))
    File.mkdir_p!(Path.join([home, ".local", "bin"]))
    File.write!(Path.join([home, ".local", "bin", "lemon-bot"]), "#!/bin/sh\n")
    :ok
  end

  defp rc_file(home, name, body) do
    path = Path.join(home, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp installed_rc(home, name) do
    rc_file(home, name, """
    export EDITOR=vim

    #{@comment}
    #{@path_line}
    """)
  end

  defp unit(overrides) do
    Enum.into(overrides, %{
      role: "controller",
      name: nil,
      port: 4040,
      manager: "launchd",
      label: "org.lemon.controller",
      path: "/units/org.lemon.controller.plist",
      state: "ready",
      fingerprint: String.duplicate("1", 64),
      options: [port: 4040]
    })
  end

  defp removed(unit, extra \\ %{}) do
    {:ok,
     %{
       schema: 1,
       units: [
         Map.merge(
           %{
             role: unit.role,
             name: unit.name,
             label: unit.label,
             installed: false,
             state: "not_installed",
             action: "removed"
           },
           extra
         )
       ]
     }}
  end

  describe "preview/1 candidate set" do
    test "lists the exact installer-managed program paths that exist", ctx do
      installed_release(ctx.home)

      {:ok, preview} = Uninstall.preview(opts(ctx))

      assert preview.program_paths == [
               Path.join([ctx.home, ".lemon", "versions"]),
               Path.join([ctx.home, ".lemon", "bin"]),
               Path.join([ctx.home, ".lemon", "updates"]),
               Path.join([ctx.home, ".lemon", "tmp"]),
               Path.join([ctx.home, ".lemon", "lemon_bot", "versions"]),
               Path.join([ctx.home, ".local", "bin", "lemon-bot"])
             ]

      refute Path.join(ctx.home, ".lemon") in preview.program_paths
      refute preview.purge
      assert preview.purge_paths == []
      refute preview.keychain
    end

    test "includes a dangling managed symlink and omits absent paths", ctx do
      File.mkdir_p!(Path.join([ctx.home, ".lemon", "lemon_bot"]))

      File.ln_s!(
        Path.join([ctx.home, ".lemon", "lemon_bot", "versions", "gone"]),
        Path.join([ctx.home, ".lemon", "lemon_bot", "current"])
      )

      {:ok, preview} = Uninstall.preview(opts(ctx))

      assert preview.program_paths == [Path.join([ctx.home, ".lemon", "lemon_bot", "current"])]
    end

    test "--purge adds the data directory and, on macOS, the Keychain item", ctx do
      installed_release(ctx.home)

      {:ok, linux} = Uninstall.preview(opts(ctx, purge: true))
      assert linux.purge
      assert linux.purge_paths == [Path.join(ctx.home, ".lemon")]
      refute linux.keychain

      {:ok, darwin} = Uninstall.preview(opts(ctx, purge: true, os: :darwin))
      assert darwin.keychain == "Lemon Secrets/default"
      refute darwin.confirmation_digest == linux.confirmation_digest
    end

    test "a source checkout previews units only, with or without --purge", ctx do
      installed_release(ctx.home)
      installed_rc(ctx.home, ".zshrc")

      units = [unit(label: "org.lemon.controller")]

      for purge <- [false, true] do
        {:ok, preview} =
          Uninstall.preview(
            opts(ctx,
              cli_launcher: :source,
              purge: purge,
              units: units,
              rc_files: [Path.join(ctx.home, ".zshrc")]
            )
          )

        assert preview.source
        assert preview.units == units
        assert preview.program_paths == []
        assert preview.rc_lines == []
        assert preview.purge_paths == []
        refute preview.keychain
        refute preview.purge
      end
    end

    test "rejects symlinked owned ancestors even when the leaf is absent", ctx do
      for relative <- [".lemon", ".lemon/lemon_bot", ".local", ".local/bin"],
          leaf_present? <- [false, true] do
        home = Path.join(ctx.tmp_dir, "home-#{System.unique_integer([:positive])}")
        outside = Path.join(ctx.tmp_dir, "outside-#{System.unique_integer([:positive])}")
        File.mkdir_p!(home)
        File.mkdir_p!(outside)
        sentinel = Path.join(outside, "keep")
        File.write!(sentinel, "external")

        if leaf_present? do
          File.mkdir_p!(Path.join(outside, "versions"))
          File.write!(Path.join(outside, "lemon-bot"), "external executable")
        end

        ancestor = Path.join(home, relative)
        File.mkdir_p!(Path.dirname(ancestor))
        File.ln_s!(outside, ancestor)
        options = opts(%{ctx | home: home}, purge: true)

        assert {:error, :unsafe_uninstall_path} = Uninstall.preview(options)

        assert {:error, :unsafe_uninstall_path} =
                 Uninstall.execute(Keyword.put(options, :confirm, String.duplicate("a", 64)))

        assert File.read!(sentinel) == "external"
        assert File.read!(ctx.manifest) == ""
      end
    end

    test "allows a leaf symlink without following its external target", ctx do
      outside = Path.join(ctx.tmp_dir, "external-release")
      File.mkdir_p!(outside)
      sentinel = Path.join(outside, "keep")
      File.write!(sentinel, "external")
      File.mkdir_p!(Path.join(ctx.home, ".lemon"))
      link = Path.join(ctx.home, ".lemon/versions")
      File.ln_s!(outside, link)
      options = opts(ctx)
      {:ok, preview} = Uninstall.preview(options)

      assert [%{type: "symlink", path: path} = identity] = preview.path_identities
      assert path == Path.join(preview.canonical_home, ".lemon/versions")
      assert Enum.all?(identity.ancestors, &(&1.type == "directory"))

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert [%{"path" => ^path, "type" => "symlink"}] =
               Jason.decode!(File.read!(ctx.manifest))["paths"]

      assert File.read!(sentinel) == "external"
      assert {:ok, ^outside} = File.read_link(link)
    end

    test "canonicalizes trusted HOME aliases but not owned ancestors", ctx do
      installed_release(ctx.home)
      alias_home = Path.join(ctx.tmp_dir, "home-alias")
      File.ln_s!(ctx.home, alias_home)
      {:ok, direct} = Uninstall.preview(opts(ctx))
      options = opts(%{ctx | home: alias_home})
      {:ok, aliased} = Uninstall.preview(options)

      assert aliased.canonical_home == direct.canonical_home
      assert aliased.path_identities == direct.path_identities

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(options, :confirm, aliased.confirmation_digest))

      document = Jason.decode!(File.read!(ctx.manifest))
      assert document["home"] == direct.canonical_home

      assert Enum.all?(document["paths"], fn entry ->
               String.starts_with?(entry["path"], direct.canonical_home <> "/")
             end)
    end
  end

  describe "preview/1 rc scanning" do
    test "binds the marker comment and the line directly after it", ctx do
      zshrc = installed_rc(ctx.home, ".zshrc")
      fish = installed_rc(ctx.home, ".config/fish/config.fish")

      {:ok, preview} = Uninstall.preview(opts(ctx, rc_files: [zshrc, fish]))

      assert [first, second] = preview.rc_lines
      assert first.file == zshrc
      assert first.comment == @comment
      assert first.line == @path_line
      assert first.index == 2
      assert second.file == fish
    end

    test "ignores a marker with a blank or missing line after it", ctx do
      blank = rc_file(ctx.home, ".bashrc", "#{@comment}\n\nexport PATH=1\n")
      trailing = rc_file(ctx.home, ".profile", "export PATH=1\n#{@comment}")
      unmarked = rc_file(ctx.home, ".bash_profile", "#{@path_line}\n")
      unrelated = rc_file(ctx.home, ".zshrc", "#{@comment}\necho keep-me\n")

      {:ok, preview} =
        Uninstall.preview(opts(ctx, rc_files: [blank, trailing, unmarked, unrelated]))

      assert preview.rc_lines == []
    end

    test "fails instead of silently skipping an rc path that is not a file", ctx do
      directory = Path.join(ctx.home, ".bashrc")
      File.mkdir_p!(directory)

      assert {:error, :rc_file_changed} = Uninstall.preview(opts(ctx, rc_files: [directory]))
    end
  end

  describe "preview/1 unit discovery" do
    test "propagates a failing unit status instead of reporting no units", ctx do
      options = opts(ctx, units: nil, status_fn: fn _roles, _opts -> {:error, :boom} end)

      assert {:error, :unit_status_unavailable} = Uninstall.preview(options)

      assert {:error, :unit_status_unavailable} =
               Uninstall.execute(Keyword.put(options, :confirm, String.duplicate("a", 64)))
    end

    test "refuses when a unit directory exists but cannot be listed", ctx do
      directory = Path.join([ctx.home, ".lemon", "run", "service"])
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o000)
      on_exit(fn -> File.chmod(directory, 0o700) end)

      options = opts(ctx, units: nil)

      # A root test runner can list an unreadable directory; skip there.
      if match?({:error, _}, File.ls(directory)) do
        assert {:error, :unit_status_unavailable} = Uninstall.preview(options)
      end
    end
  end

  describe "confirmation_digest/1" do
    test "is order-independent over units, paths and rc lines" do
      first = %{
        units: [unit(label: "org.lemon.controller"), unit(label: "org.lemon.node.chico")],
        program_paths: ["/a", "/b"],
        rc_lines: [
          %{file: "/h/.zshrc", index: 1, comment: @comment, line: @path_line},
          %{file: "/h/.bashrc", index: 4, comment: @comment, line: @path_line}
        ],
        purge: false,
        purge_paths: [],
        keychain: nil,
        source: false
      }

      second = %{
        first
        | units: Enum.reverse(first.units),
          program_paths: ["/b", "/a"],
          rc_lines: Enum.reverse(first.rc_lines)
      }

      assert Uninstall.confirmation_digest(first) == Uninstall.confirmation_digest(second)
      assert Uninstall.confirmation_digest(first) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "binds unit identity, unit content and every other element" do
      base = %{
        units: [unit([])],
        program_paths: ["/a"],
        rc_lines: [%{file: "/h/.zshrc", index: 1, comment: @comment, line: @path_line}],
        purge: false,
        purge_paths: [],
        keychain: nil,
        source: false
      }

      digest = Uninstall.confirmation_digest(base)

      mutations = [
        %{base | units: []},
        # A reinstalled or edited unit: same identity, different content.
        %{base | units: [unit(fingerprint: String.duplicate("2", 64))]},
        %{base | units: [unit(port: 4041, label: "org.lemon.controller.4041")]},
        %{base | units: [unit(manager: "systemd", label: "lemon-controller.service")]},
        %{base | units: [unit(state: "stopped")]},
        %{base | units: [unit(path: "/elsewhere.plist")]},
        %{base | program_paths: ["/a", "/c"]},
        %{base | purge: true},
        %{base | purge_paths: ["/h/.lemon"]},
        %{base | keychain: "Lemon Secrets/default"},
        %{base | source: true},
        %{base | rc_lines: [%{file: "/h/.zshrc", index: 2, comment: @comment, line: @path_line}]},
        %{
          base
          | rc_lines: [%{file: "/h/.zshrc", index: 1, comment: @comment, line: "export PATH=2"}]
        }
      ]

      for mutated <- mutations do
        refute Uninstall.confirmation_digest(mutated) == digest
      end
    end
  end

  describe "execute/1 confirmation" do
    test "refuses without a confirmation digest", ctx do
      installed_release(ctx.home)

      assert {:error, :confirmation_required} = Uninstall.execute(opts(ctx))
      assert {:error, :confirmation_required} = Uninstall.execute(opts(ctx, confirm: ""))
      assert File.exists?(Path.join([ctx.home, ".lemon", "versions"]))
    end

    test "refuses a stale digest and returns the fresh one", ctx do
      installed_release(ctx.home)
      {:ok, preview} = Uninstall.preview(opts(ctx))

      File.rm_rf!(Path.join([ctx.home, ".lemon", "updates"]))

      assert {:error, {:digest_mismatch, fresh}} =
               Uninstall.execute(opts(ctx, confirm: preview.confirmation_digest))

      refute fresh == preview.confirmation_digest
      assert File.exists?(Path.join([ctx.home, ".lemon", "versions"]))
      assert File.read!(ctx.manifest) == ""
    end

    test "refuses a digest previewed without --purge when executing with --purge", ctx do
      installed_release(ctx.home)
      {:ok, preview} = Uninstall.preview(opts(ctx))

      assert {:error, {:digest_mismatch, _}} =
               Uninstall.execute(opts(ctx, purge: true, confirm: preview.confirmation_digest))

      assert File.read!(ctx.manifest) == ""
    end

    test "refuses a digest taken before a unit was reinstalled", ctx do
      units = [unit([])]
      {:ok, preview} = Uninstall.preview(opts(ctx, units: units))

      reinstalled = [unit(fingerprint: String.duplicate("9", 64))]

      assert {:error, {:digest_mismatch, _}} =
               Uninstall.execute(
                 opts(ctx, units: reinstalled, confirm: preview.confirmation_digest)
               )
    end

    test "accepts an upper-case digest", ctx do
      installed_release(ctx.home)
      {:ok, preview} = Uninstall.preview(opts(ctx))

      assert {:ok, _} =
               Uninstall.execute(opts(ctx, confirm: String.upcase(preview.confirmation_digest)))
    end

    test "rejects a replaced target or ancestor even when all path names are unchanged", ctx do
      installed_release(ctx.home)

      for relative <- [".lemon/versions", ".lemon/lemon_bot", ".lemon", ""] do
        options = opts(ctx)
        {:ok, preview} = Uninstall.preview(options)
        path = Path.join(ctx.home, relative)
        saved = path <> "-previous-#{System.unique_integer([:positive])}"
        File.rename!(path, saved)
        File.mkdir_p!(path)

        if relative in [".lemon", ""] do
          installed_release(ctx.home)
        else
          File.mkdir_p!(Path.join(ctx.home, ".lemon/lemon_bot/versions"))
        end

        assert {:error, {:digest_mismatch, _}} =
                 Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

        assert File.dir?(path)
        assert File.dir?(saved)
        assert File.read!(ctx.manifest) == ""
      end
    end

    test "binds an ancestor identity even if the target inode is preserved", ctx do
      parent = Path.join(ctx.home, ".lemon/lemon_bot")
      target = Path.join(parent, "versions")
      File.mkdir_p!(target)
      options = opts(ctx)
      {:ok, preview} = Uninstall.preview(options)
      inode = File.lstat!(target).inode
      saved = parent <> "-previous"
      File.rename!(parent, saved)
      File.mkdir_p!(parent)
      File.rename!(Path.join(saved, "versions"), target)
      assert File.lstat!(target).inode == inode

      assert {:error, {:digest_mismatch, _}} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.dir?(target)
      assert File.read!(ctx.manifest) == ""
    end
  end

  describe "execute/1 units" do
    test "removes each previewed unit by its own identity, never by a broad role", ctx do
      parent = self()

      units = [
        unit(
          role: "controller",
          port: 4041,
          label: "org.lemon.controller.4041",
          options: [port: 4041]
        ),
        unit(
          role: "backend",
          port: 4101,
          label: "org.lemon.bot.4101",
          path: "/units/org.lemon.bot.4101.plist",
          options: [port: 4101]
        ),
        unit(
          role: "worker",
          name: "chico",
          port: nil,
          label: "org.lemon.node.chico",
          path: "/units/org.lemon.node.chico.plist",
          options: [name: "chico"]
        ),
        unit(
          role: "worker",
          name: "manual",
          port: nil,
          manager: "none",
          label: "lemon-node-manual.service",
          path: "/run/service/lemon-node-manual.service.json",
          options: [name: "manual", manual: true]
        )
      ]

      options =
        opts(ctx,
          units: units,
          uninstall_fn: fn [role], unit_opts ->
            send(
              parent,
              {:uninstall, role, unit_opts[:port], unit_opts[:name], unit_opts[:manual]}
            )

            matched =
              Enum.find(units, fn candidate ->
                candidate.role == role and candidate.name == unit_opts[:name] and
                  candidate.port == unit_opts[:port]
              end)

            removed(matched)
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:ok, result} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert result.units == Enum.map(units, & &1.label)

      assert_received {:uninstall, "controller", 4041, nil, nil}
      assert_received {:uninstall, "backend", 4101, nil, nil}
      assert_received {:uninstall, "worker", nil, "chico", nil}
      assert_received {:uninstall, "worker", nil, "manual", true}
    end

    test "fails when a unit is reported foreign, blocked or still installed", ctx do
      zshrc = installed_rc(ctx.home, ".zshrc")

      for reported <- [
            %{installed: true, state: "foreign"},
            %{installed: false, state: "blocked"},
            %{installed: false, state: "failed"},
            %{installed: true, state: "ready"}
          ] do
        options =
          opts(ctx,
            units: [unit([])],
            rc_files: [zshrc],
            uninstall_fn: fn _roles, _unit_opts ->
              {:ok,
               %{
                 schema: 1,
                 units: [
                   Map.merge(%{role: "controller", label: "org.lemon.controller"}, reported)
                 ]
               }}
            end
          )

        {:ok, preview} = Uninstall.preview(options)

        assert {:error, :unit_not_removed} =
                 Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

        # Nothing after the unit step ran.
        assert File.read!(zshrc) =~ @comment
        assert File.read!(ctx.manifest) == ""
      end
    end

    test "fails when the service reports no unit for the previewed label", ctx do
      options =
        opts(ctx,
          units: [unit([])],
          uninstall_fn: fn _roles, _unit_opts ->
            {:ok, %{schema: 1, units: [%{label: "org.lemon.other", installed: false}]}}
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :unit_not_removed} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))
    end
  end

  describe "execute/1 controller" do
    test "stops a verified unsupervised controller with its own snapshot token", ctx do
      parent = self()
      token = String.duplicate("a", 64)

      options =
        opts(ctx,
          command_runner: fn _executable, args, _opts ->
            send(parent, {:ran, args})

            case args do
              ["__update-daemon", "snapshot"] -> {token <> "\n", 0}
              ["__update-daemon", "stop", ^token] -> {"", 0}
              _ -> {"", 1}
            end
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert_received {:ran, ["__update-daemon", "snapshot"]}
      assert_received {:ran, ["__update-daemon", "stop", ^token]}
    end

    test "signals nothing when the snapshot reports a stopped controller", ctx do
      parent = self()

      options =
        opts(ctx,
          command_runner: fn _executable, args, _opts ->
            send(parent, {:ran, args})
            {"stopped\n", 0}
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert_received {:ran, ["__update-daemon", "snapshot"]}
      refute_received {:ran, ["__update-daemon", "stop" | _]}
    end

    test "fails closed on an unverifiable or malformed snapshot", ctx do
      for output <- ["", "boom", "not-a-token", String.duplicate("z", 64)] do
        options =
          opts(ctx,
            command_runner: fn _executable, _args, _opts -> {output, 0} end
          )

        {:ok, preview} = Uninstall.preview(options)

        assert {:error, :controller_snapshot_unverified} =
                 Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))
      end

      options = opts(ctx, command_runner: fn _executable, _args, _opts -> {"", 1} end)
      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :controller_snapshot_unverified} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))
    end

    test "fails when the verified controller refuses to stop", ctx do
      token = String.duplicate("b", 64)

      options =
        opts(ctx,
          command_runner: fn _executable, args, _opts ->
            case args do
              ["__update-daemon", "snapshot"] -> {token, 0}
              _ -> {"", 1}
            end
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :controller_stop_failed} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.read!(ctx.manifest) == ""
    end

    test "fails when no launcher can verify the controller", ctx do
      for launcher <- [nil, "relative/lemon", Path.join(ctx.home, "missing")] do
        options = opts(ctx, launcher: launcher)
        {:ok, preview} = Uninstall.preview(options)

        assert {:error, :launcher_unavailable} =
                 Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))
      end
    end
  end

  describe "execute/1 rc files" do
    test "removes exactly the two bound lines and keeps the rest", ctx do
      zshrc =
        rc_file(ctx.home, ".zshrc", """
        export EDITOR=vim

        #{@comment}
        #{@path_line}
        export AFTER=1
        """)

      mode = File.stat!(zshrc).mode
      options = opts(ctx, rc_files: [zshrc])
      {:ok, preview} = Uninstall.preview(options)

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.read!(zshrc) == "export EDITOR=vim\n\nexport AFTER=1\n"
      assert File.stat!(zshrc).mode == mode
    end

    test "an rc file edited after the preview invalidates the digest", ctx do
      zshrc = installed_rc(ctx.home, ".zshrc")
      options = opts(ctx, rc_files: [zshrc])
      {:ok, preview} = Uninstall.preview(options)

      File.write!(zshrc, "# prepended\n" <> File.read!(zshrc))

      assert {:error, {:digest_mismatch, _}} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.read!(zshrc) =~ @path_line
    end

    # The rewrite re-reads the file and compares the bound bytes, so a change
    # racing the confirmed preview cannot delete somebody else's line.
    test "the rewrite refuses when the bound bytes change after confirmation", ctx do
      zshrc = installed_rc(ctx.home, ".zshrc")

      options =
        opts(ctx,
          rc_files: [zshrc],
          command_runner: fn _executable, args, _opts ->
            if args == ["__update-daemon", "snapshot"] do
              File.write!(zshrc, "# prepended\n" <> File.read!(zshrc))
            end

            {"stopped\n", 0}
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :rc_file_changed} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.read!(zshrc) =~ @comment
      assert File.read!(zshrc) =~ @path_line
    end

    test "never rewrites an rc file that only mentions the Lemon bin directory", ctx do
      bashrc = rc_file(ctx.home, ".bashrc", "#{@path_line}\n")
      options = opts(ctx, rc_files: [bashrc])
      {:ok, preview} = Uninstall.preview(options)

      assert preview.rc_lines == []

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.read!(bashrc) == "#{@path_line}\n"
    end
  end

  describe "execute/1 manifest" do
    test "hands the exact paths to the launcher and deletes nothing in-VM", ctx do
      installed_release(ctx.home)
      options = opts(ctx, purge: true)
      {:ok, preview} = Uninstall.preview(options)

      assert {:ok, result} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert result.deleted_paths == preview.program_paths ++ preview.purge_paths
      document = Jason.decode!(File.read!(ctx.manifest))
      assert document["schema"] == 2
      assert document["home"] == preview.canonical_home

      assert Enum.sort(Enum.map(document["paths"], & &1["path"])) ==
               Enum.sort([
                 Path.join(preview.canonical_home, ".lemon"),
                 Path.join(preview.canonical_home, ".local/bin/lemon-bot")
               ])

      preview_identities = preview.path_identities |> Jason.encode!() |> Jason.decode!()
      assert Enum.all?(document["paths"], &(&1 in preview_identities))

      for identity <- document["paths"] do
        stat = File.lstat!(identity["path"])
        assert identity["device"] == stat.major_device
        assert identity["inode"] == stat.inode
        assert identity["type"] == Atom.to_string(stat.type)
        assert List.first(identity["ancestors"])["path"] == "/"
        assert List.last(identity["ancestors"])["path"] == Path.dirname(identity["path"])
        assert Enum.all?(identity["ancestors"], &(&1["type"] == "directory"))
      end

      for path <- result.deleted_paths, do: assert(File.exists?(path))
    end

    test "fails when no launcher manifest is available for program removal", ctx do
      installed_release(ctx.home)
      options = opts(ctx, manifest_path: nil)
      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :uninstall_manifest_missing} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.exists?(Path.join([ctx.home, ".lemon", "versions"]))
    end

    test "fails when the manifest is not a regular file", ctx do
      installed_release(ctx.home)
      directory = Path.join(ctx.tmp_dir, "manifest-dir")
      File.mkdir_p!(directory)

      options = opts(ctx, manifest_path: directory)
      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :uninstall_manifest_missing} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))
    end

    test "a units-only uninstall needs no manifest", ctx do
      options =
        opts(ctx,
          cli_launcher: :source,
          units: [unit([])],
          manifest_path: nil,
          uninstall_fn: fn _roles, _unit_opts -> removed(unit([])) end
        )

      {:ok, preview} = Uninstall.preview(options)
      assert preview.program_paths == []

      assert {:ok, result} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert result.deleted_paths == []
    end

    test "refuses target or ancestor swaps after confirmation and before handoff", ctx do
      for relative <- [".lemon/versions", ".lemon/lemon_bot"] do
        installed_release(ctx.home)
        path = Path.join(ctx.home, relative)
        saved = path <> "-previous"
        outside = Path.join(ctx.tmp_dir, "external-#{System.unique_integer([:positive])}")
        File.mkdir_p!(outside)
        sentinel = Path.join(outside, "keep")
        File.write!(sentinel, "external")

        options =
          opts(ctx,
            command_runner: fn _executable, args, _opts ->
              if args == ["__update-daemon", "snapshot"] do
                File.rename!(path, saved)
                File.ln_s!(outside, path)
              end

              {"stopped\n", 0}
            end
          )

        {:ok, preview} = Uninstall.preview(options)

        assert {:error, :uninstall_path_changed} =
                 Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

        assert File.read!(ctx.manifest) == ""
        assert File.read!(sentinel) == "external"
        assert File.dir?(saved)
        File.rm!(path)
        File.rename!(saved, path)
      end
    end

    test "revalidates identities again after Keychain removal before publishing", ctx do
      installed_release(ctx.home)
      path = Path.join(ctx.home, ".lemon/versions")
      saved = path <> "-previous"

      options =
        opts(ctx,
          purge: true,
          os: :darwin,
          command_runner: fn executable, _args, _opts ->
            if executable == "security" do
              File.rename!(path, saved)
              File.mkdir_p!(path)
              {"", 0}
            else
              {"stopped\n", 0}
            end
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:error, :uninstall_path_changed} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert File.read!(ctx.manifest) == ""
      assert File.dir?(saved)
      assert File.dir?(path)
    end
  end

  describe "execute/1 keychain" do
    test "removes the Keychain item when purging on macOS", ctx do
      installed_release(ctx.home)
      parent = self()

      options =
        opts(ctx,
          os: :darwin,
          purge: true,
          command_runner: fn executable, args, _opts ->
            send(parent, {:ran, executable, args})
            if executable == "security", do: {"", 0}, else: {"stopped\n", 0}
          end
        )

      {:ok, preview} = Uninstall.preview(options)

      assert {:ok, result} =
               Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

      assert_received {:ran, "security",
                       ["delete-generic-password", "-s", "Lemon Secrets", "-a", "default"]}

      assert result.purged
    end

    test "treats an absent Keychain item as success and a real failure as an error", ctx do
      installed_release(ctx.home)

      absent =
        opts(ctx,
          os: :darwin,
          purge: true,
          command_runner: fn executable, _args, _opts ->
            if executable == "security", do: {"", 44}, else: {"stopped\n", 0}
          end
        )

      {:ok, preview} = Uninstall.preview(absent)

      assert {:ok, _} =
               Uninstall.execute(Keyword.put(absent, :confirm, preview.confirmation_digest))

      File.write!(ctx.manifest, "")

      failing =
        opts(ctx,
          os: :darwin,
          purge: true,
          command_runner: fn executable, _args, _opts ->
            if executable == "security", do: {"", 1}, else: {"stopped\n", 0}
          end
        )

      {:ok, preview} = Uninstall.preview(failing)

      assert {:error, :keychain_removal_failed} =
               Uninstall.execute(Keyword.put(failing, :confirm, preview.confirmation_digest))

      assert File.read!(ctx.manifest) == ""
    end

    test "never touches the Keychain without --purge or on Linux", ctx do
      parent = self()

      for overrides <- [[os: :darwin], [os: :linux, purge: true]] do
        options =
          opts(
            ctx,
            Keyword.merge(overrides,
              command_runner: fn executable, _args, _opts ->
                send(parent, {:ran, executable})
                {"stopped\n", 0}
              end
            )
          )

        {:ok, preview} = Uninstall.preview(options)

        assert {:ok, _} =
                 Uninstall.execute(Keyword.put(options, :confirm, preview.confirmation_digest))

        refute_received {:ran, "security"}
      end
    end
  end

  describe "candidate_program_paths/1" do
    test "is the exact installer layout, data directory excluded" do
      assert Uninstall.candidate_program_paths("/h") == [
               "/h/.lemon/versions",
               "/h/.lemon/bin",
               "/h/.lemon/updates",
               "/h/.lemon/tmp",
               "/h/.lemon/lemon_bot/versions",
               "/h/.lemon/lemon_bot/current",
               "/h/.local/bin/lemon-bot"
             ]
    end
  end
end
