defmodule LemonCore.Uninstall do
  @moduledoc """
  Preview and execution for `lemon uninstall`.

  Destructive lifecycle operation: it previews first and binds the operator's
  confirmation to the exact candidate set — every discovered unit with its
  current file content, the exact program paths and their canonical filesystem
  identities (including every ancestor), and the exact rc-file lines.
  Execution recomputes the preview from live state and refuses unless the
  supplied digest still matches, then removes each previewed unit through
  `LemonCore.Service`, stops a verified unsupervised controller through the
  launcher's authenticated hook, rewrites the bound rc lines, and hands a
  schema-2 identity manifest to the launcher for deletion after the VM exits.

  Errors are stable atoms. No path, command output or exception text leaks into
  a result.
  """

  alias LemonCore.Service
  alias LemonCore.Service.Role

  @installer_comment "# added by the lemon installer"

  @rc_relative_paths [
    ".zshrc",
    ".bashrc",
    ".bash_profile",
    ".profile",
    Path.join([".config", "fish", "config.fish"])
  ]

  @type unit :: %{
          role: String.t(),
          name: String.t() | nil,
          port: non_neg_integer() | nil,
          manager: String.t(),
          label: String.t(),
          path: String.t(),
          state: String.t(),
          fingerprint: String.t(),
          options: keyword()
        }

  # ──────────────────────────────────────────────────────────────────────────
  # Preview
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Returns the exact candidate set plus the confirmation digest that binds it.

  A source checkout owns no installed program files, so it previews units only:
  no program paths, no rc lines, no purge paths and no keychain item, even with
  `purge: true`.
  """
  @spec preview(keyword()) :: {:ok, map()} | {:error, atom()}
  def preview(opts \\ []) do
    home = Role.home(opts)
    source? = source?(opts)
    purge? = Keyword.get(opts, :purge, false) == true and not source?

    with {:ok, canonical_home} <- canonical_home(home),
         {:ok, units} <- discover_units(opts),
         {:ok, rc_lines} <- rc_entries(source?, home, opts),
         {:ok, programs} <- program_paths(source?, home, canonical_home),
         {:ok, purge_paths} <- purge_paths(source?, purge?, home, canonical_home) do
      candidates = %{
        units: units,
        program_paths: Enum.map(programs, &elem(&1, 0)),
        path_identities: Enum.map(programs ++ purge_paths, &elem(&1, 1)),
        canonical_home: canonical_home,
        rc_lines: rc_lines,
        purge: purge?,
        purge_paths: Enum.map(purge_paths, &elem(&1, 0)),
        keychain: keychain(source?, purge?, opts),
        source: source?
      }

      {:ok, Map.put(candidates, :confirmation_digest, confirmation_digest(candidates))}
    end
  end

  @doc """
  SHA-256 over the canonical rendering of the candidate set.

  Every removal path binds its canonical device/inode identity and ancestor
  chain. Every unit binds its identity and current file content.
  """
  @spec confirmation_digest(map()) :: String.t()
  def confirmation_digest(candidates) do
    units =
      candidates
      |> Map.get(:units, [])
      |> Enum.map(fn unit ->
        Enum.join(
          [
            unit.manager,
            unit.role,
            unit.name || "",
            if(unit.port, do: Integer.to_string(unit.port), else: ""),
            unit.label,
            unit.path,
            unit.state,
            unit.fingerprint
          ],
          "|"
        )
      end)
      |> Enum.sort()

    rc_lines =
      candidates
      |> Map.get(:rc_lines, [])
      |> Enum.map(&Enum.join([&1.file, Integer.to_string(&1.index), &1.comment, &1.line], "|"))
      |> Enum.sort()

    identities =
      candidates
      |> Map.get(:path_identities, [])
      |> Enum.sort_by(& &1.path)
      |> :erlang.term_to_binary()
      |> Base.encode64()

    canonical =
      Enum.join(
        [
          "schema:2",
          "home:" <> Map.get(candidates, :canonical_home, ""),
          "identities:" <> identities,
          "source:#{Map.get(candidates, :source, false) == true}",
          "purge:#{Map.get(candidates, :purge, false) == true}",
          "units:" <> Enum.join(units, "\u0000"),
          "programs:" <> Enum.join(Enum.sort(Map.get(candidates, :program_paths, [])), "\u0000"),
          "rc:" <> Enum.join(rc_lines, "\u0000"),
          "purge_paths:" <> Enum.join(Enum.sort(Map.get(candidates, :purge_paths, [])), "\u0000"),
          "keychain:" <> to_string(Map.get(candidates, :keychain))
        ],
        "\n"
      )

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Execution
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Executes the uninstall bound to `:confirm`, which must still match a fresh
  preview of live state.
  """
  @spec execute(keyword()) :: {:ok, map()} | {:error, atom() | {:digest_mismatch, String.t()}}
  def execute(opts \\ []) do
    case Keyword.get(opts, :confirm) do
      confirm when is_binary(confirm) and byte_size(confirm) > 0 ->
        with {:ok, candidates} <- preview(opts) do
          if String.downcase(confirm) == candidates.confirmation_digest do
            perform(candidates, opts)
          else
            {:error, {:digest_mismatch, candidates.confirmation_digest}}
          end
        end

      _ ->
        {:error, :confirmation_required}
    end
  end

  defp perform(candidates, opts) do
    paths = candidates.program_paths ++ candidates.purge_paths

    with {:ok, manifest} <- manifest_path(paths, opts),
         :ok <- remove_units(candidates.units, opts),
         :ok <- stop_unsupervised_controller(opts),
         :ok <- revalidate_paths(candidates.path_identities),
         :ok <- rewrite_rc_files(candidates.rc_lines),
         :ok <- remove_keychain_item(candidates.keychain, opts),
         :ok <- revalidate_paths(candidates.path_identities),
         :ok <- publish_manifest(candidates, manifest) do
      {:ok,
       %{
         uninstalled: true,
         units: Enum.map(candidates.units, & &1.label),
         program_paths: candidates.program_paths,
         rc_lines: candidates.rc_lines,
         purged: candidates.purge,
         deleted_paths: paths
       }}
    end
  end

  # ── Units ─────────────────────────────────────────────────────────────────

  # Each previewed unit is removed by its own exact identity (role + name +
  # port + manager), never by a broad role, so controller/backend units on a
  # non-default port and every named worker are covered.
  defp remove_units(units, opts) do
    Enum.reduce_while(units, :ok, fn unit, :ok ->
      case remove_unit(unit, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_unit(unit, opts) do
    call = Keyword.get(opts, :uninstall_fn, &Service.uninstall/2)

    unit_opts =
      service_opts(opts)
      |> Keyword.merge(unit.options)
      |> Keyword.put(:expected_fingerprint, unit.fingerprint)

    case call.([unit.role], unit_opts) do
      {:ok, document} ->
        document
        |> Map.get(:units, [])
        |> Enum.find(&(Map.get(&1, :label) == unit.label))
        |> removed?()

      _ ->
        {:error, :unit_not_removed}
    end
  end

  defp removed?(%{installed: false} = reported) do
    if Map.get(reported, :state) in ["blocked", "foreign", "failed"] do
      {:error, :unit_not_removed}
    else
      :ok
    end
  end

  defp removed?(_), do: {:error, :unit_not_removed}

  # ── Controller ────────────────────────────────────────────────────────────

  # Step 2 of D13: an unsupervised controller is stopped through the launcher's
  # authenticated snapshot/stop hook. Anything the launcher cannot verify fails
  # closed; no signal is ever sent on an unverified identity.
  defp stop_unsupervised_controller(opts) do
    runner = Keyword.get(opts, :command_runner, &run_command/3)

    case launcher(opts) do
      {:ok, launcher} ->
        case runner.(launcher, ["__update-daemon", "snapshot"], opts) do
          {output, 0} -> stop_snapshot(launcher, String.trim(output), runner, opts)
          _ -> {:error, :controller_snapshot_unverified}
        end

      error ->
        error
    end
  end

  defp stop_snapshot(_launcher, "stopped", _runner, _opts), do: :ok

  defp stop_snapshot(launcher, token, runner, opts) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/i, token) do
      case runner.(launcher, ["__update-daemon", "stop", token], opts) do
        {_, 0} -> :ok
        _ -> {:error, :controller_stop_failed}
      end
    else
      {:error, :controller_snapshot_unverified}
    end
  end

  defp launcher(opts) do
    path =
      Keyword.get(opts, :launcher) ||
        Map.get(Keyword.get_lazy(opts, :env, &System.get_env/0), "LEMON_LAUNCHER")

    if is_binary(path) and Path.type(path) == :absolute and regular_file?(path) do
      {:ok, path}
    else
      {:error, :launcher_unavailable}
    end
  end

  # ── rc files ──────────────────────────────────────────────────────────────

  # Only the two previewed lines are removed, and only while the file still
  # holds exactly those bytes at exactly those positions.
  defp rewrite_rc_files(entries) do
    entries
    |> Enum.group_by(& &1.file)
    |> Enum.reduce_while(:ok, fn {file, file_entries}, :ok ->
      case rewrite_rc_file(file, file_entries) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp rewrite_rc_file(file, entries) do
    with {:ok, contents} <- read_file(file, :rc_file_changed),
         {:ok, %File.Stat{mode: mode}} <- stat(file, :rc_file_changed) do
      lines = String.split(contents, "\n")
      drop = Enum.flat_map(entries, &[&1.index, &1.index + 1])

      if Enum.all?(entries, &bound?(lines, &1)) do
        kept =
          lines
          |> Enum.with_index()
          |> Enum.reject(fn {_line, index} -> index in drop end)
          |> Enum.map(&elem(&1, 0))

        write_atomic(file, Enum.join(kept, "\n"), mode)
      else
        {:error, :rc_file_changed}
      end
    end
  end

  defp bound?(lines, entry) do
    Enum.at(lines, entry.index) == entry.comment and
      Enum.at(lines, entry.index + 1) == entry.line
  end

  # A temporary file in the same directory keeps the rc file whole on a failed
  # write; the original mode is restored before it is published.
  defp write_atomic(file, contents, mode) do
    temporary = file <> ".lemon-uninstall-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, rem(mode, 0o10000)),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      _ ->
        File.rm(temporary)
        {:error, :rc_write_failed}
    end
  end

  # ── Keychain ──────────────────────────────────────────────────────────────

  defp remove_keychain_item(nil, _opts), do: :ok

  defp remove_keychain_item(_item, opts) do
    runner = Keyword.get(opts, :command_runner, &run_command/3)

    case runner.(
           "security",
           ["delete-generic-password", "-s", "Lemon Secrets", "-a", "default"],
           opts
         ) do
      {_, 0} -> :ok
      # A missing item is already the requested end state.
      {_, 44} -> :ok
      _ -> {:error, :keychain_removal_failed}
    end
  end

  # ── Manifest ──────────────────────────────────────────────────────────────

  # The release VM cannot delete its own program files, so the launcher does it
  # after the VM exits. Without the launcher's private manifest there is no
  # authorized deletion path at all: fail instead of pretending success.
  defp manifest_path([], _opts), do: {:ok, nil}

  defp manifest_path(_paths, opts) do
    manifest =
      Keyword.get(opts, :manifest_path) ||
        Map.get(Keyword.get_lazy(opts, :env, &System.get_env/0), "LEMON_UNINSTALL_MANIFEST")

    cond do
      not (is_binary(manifest) and Path.type(manifest) == :absolute) ->
        {:error, :uninstall_manifest_missing}

      not private_manifest?(manifest) ->
        {:error, :uninstall_manifest_missing}

      true ->
        {:ok, manifest}
    end
  end

  defp private_manifest?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> :erlang.band(mode, 0o077) == 0
      _ -> false
    end
  end

  defp publish_manifest(%{path_identities: []}, nil), do: :ok

  # Schema 2 is also the launcher's deletion contract. Each canonical leaf has
  # its lstat identity plus the ordered, symlink-free chain from / to its parent.
  # The launcher validates all entries, then revalidates immediately before each
  # removal. A symlink leaf is unlinked, never resolved or traversed.
  defp publish_manifest(candidates, manifest) do
    document = %{
      schema: 2,
      home: candidates.canonical_home,
      paths: disjoint_paths(candidates.path_identities)
    }

    case File.write(manifest, Jason.encode!(document) <> "\n") do
      :ok -> :ok
      _ -> {:error, :uninstall_manifest_write_failed}
    end
  end

  # Purging .lemon subsumes its program directories. The launcher pins parent
  # descriptors before mutation, so no entry may delete another entry's parent.
  defp disjoint_paths(paths) do
    Enum.reject(paths, fn path ->
      Enum.any?(paths, fn other ->
        path.path != other.path and String.starts_with?(path.path, other.path <> "/")
      end)
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Discovery
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Returns every Lemon-owned unit the service manager and the manual records
  know about, each with its current file fingerprint.
  """
  @spec discover_units(keyword()) :: {:ok, [unit()]} | {:error, atom()}
  def discover_units(opts) do
    case Keyword.get(opts, :units) do
      units when is_list(units) ->
        {:ok, units}

      _ ->
        with {:ok, states} <- unit_states(opts) do
          {manager, _module, _blocked} = Service.manager(opts)

          managers = Enum.uniq([manager, "none"])
          service_opts = service_opts(opts)

          with :ok <- readable?(managers, service_opts) do
            {:ok,
             managers
             |> Enum.flat_map(fn candidate ->
               candidate
               |> Service.discover(service_opts)
               |> Enum.map(&describe(candidate, &1, states, service_opts))
             end)
             |> Enum.uniq_by(& &1.path)}
          end
        end
    end
  end

  # A unit directory that exists but cannot be listed would silently shrink the
  # candidate set, which must never happen before a destructive confirmation.
  defp readable?(managers, opts) do
    Enum.reduce_while(managers, :ok, fn manager, :ok ->
      directory = unit_directory(manager, opts)

      case File.ls(directory) do
        {:ok, _} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, _} -> {:halt, {:error, :unit_status_unavailable}}
      end
    end)
  end

  defp unit_directory("launchd", opts), do: Path.join(Role.home(opts), "Library/LaunchAgents")
  defp unit_directory("systemd", opts), do: Path.join(Role.home(opts), ".config/systemd/user")
  defp unit_directory("none", opts), do: Role.run_dir(opts)

  defp describe(manager, {role, options}, states, opts) do
    name = options[:name]
    port = options[:port]
    label = Role.label(role, manager, name, port)
    path = Role.unit_path(label, manager, opts)

    %{
      role: role,
      name: name,
      port: port,
      manager: manager,
      label: label,
      path: path,
      state: Map.get(states, label, "unknown"),
      fingerprint: fingerprint(path),
      options: if(manager == "none", do: Keyword.put(options, :manual, true), else: options)
    }
  end

  defp unit_states(opts) do
    reader = Keyword.get(opts, :status_fn, &Service.status/2)

    case reader.([], service_opts(opts)) do
      {:ok, %{units: units}} ->
        {:ok, Map.new(units, &{Map.get(&1, :label), Map.get(&1, :state, "unknown")})}

      _ ->
        {:error, :unit_status_unavailable}
    end
  end

  # A unit's content is part of the confirmation: an edited or reinstalled unit
  # must invalidate a digest taken before the change.
  defp fingerprint(path) do
    case File.read(path) do
      {:ok, body} -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      _ -> "absent"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Candidate sets
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  The exact installer-managed program paths. The data directory is not one of
  them: it is removed only by `--purge`.
  """
  @spec candidate_program_paths(String.t()) :: [String.t()]
  def candidate_program_paths(home) do
    [
      Path.join([home, ".lemon", "versions"]),
      Path.join([home, ".lemon", "bin"]),
      Path.join([home, ".lemon", "updates"]),
      Path.join([home, ".lemon", "tmp"]),
      Path.join([home, ".lemon", "lemon_bot", "versions"]),
      Path.join([home, ".lemon", "lemon_bot", "current"]),
      Path.join([home, ".local", "bin", "lemon-bot"])
    ]
  end

  defp program_paths(true, _home, _canonical_home), do: {:ok, []}

  defp program_paths(false, home, canonical_home) do
    identify_paths(candidate_program_paths(home), home, canonical_home)
  end

  defp purge_paths(false, true, home, canonical_home) do
    identify_paths([Path.join(home, ".lemon")], home, canonical_home)
  end

  defp purge_paths(_source?, _purge?, _home, _canonical_home), do: {:ok, []}

  defp identify_paths(paths, home, canonical_home) do
    with {:ok, ancestors} <- directory_chain(canonical_home) do
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, found} ->
        relative = Path.relative_to(Path.expand(path), Path.expand(home))

        case identify_path(Path.split(relative), canonical_home, ancestors) do
          {:ok, nil} -> {:cont, {:ok, found}}
          {:ok, identity} -> {:cont, {:ok, found ++ [{path, identity}]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp identify_path([part | rest], parent, ancestors) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: type} = stat} ->
        identity = identity(path, stat)

        cond do
          rest == [] and type in [:directory, :regular, :symlink] ->
            {:ok, Map.put(identity, :ancestors, ancestors)}

          rest != [] and type == :directory ->
            identify_path(rest, path, ancestors ++ [identity])

          true ->
            {:error, :unsafe_uninstall_path}
        end

      {:error, :enoent} ->
        {:ok, nil}

      _ ->
        {:error, :unsafe_uninstall_path}
    end
  end

  # Only the trusted HOME prefix may have aliases (notably /tmp on macOS).
  # Once it is canonical, no owned ancestor is ever followed through a symlink.
  defp canonical_home(home) do
    resolve_home(Path.split(Path.expand(home)), "", 40)
  end

  defp resolve_home([], path, _remaining), do: {:ok, path}
  defp resolve_home(["/" | rest], "", remaining), do: resolve_home(rest, "/", remaining)

  defp resolve_home([part | rest], parent, remaining) do
    path = Path.join(parent, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        resolve_home(rest, path, remaining)

      {:ok, %File.Stat{type: :symlink}} when remaining > 0 ->
        case File.read_link(path) do
          {:ok, target} ->
            resolve_home(Path.split(Path.expand(target, parent)) ++ rest, "", remaining - 1)

          _ ->
            {:error, :unsafe_uninstall_path}
        end

      _ ->
        {:error, :unsafe_uninstall_path}
    end
  end

  defp directory_chain(path) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, "", []}, fn part, {:ok, parent, chain} ->
      directory = if part == "/", do: "/", else: Path.join(parent, part)

      case File.lstat(directory) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          {:cont, {:ok, directory, chain ++ [identity(directory, stat)]}}

        _ ->
          {:halt, {:error, :unsafe_uninstall_path}}
      end
    end)
    |> case do
      {:ok, _path, chain} -> {:ok, chain}
      error -> error
    end
  end

  defp identity(path, stat) do
    %{path: path, type: Atom.to_string(stat.type), device: stat.major_device, inode: stat.inode}
  end

  defp revalidate_paths(paths) do
    if Enum.all?(paths, fn path ->
         Enum.all?(path.ancestors ++ [Map.delete(path, :ancestors)], &same_identity?/1)
       end) do
      :ok
    else
      {:error, :uninstall_path_changed}
    end
  end

  defp same_identity?(expected) do
    case File.lstat(expected.path) do
      {:ok, stat} -> identity(expected.path, stat) == expected
      _ -> false
    end
  end

  defp keychain(false, true, opts) do
    if darwin?(opts), do: "Lemon Secrets/default", else: nil
  end

  defp keychain(_source?, _purge?, _opts), do: nil

  # ── rc scanning ───────────────────────────────────────────────────────────

  defp rc_entries(true, _home, _opts), do: {:ok, []}

  defp rc_entries(false, home, opts) do
    opts
    |> rc_files(home)
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case scan_rc_file(file, home) do
        {:ok, entries} -> {:cont, {:ok, acc ++ entries}}
        error -> {:halt, error}
      end
    end)
  end

  defp rc_files(opts, home) do
    case Keyword.get(opts, :rc_files) do
      files when is_list(files) -> files
      _ -> Enum.map(@rc_relative_paths, &Path.join(home, &1))
    end
  end

  # The installer writes the marker comment and the PATH line as an adjacent
  # pair. Only that pair is a candidate; a later unrelated line is not.
  defp scan_rc_file(file, home) do
    cond do
      not exists?(file) ->
        {:ok, []}

      not regular_file?(file) ->
        {:error, :rc_file_changed}

      true ->
        case read_file(file, :rc_file_changed) do
          {:ok, contents} ->
            lines = String.split(contents, "\n")

            {:ok,
             lines
             |> Enum.with_index()
             |> Enum.flat_map(fn {line, index} ->
               next = Enum.at(lines, index + 1)

               if String.trim(line) == @installer_comment and is_binary(next) and
                    installer_path_line?(next, home) do
                 [%{file: file, index: index, comment: line, line: next}]
               else
                 []
               end
             end)}

          error ->
            error
        end
    end
  end

  defp installer_path_line?(line, home) do
    bins = [Path.join(home, ".lemon/bin"), "$HOME/.lemon/bin", "${HOME}/.lemon/bin"]

    Enum.any?(bins, fn bin -> line in ["export PATH=\"#{bin}:$PATH\"", "fish_add_path #{bin}"] end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp source?(opts) do
    launcher =
      Keyword.get_lazy(opts, :cli_launcher, fn ->
        Map.get(Keyword.get_lazy(opts, :env, &System.get_env/0), "LEMON_CLI_LAUNCHER")
      end)

    launcher in [:source, "source"]
  end

  defp darwin?(opts) do
    case Keyword.get(opts, :os, :os.type()) do
      :darwin -> true
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  # Injected test seams never reach the service layer as unit options.
  defp service_opts(opts) do
    Keyword.drop(opts, [:units, :uninstall_fn, :status_fn, :confirm, :rc_files, :manifest_path])
  end

  defp exists?(path), do: match?({:ok, _}, :file.read_link_info(String.to_charlist(path)))

  defp regular_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.stat(path, time: :posix))
  end

  defp stat(path, error) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat}
      _ -> {:error, error}
    end
  end

  defp read_file(path, error) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      _ -> {:error, error}
    end
  end

  defp run_command(executable, args, opts) do
    Service.Command.run(executable, args, opts)
  end
end
