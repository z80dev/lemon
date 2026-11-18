defmodule LemonSkills.Bundle do
  @moduledoc false

  # The one skill bundle layout policy: enumeration, hashing, safe file reads,
  # and exact-file copies.
  #
  # A bundle is a directory holding `SKILL.md` plus files under `references/`,
  # `templates/`, `scripts/` and `assets/`. `scan/1` lstat-walks the tree and
  # never follows a symlink. Every entry is either an auditable regular file or
  # a violation: hidden names, names with control/format characters, `\`, `:`
  # or invalid UTF-8, entries outside that layout, symlinks, FIFOs, devices,
  # sockets, oversized files and over-limit trees are reported, never silently
  # skipped. The bundle hash covers the files and the violations in a
  # length-delimited, versioned encoding, so distinct scans never share a hash
  # and a cached verdict can never outlive a change to either.
  #
  # Installs, audits, the skill blueprint importer, `read_skill` and `skill://`
  # all use this module, so the audited set, the activated set and the readable
  # set are the same set.

  @allowed_dirs ~w(references templates scripts assets)
  @max_files 256
  @max_file_bytes 1_048_576
  @max_total_bytes 8_388_608
  @max_path_bytes 512

  @type group :: :skill | :references | :templates | :scripts | :assets

  @type file_info :: %{
          path: String.t(),
          full_path: String.t(),
          sha256: String.t(),
          size: non_neg_integer(),
          mode: non_neg_integer(),
          text?: boolean(),
          group: group()
        }

  @type violation_reason ::
          :hidden
          | :invalid_name
          | :outside_layout
          | :symlink
          | :not_regular
          | :not_directory
          | :missing_skill_md
          | :too_large
          | :too_many_files
          | :total_too_large
          | :path_too_long
          | :unreadable
          | :hard_link

  @type violation :: %{path: String.t(), reason: violation_reason()}
  @type scan :: %{root: String.t(), files: [file_info()], violations: [violation()]}

  @type read_error ::
          :invalid_path
          | :hidden
          | :outside_layout
          | :symlink
          | :not_regular
          | :enoent
          | :too_large
          | :changed
          | :unavailable
          | :hard_link

  @doc false
  def max_file_bytes, do: @max_file_bytes

  @spec scan(String.t()) :: {:ok, scan()} | {:error, term()}
  def scan(skill_dir) when is_binary(skill_dir) do
    root = Path.expand(skill_dir)

    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, names} <- list_names(root) do
          acc = %{files: [], violations: [], count: 0, bytes: 0}
          acc = Enum.reduce(Enum.sort(names), acc, &scan_root_entry(root, &1, &2))

          violations =
            if Enum.any?(acc.files, &(&1.path == "SKILL.md")) or
                 Enum.any?(acc.violations, &(&1.path == "SKILL.md")) do
              acc.violations
            else
              [%{path: "SKILL.md", reason: :missing_skill_md} | acc.violations]
            end

          {:ok,
           %{
             root: root,
             files: Enum.sort_by(acc.files, & &1.path),
             violations: Enum.sort_by(violations, & &1.path)
           }}
        end

      {:ok, _} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec require_clean(scan()) :: :ok | {:error, {:bundle_violations, [violation()]}}
  def require_clean(%{violations: []}), do: :ok
  def require_clean(%{violations: violations}), do: {:error, {:bundle_violations, violations}}

  @spec compute_hash(String.t()) :: {:ok, String.t()} | {:error, term()}
  def compute_hash(skill_dir) when is_binary(skill_dir) do
    with {:ok, scan} <- scan(skill_dir), do: {:ok, hash(scan)}
  end

  @hash_version "lemon-skill-bundle-v2"

  @doc """
  Deterministic hash over the scanned files and violations.

  Every field is length-prefixed and the encoding is versioned, so no file or
  violation path, whatever bytes it holds, can make two different scans
  serialise identically.
  """
  @spec hash(scan()) :: String.t()
  def hash(%{files: files, violations: violations}) do
    file_fields = Enum.map(files, &["F", field(&1.path), field(&1.sha256)])

    violation_fields =
      Enum.map(violations, &["V", field(&1.path), field(Atom.to_string(&1.reason))])

    [
      field(@hash_version),
      <<length(files)::64>>,
      file_fields,
      <<length(violations)::64>>,
      violation_fields
    ]
    |> IO.iodata_to_binary()
    |> sha256_hex()
  end

  defp field(bytes) when is_binary(bytes), do: [<<byte_size(bytes)::64>>, bytes]

  @doc false
  # The pre-v2 (line-joined, collision-prone) hash of a clean scan, or `nil`.
  # Only used to recognise a lockfile record written before v2 for exactly
  # these bytes (the one-time upgrade audit); never a content identity.
  @spec legacy_hash(scan()) :: String.t() | nil
  def legacy_hash(%{files: files, violations: []}) do
    files
    |> Enum.map_join("\n", &"#{&1.path}\t#{&1.sha256}")
    |> sha256_hex()
  end

  def legacy_hash(_scan), do: nil

  @doc "The `{path, sha256}` manifest of the scanned files."
  @spec manifest(scan()) :: [{String.t(), String.t()}]
  def manifest(%{files: files}), do: Enum.map(files, &{&1.path, &1.sha256})

  @doc "Human-readable finding text for a layout violation."
  @spec describe_violation(violation()) :: String.t()
  def describe_violation(%{path: path, reason: reason}) do
    "#{path}: #{violation_text(reason)}"
  end

  defp violation_text(:hidden), do: "hidden entries are not allowed in a skill bundle"

  defp violation_text(:invalid_name),
    do: "entry names may not contain control or format characters, `\\`, `:` or invalid UTF-8"

  defp violation_text(:outside_layout), do: "entry is outside the audited skill bundle layout"
  defp violation_text(:symlink), do: "symlinks are not allowed in a skill bundle"
  defp violation_text(:not_regular), do: "only regular files and directories are allowed"
  defp violation_text(:not_directory), do: "bundle directory entry is not a directory"
  defp violation_text(:missing_skill_md), do: "SKILL.md is missing or not a regular file"
  defp violation_text(:too_large), do: "file exceeds #{@max_file_bytes} bytes"
  defp violation_text(:too_many_files), do: "bundle exceeds #{@max_files} files"
  defp violation_text(:total_too_large), do: "bundle exceeds #{@max_total_bytes} bytes"
  defp violation_text(:path_too_long), do: "path exceeds #{@max_path_bytes} bytes"
  defp violation_text(:unreadable), do: "entry could not be read"
  defp violation_text(:hard_link), do: "hard-linked files are not allowed in a skill bundle"

  @doc """
  Reads a scanned file again and returns its bytes only when they still match
  the scanned digest.
  """
  @spec read_verified(file_info()) :: {:ok, binary()} | {:error, :changed | term()}
  def read_verified(%{full_path: full_path, sha256: sha256}) do
    with {:ok, stat} <- File.lstat(full_path),
         :regular <- stat.type,
         {:ok, bytes} <- bounded_read(full_path, stat) do
      if sha256_hex(bytes) == sha256, do: {:ok, bytes}, else: {:error, :changed}
    else
      {:error, _} = error -> error
      _ -> {:error, :changed}
    end
  end

  @doc """
  Copies exactly the scanned files of `scan` into the new directory `dest`,
  writing only bytes whose digest matches the scan. `dest` must not exist.
  """
  @spec copy_files(scan(), String.t()) :: :ok | {:error, term()}
  def copy_files(%{files: files}, dest) when is_binary(dest) do
    with :ok <- File.mkdir(dest) do
      Enum.reduce_while(files, :ok, fn file, :ok ->
        target = Path.join(dest, file.path)

        with :ok <- File.mkdir_p(Path.dirname(target)),
             {:ok, bytes} <- read_verified(file),
             :ok <- write_new(target, bytes),
             :ok <- File.chmod(target, Bitwise.band(file.mode, 0o755)) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:copy_failed, file.path, reason}}}
        end
      end)
    end
  end

  @doc """
  Copies a source bundle into `dest` through `scan/1`; a source holding any
  violation is refused with `{:error, {:bundle_violations, violations}}`.
  """
  @spec copy_tree(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def copy_tree(source, dest) when is_binary(source) and is_binary(dest) do
    with {:ok, scan} <- scan(source),
         :ok <- require_clean(scan),
         :ok <- copy_files(scan, dest) do
      {:ok, dest}
    end
  end

  @doc """
  Resolves a bundle-relative path to a regular file inside `root`.

  The path must stay inside the bundle layout, may not contain hidden or
  traversal segments, and every segment is lstat-checked: symlinks, FIFOs,
  devices and directories are refused, as are files over the byte cap. The
  bundle root itself is not lstat-checked, so a registered root may be a link.
  """
  @spec resolve_file(String.t(), String.t() | [String.t()]) ::
          {:ok, String.t(), File.Stat.t()} | {:error, read_error()}
  def resolve_file(root, rel) when is_binary(rel), do: resolve_file(root, split_relative(rel))

  def resolve_file(root, segments) when is_binary(root) and is_list(segments) do
    with :ok <- validate_segments(segments),
         {:ok, path, stat} <- walk(Path.expand(root), segments),
         :ok <- validate_layout(segments) do
      if stat.size > @max_file_bytes, do: {:error, :too_large}, else: {:ok, path, stat}
    end
  end

  @doc """
  Reads a bundle file through `resolve_file/2`. The opened handle must be the
  same inode the lstat walk accepted, and the walk is repeated after the read,
  so a swap to a symlink or special file during the read is refused.
  """
  @spec read_file(String.t(), String.t() | [String.t()]) ::
          {:ok, binary()} | {:error, read_error()}
  def read_file(root, rel) do
    with {:ok, path, stat} <- resolve_file(root, rel),
         {:ok, bytes} <- bounded_read(path, stat),
         {:ok, ^path, after_stat} <- resolve_file(root, rel),
         true <- same_file?(stat, after_stat) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :changed}
    end
  end

  @spec review_payload(scan() | String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def review_payload(scan_or_dir, opts \\ [])

  def review_payload(skill_dir, opts) when is_binary(skill_dir) do
    with {:ok, scan} <- scan(skill_dir), do: review_payload(scan, opts)
  end

  def review_payload(%{files: files, violations: violations}, opts) when is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 32_768)

    {sections, _used} =
      Enum.reduce(files, {[], 0}, fn file, {acc, used} ->
        case read_verified(file) do
          {:ok, bytes} when file.text? ->
            remaining = max(max_bytes - used, 0)
            excerpt = excerpt(bytes, remaining)

            section = """
            ### #{file.path}
            type: text
            bytes: #{file.size}

            #{excerpt}
            """

            {[section | acc], min(max_bytes, used + byte_size(excerpt))}

          {:ok, _bytes} ->
            section = """
            ### #{file.path}
            type: binary
            bytes: #{file.size}
            sha256: #{file.sha256}
            """

            {[section | acc], used}

          {:error, _reason} ->
            {["### #{file.path}\ntype: unreadable\n" | acc], used}
        end
      end)

    violation_section =
      case violations do
        [] ->
          ""

        _ ->
          "\nLayout violations:\n" <>
            Enum.map_join(violations, "\n", &("- " <> describe_violation(&1)))
      end

    {:ok,
     """
     Review this skill bundle.

     Bundle files:
     #{Enum.map_join(files, "\n", fn file -> "- #{file.path} (#{file.size} bytes)" end)}
     #{violation_section}

     #{sections |> Enum.reverse() |> Enum.join("\n\n")}
     """}
  end

  # ── scanning ────────────────────────────────────────────────────────────────

  defp scan_root_entry(root, name, acc) do
    full = Path.join(root, name)

    cond do
      not valid_name?(name) ->
        violation(acc, escape_name(name), :invalid_name)

      hidden?(name) ->
        violation(acc, name, :hidden)

      name == "SKILL.md" ->
        case File.lstat(full) do
          {:ok, stat} -> scan_file(acc, name, full, stat)
          {:error, _} -> violation(acc, name, :unreadable)
        end

      name in @allowed_dirs ->
        case File.lstat(full) do
          {:ok, %File.Stat{type: :directory}} -> scan_dir(root, name, acc)
          {:ok, %File.Stat{type: :symlink}} -> violation(acc, name, :symlink)
          {:ok, _} -> violation(acc, name, :not_directory)
          {:error, _} -> violation(acc, name, :unreadable)
        end

      true ->
        case File.lstat(full) do
          {:ok, %File.Stat{type: :symlink}} -> violation(acc, name, :symlink)
          _ -> violation(acc, name, :outside_layout)
        end
    end
  end

  defp scan_dir(root, rel_dir, acc) do
    case list_names(Path.join(root, rel_dir)) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce(acc, fn name, acc ->
          rel = rel_dir <> "/" <> name
          full = Path.join(root, rel)

          cond do
            not valid_name?(name) ->
              violation(acc, rel_dir <> "/" <> escape_name(name), :invalid_name)

            hidden?(name) ->
              violation(acc, rel, :hidden)

            byte_size(rel) > @max_path_bytes ->
              violation(acc, rel, :path_too_long)

            true ->
              case File.lstat(full) do
                {:ok, %File.Stat{type: :directory}} -> scan_dir(root, rel, acc)
                {:ok, stat} -> scan_file(acc, rel, full, stat)
                {:error, _} -> violation(acc, rel, :unreadable)
              end
          end
        end)

      {:error, _} ->
        violation(acc, rel_dir, :unreadable)
    end
  end

  defp scan_file(acc, rel, _full, %File.Stat{type: :symlink}), do: violation(acc, rel, :symlink)

  defp scan_file(acc, rel, full, %File.Stat{type: :regular, size: size} = stat) do
    cond do
      stat.links > 1 ->
        violation(acc, rel, :hard_link)

      size > @max_file_bytes ->
        violation(acc, rel, :too_large)

      acc.count + 1 > @max_files ->
        violation(acc, rel, :too_many_files)

      acc.bytes + size > @max_total_bytes ->
        violation(acc, rel, :total_too_large)

      true ->
        case bounded_read(full, stat) do
          {:ok, bytes} ->
            info = %{
              path: rel,
              full_path: full,
              sha256: sha256_hex(bytes),
              size: byte_size(bytes),
              mode: stat.mode,
              text?: text_file?(bytes),
              group: file_group(rel)
            }

            %{acc | files: [info | acc.files], count: acc.count + 1, bytes: acc.bytes + size}

          {:error, _} ->
            violation(acc, rel, :unreadable)
        end
    end
  end

  defp scan_file(acc, rel, _full, _stat), do: violation(acc, rel, :not_regular)

  defp violation(acc, path, reason) do
    %{acc | violations: [%{path: path, reason: reason} | acc.violations]}
  end

  # Lists every entry, raw (non-UTF-8) names included, so no name the
  # filesystem holds is silently left out of the scan.
  defp list_names(dir) do
    with {:ok, names} <- :file.list_dir_all(dir) do
      {:ok, Enum.map(names, &name_to_binary/1)}
    end
  end

  defp name_to_binary(name) when is_binary(name), do: name

  defp name_to_binary(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      bin when is_binary(bin) -> bin
      _ -> <<0xFF>>
    end
  end

  # The one entry-name policy, shared by `scan/1` and `resolve_file/2`: valid
  # UTF-8 with no control (C0/C1), format/bidi, `/`, `\` or `:` characters.
  defp valid_name?(name) when is_binary(name) do
    String.valid?(name) and not Regex.match?(~r/[\p{Cc}\p{Cf}\/\\:]/u, name)
  end

  defp valid_name?(_name), do: false

  # An injective, printable rendering of a rejected name for violation paths
  # and findings: raw control bytes never reach audit text or prompts.
  defp escape_name(name), do: inspect(name, binaries: :as_strings)

  # Opens the lstat-accepted regular file, checks the handle is that inode and
  # reads at most the byte cap plus one byte.
  defp bounded_read(path, %File.Stat{} = stat) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          with {:ok, info} <- :file.read_file_info(fd),
               true <-
                 elem(info, 2) == :regular and inode_of(info) == {stat.major_device, stat.inode} do
            read_capped(fd)
          else
            {:error, _} = error -> error
            _ -> {:error, :changed}
          end
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_capped(fd) do
    case :file.read(fd, @max_file_bytes + 1) do
      {:ok, bytes} when byte_size(bytes) > @max_file_bytes -> {:error, :too_large}
      {:ok, bytes} -> {:ok, bytes}
      :eof -> {:ok, ""}
      {:error, _} = error -> error
    end
  end

  # file_info record: {:file_info, size, type, access, atime, mtime, ctime,
  #                    mode, links, major_device, minor_device, inode, uid, gid}
  defp inode_of(info), do: {elem(info, 9), elem(info, 11)}

  defp same_file?(%File.Stat{} = a, %File.Stat{} = b),
    do: a.major_device == b.major_device and a.inode == b.inode

  # ── path resolution ─────────────────────────────────────────────────────────

  defp split_relative(rel) do
    if String.contains?(rel, "\\"), do: [:invalid], else: String.split(rel, "/")
  end

  defp validate_segments([]), do: {:error, :invalid_path}

  defp validate_segments(segments) do
    cond do
      Enum.any?(segments, &(not is_binary(&1) or &1 in ["", ".", ".."])) ->
        {:error, :invalid_path}

      not Enum.all?(segments, &valid_name?/1) ->
        {:error, :invalid_path}

      Enum.any?(segments, &hidden?/1) ->
        {:error, :hidden}

      true ->
        :ok
    end
  end

  defp walk(root, segments) do
    Enum.reduce_while(Enum.with_index(segments, 1), {:ok, root, nil}, fn {segment, index},
                                                                         {:ok, parent, _} ->
      path = Path.join(parent, segment)
      last? = index == length(segments)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, :symlink}}

        {:ok, %File.Stat{type: :regular, links: links}} when last? and links > 1 ->
          {:halt, {:error, :hard_link}}

        {:ok, %File.Stat{type: :regular} = stat} when last? ->
          {:cont, {:ok, path, stat}}

        {:ok, %File.Stat{type: :directory} = stat} when not last? ->
          {:cont, {:ok, path, stat}}

        {:ok, _} ->
          {:halt, {:error, :not_regular}}

        {:error, :enoent} ->
          {:halt, {:error, :enoent}}

        {:error, :enotdir} ->
          {:halt, {:error, :enoent}}

        {:error, _} ->
          {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp validate_layout(["SKILL.md"]), do: :ok
  defp validate_layout([dir, _ | _]) when dir in @allowed_dirs, do: :ok
  defp validate_layout(_segments), do: {:error, :outside_layout}

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp write_new(target, bytes) do
    case :file.open(target, [:write, :exclusive, :binary, :raw]) do
      {:ok, fd} ->
        try do
          :file.write(fd, bytes)
        after
          :file.close(fd)
        end

      {:error, _} = error ->
        error
    end
  end

  defp hidden?(name), do: String.starts_with?(name, ".")

  defp file_group("SKILL.md"), do: :skill
  defp file_group("references/" <> _), do: :references
  defp file_group("templates/" <> _), do: :templates
  defp file_group("scripts/" <> _), do: :scripts
  defp file_group("assets/" <> _), do: :assets

  defp text_file?(bytes) when is_binary(bytes) do
    not String.contains?(bytes, <<0>>) and String.valid?(bytes)
  end

  defp excerpt(_bytes, remaining) when remaining <= 0, do: "[truncated]"

  defp excerpt(bytes, remaining) do
    if byte_size(bytes) <= remaining do
      bytes
    else
      binary_part(bytes, 0, remaining) <> "\n[truncated]"
    end
  end

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end
end
