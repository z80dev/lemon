defmodule LemonControlPlane.Methods.SessionsChanges do
  @moduledoc """
  Read-only workspace changes for a native session's cwd: a bounded `git
  status` file list with per-file `+`/`-` counts, or — when `path` is given —
  one bounded unified diff.

  Targets resolve like `sessions.context` (`sessionKey` + `cwd`). Every Git
  command runs through `LemonCore.SafeGit`: the repository is located with file
  reads and must be owned by the Lemon user, and Git runs without a shell, with
  a minimal environment, a deadline, an output cap, literal pathspecs, no
  optional index locks and every program-selecting setting (fsmonitor, hooks,
  filter/diff drivers, external diff, submodule recursion) disabled, so a
  repository's own configuration cannot make a read run commands or write to
  the index. A repository failing SafeGit's checks answers `unavailable`.

  Results are limited to the `cwd` subtree: listed paths are relative to `cwd`
  and a diff is served only for a path that the current status reports as
  changed, so a request can never read files outside the workspace. Absolute
  paths, repository roots and git's own error text are never returned.

  A `cwd` outside a git work tree answers `repository: false` with state
  `not_git_repository` rather than an error.

  The diff `patch` is file content and needs `operator.content`; read-only
  callers get the changed file's status, counts and `patchBytes`.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.SafeGit

  @max_files 300
  @max_status_bytes 2_000_000
  @max_diff_bytes 256_000
  @max_diff_lines 3_000
  @max_count_bytes 512_000
  @max_counted_untracked 100
  @timeout_ms 5_000
  @max_path_bytes 4_096

  # Output formatting the parsers below rely on; SafeGit's settings follow.
  @format_config [{"core.quotepath", "off"}, {"diff.noprefix", "false"}]

  @impl true
  def name, do: "sessions.changes"

  @impl true
  def scopes, do: [:read]

  # Git on a large work tree can take seconds; keep it off the connection process.
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx) do
    content? = Authorize.content?(ctx)

    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, path} <- optional_path(params),
         :ok <- workspace(cwd),
         {:ok, git} <- git_executable() do
      case repository(git, cwd) do
        {:ok, git, repo} when is_nil(path) -> status_response(git, cwd, key, repo)
        {:ok, git, repo} -> diff_response(git, cwd, key, repo, path, content?)
        :not_repository -> {:ok, not_repository(key, path)}
        {:error, reason} -> failure(reason)
      end
      |> case do
        {:ok, payload} -> {:ok, Map.put(payload, "contentWithheld", not content?)}
        error -> error
      end
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────

  defp optional_path(params) do
    case Map.get(params, "path") do
      nil ->
        {:ok, nil}

      path when is_binary(path) and byte_size(path) > 0 and byte_size(path) <= @max_path_bytes ->
        if safe_relative_path?(path),
          do: {:ok, path},
          else: NativeSessions.invalid("path must be a relative path inside the workspace")

      _ ->
        NativeSessions.invalid(
          "path must be a non-empty string of at most #{@max_path_bytes} bytes"
        )
    end
  end

  @doc false
  def safe_relative_path?(path) do
    segments = String.split(path, "/")

    String.valid?(path) and not String.contains?(path, [<<0>>, "\\"]) and
      Path.type(path) == :relative and
      not String.starts_with?(path, "-") and
      Enum.all?(segments, &(&1 not in ["..", "."])) and
      Enum.any?(segments, &(&1 != ""))
  end

  defp workspace(cwd) do
    if Path.type(cwd) == :absolute and File.dir?(cwd),
      do: :ok,
      else: {:error, {:not_found, "Workspace directory not found", nil}}
  end

  defp git_executable do
    case SafeGit.executable() do
      {:ok, git} -> {:ok, git}
      {:error, _} -> {:error, {:unavailable, "git is not available on this host", nil}}
    end
  end

  defp failure(:timeout),
    do: {:error, {:unavailable, "Reading workspace changes timed out", %{"reason" => "timeout"}}}

  defp failure(:not_changed),
    do: {:error, {:not_found, "That file has no workspace changes", nil}}

  defp failure(_reason),
    do: {:error, {:unavailable, "Workspace changes are unavailable", nil}}

  # ── Repository discovery ───────────────────────────────────────────────

  # `git` becomes the SafeGit repository and executable every later command
  # uses.
  defp repository(executable, cwd) do
    case SafeGit.repository(cwd) do
      {:ok, safe} ->
        git = %{executable: executable, repo: safe}

        case git(git, cwd, ["rev-parse", "--is-inside-work-tree", "--show-prefix"], 4_096) do
          {:ok, out, 0} ->
            case String.split(out, "\n") do
              ["true", prefix | _] -> {:ok, git, %{prefix: prefix, base: base(git, cwd)}}
              _ -> :not_repository
            end

          {:error, reason} ->
            {:error, reason}

          _ ->
            {:error, :git_failed}
        end

      :not_repository ->
        :not_repository

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Compare against HEAD; a repository without commits compares against the
  # empty tree so staged and unstaged additions still show.
  defp base(git, cwd) do
    case git(git, cwd, ["rev-parse", "--verify", "-q", "HEAD"], 256) do
      {:ok, _, 0} ->
        "HEAD"

      _ ->
        case git(git, cwd, ["hash-object", "-t", "tree", "/dev/null"], 256) do
          {:ok, out, 0} -> String.trim(out)
          _ -> "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        end
    end
  end

  defp not_repository(key, path) do
    base = %{"sessionKey" => key, "repository" => false, "state" => "not_git_repository"}

    if path,
      do: Map.put(base, "diff", nil),
      else:
        Map.merge(base, %{
          "branch" => nil,
          "files" => [],
          "totals" => %{"files" => 0, "additions" => 0, "deletions" => 0},
          "truncated" => false,
          "limit" => @max_files
        })
  end

  # ── Status ─────────────────────────────────────────────────────────────

  defp status_response(git, cwd, key, repo) do
    case status(git, cwd, repo) do
      {:ok, %{branch: branch, entries: entries, truncated: truncated}} ->
        counts = numstat(git, cwd, repo)
        total = length(entries)
        shown = Enum.take(entries, @max_files)

        files =
          shown
          |> Enum.with_index()
          |> Enum.map(fn {entry, index} -> file_entry(entry, counts, cwd, index) end)

        {:ok,
         %{
           "sessionKey" => key,
           "repository" => true,
           "state" => "ok",
           "branch" => branch,
           "files" => files,
           "totals" => %{
             "files" => total,
             "additions" => sum(files, "additions"),
             "deletions" => sum(files, "deletions")
           },
           "truncated" => truncated or total > @max_files,
           "limit" => @max_files,
           "measuredAt" => System.system_time(:millisecond)
         }}

      {:error, reason} ->
        failure(reason)
    end
  end

  defp status(git, cwd, repo) do
    # `all` lists files inside new directories (what an agent usually creates);
    # the byte cap and deadline bound pathological untracked trees.
    args = ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--", "."]

    case git(git, cwd, args, @max_status_bytes) do
      {:ok, out, 0} -> {:ok, parse_status(out, repo.prefix, false)}
      {:truncated, out, _} -> {:ok, parse_status(out, repo.prefix, true)}
      {:ok, _out, _status} -> {:error, :git_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def parse_status(out, prefix, truncated) do
    records = String.split(out, <<0>>)
    {branch, records} = branch(records)

    entries =
      records
      |> status_entries([])
      |> Enum.flat_map(&relative_entry(&1, prefix))
      |> Enum.sort_by(& &1.path)

    %{branch: branch, entries: entries, truncated: truncated}
  end

  defp branch(["## " <> header | rest]), do: {branch_name(header), rest}
  defp branch(records), do: {nil, records}

  defp branch_name("No commits yet on " <> name), do: clean(name, 120)
  defp branch_name("HEAD (no branch)" <> _), do: nil

  defp branch_name(header) do
    header |> String.split(["...", " "], parts: 2) |> hd() |> clean(120)
  end

  defp status_entries([], acc), do: Enum.reverse(acc)
  defp status_entries([""], acc), do: Enum.reverse(acc)

  defp status_entries([<<x, y, ?\s, path::binary>> | rest], acc) when x in [?R, ?C] do
    {orig, rest} =
      case rest do
        [orig | rest] -> {orig, rest}
        [] -> {nil, []}
      end

    status_entries(rest, [%{x: x, y: y, path: path, orig: orig} | acc])
  end

  defp status_entries([<<x, y, ?\s, path::binary>> | rest], acc),
    do: status_entries(rest, [%{x: x, y: y, path: path, orig: nil} | acc])

  defp status_entries([_malformed | rest], acc), do: status_entries(rest, acc)

  # Porcelain paths are repository-relative; keep the cwd subtree only and
  # present paths relative to cwd.
  defp relative_entry(%{path: path} = entry, prefix) do
    case strip_prefix(path, prefix) do
      nil -> []
      "" -> []
      rel -> [%{entry | path: rel, orig: entry.orig && strip_prefix(entry.orig, prefix)}]
    end
  end

  defp strip_prefix(path, ""), do: path

  defp strip_prefix(path, prefix) do
    if String.starts_with?(path, prefix),
      do: binary_part(path, byte_size(prefix), byte_size(path) - byte_size(prefix))
  end

  defp file_entry(entry, counts, cwd, index) do
    untracked = entry.x == ?? and entry.y == ??
    directory = untracked and String.ends_with?(entry.path, "/")

    {additions, deletions, binary} =
      cond do
        directory -> {nil, nil, false}
        untracked and index < @max_counted_untracked -> untracked_counts(cwd, entry.path)
        untracked -> {nil, nil, false}
        true -> Map.get(counts, entry.path, {nil, nil, false})
      end

    %{
      "path" => clean(entry.path, @max_path_bytes),
      "origPath" => entry.orig && clean(entry.orig, @max_path_bytes),
      "status" => status_code(entry.x, entry.y),
      "index" => <<entry.x>>,
      "worktree" => <<entry.y>>,
      "staged" => entry.x not in [?\s, ??, ?!],
      "untracked" => untracked,
      "directory" => directory,
      "binary" => binary,
      "additions" => additions,
      "deletions" => deletions
    }
  end

  @doc false
  def status_code(??, ??), do: "untracked"

  def status_code(x, y) when x == ?U or y == ?U or (x == ?A and y == ?A) or (x == ?D and y == ?D),
    do: "conflicted"

  def status_code(?R, _), do: "renamed"
  def status_code(?C, _), do: "copied"
  def status_code(x, y) when x == ?D or y == ?D, do: "deleted"
  def status_code(?A, _), do: "added"
  def status_code(x, y) when x == ?T or y == ?T, do: "type_changed"
  def status_code(_, _), do: "modified"

  defp untracked_counts(cwd, rel) do
    full = Path.join(cwd, rel)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_count_bytes <-
           File.lstat(full),
         {:ok, data} <- File.read(full) do
      if binary?(data) do
        {nil, nil, true}
      else
        lines = data |> :binary.matches("\n") |> length()
        lines = if data != "" and not String.ends_with?(data, "\n"), do: lines + 1, else: lines
        {lines, 0, false}
      end
    else
      _ -> {nil, nil, false}
    end
  end

  defp binary?(data),
    do: :binary.match(binary_part(data, 0, min(byte_size(data), 8_000)), <<0>>) != :nomatch

  defp numstat(git, cwd, repo) do
    args = [
      "diff",
      "--numstat",
      "-z",
      "-M",
      "--relative",
      "--no-ext-diff",
      "--no-textconv",
      repo.base,
      "--",
      "."
    ]

    case git(git, cwd, args, @max_status_bytes) do
      {:ok, out, 0} -> parse_numstat(out)
      {:truncated, out, _} -> parse_numstat(out)
      _ -> %{}
    end
  end

  @doc false
  def parse_numstat(out), do: out |> String.split(<<0>>) |> numstat_records(%{})

  defp numstat_records([], acc), do: acc

  # Renames: "add\tdel\t" then old and new paths as separate records.
  defp numstat_records([record, _old, new | rest], acc)
       when binary_part(record, byte_size(record) - 1, 1) == "\t" do
    numstat_records(rest, put_count(acc, new, record))
  end

  defp numstat_records([record | rest], acc) do
    case String.split(record, "\t", parts: 3) do
      [_, _, path] when path != "" -> numstat_records(rest, put_count(acc, path, record))
      _ -> numstat_records(rest, acc)
    end
  end

  defp put_count(acc, path, record) do
    case String.split(record, "\t", parts: 3) do
      ["-", "-" | _] -> Map.put(acc, path, {nil, nil, true})
      [add, del | _] -> Map.put(acc, path, {to_int(add), to_int(del), false})
      _ -> acc
    end
  end

  defp to_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp sum(files, key),
    do: files |> Enum.map(& &1[key]) |> Enum.filter(&is_integer/1) |> Enum.sum()

  # ── Diff ───────────────────────────────────────────────────────────────

  # The patch is file content and needs `operator.content`; read-only callers
  # get the file's status, counts and `patchBytes`.
  defp diff_response(git, cwd, key, repo, path, content?) do
    with {:ok, %{entries: entries}} <- status(git, cwd, repo),
         {:ok, entry} <- changed_entry(entries, path),
         {:ok, diff} <- diff(git, cwd, repo, entry) do
      diff =
        if content?,
          do: diff,
          else: diff |> Map.delete("patch") |> Map.put("patchBytes", byte_size(diff["patch"]))

      {:ok, %{"sessionKey" => key, "repository" => true, "state" => "ok", "diff" => diff}}
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp changed_entry(entries, path) do
    case Enum.find(entries, &(&1.path == path)) do
      nil -> {:error, :not_changed}
      entry -> {:ok, entry}
    end
  end

  defp diff(_git, _cwd, _repo, %{x: ??, path: path} = entry)
       when binary_part(path, byte_size(path) - 1, 1) == "/" do
    {:ok, diff_payload(entry, %{directory: true})}
  end

  defp diff(git, cwd, repo, entry) do
    args =
      if entry.x == ?? do
        [
          "diff",
          "--no-index",
          "--no-color",
          "--no-ext-diff",
          "--no-textconv",
          "--",
          "/dev/null",
          entry.path
        ]
      else
        [
          "diff",
          "--no-color",
          "--no-ext-diff",
          "--no-textconv",
          "-M",
          repo.base,
          "--",
          entry.path
        ] ++
          if(entry.orig, do: [entry.orig], else: [])
      end

    case git(git, cwd, args, @max_diff_bytes) do
      {:ok, out, status} when status in [0, 1] ->
        {:ok, diff_payload(entry, parse_diff(out, false))}

      {:truncated, out, _} ->
        {:ok, diff_payload(entry, parse_diff(out, true))}

      {:ok, _out, _status} ->
        {:error, :git_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def parse_diff(out, truncated) do
    lines = String.split(out, "\n")

    binary =
      Enum.any?(lines, fn line ->
        String.starts_with?(line, "Binary files ") or line == "GIT binary patch"
      end)

    hunk_lines =
      lines
      |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
      |> drop_trailing_empty()

    {kept, line_truncated} =
      if length(hunk_lines) > @max_diff_lines,
        do: {Enum.take(hunk_lines, @max_diff_lines), true},
        else: {hunk_lines, false}

    # A byte-truncated read may end mid-line; drop the partial last line.
    kept = if truncated and kept != [], do: Enum.drop(kept, -1), else: kept

    %{
      binary: binary,
      truncated: truncated or line_truncated,
      patch: if(binary, do: "", else: kept |> Enum.join("\n") |> clean(@max_diff_bytes)),
      additions: Enum.count(kept, &String.starts_with?(&1, "+")),
      deletions: Enum.count(kept, &String.starts_with?(&1, "-")),
      line_count: length(kept)
    }
  end

  defp drop_trailing_empty(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end

  defp diff_payload(entry, %{directory: true}) do
    %{
      "path" => clean(entry.path, @max_path_bytes),
      "origPath" => nil,
      "status" => "untracked",
      "directory" => true,
      "binary" => false,
      "truncated" => false,
      "patch" => "",
      "additions" => nil,
      "deletions" => nil,
      "lineCount" => 0,
      "limits" => %{"bytes" => @max_diff_bytes, "lines" => @max_diff_lines}
    }
  end

  defp diff_payload(entry, parsed) do
    %{
      "path" => clean(entry.path, @max_path_bytes),
      "origPath" => entry.orig && clean(entry.orig, @max_path_bytes),
      "status" => status_code(entry.x, entry.y),
      "directory" => false,
      "binary" => parsed.binary,
      "truncated" => parsed.truncated,
      "patch" => parsed.patch,
      "additions" => if(parsed.binary, do: nil, else: parsed.additions),
      "deletions" => if(parsed.binary, do: nil, else: parsed.deletions),
      "lineCount" => parsed.line_count,
      "limits" => %{"bytes" => @max_diff_bytes, "lines" => @max_diff_lines}
    }
  end

  # ── Git runner ─────────────────────────────────────────────────────────

  defp git(%{executable: executable, repo: repo}, cwd, args, max_bytes) do
    SafeGit.run(repo, args,
      git: executable,
      cd: cwd,
      timeout_ms: @timeout_ms,
      max_bytes: max_bytes,
      config: @format_config
    )
  end

  # Strings leave as valid, bounded UTF-8 (file names and contents need not be).
  defp clean(value, max) when is_binary(value) do
    value = if String.valid?(value), do: value, else: String.replace_invalid(value)

    if byte_size(value) > max,
      do: value |> binary_part(0, max) |> String.replace_invalid() |> trim_partial(),
      else: value
  end

  defp clean(_value, _max), do: nil

  defp trim_partial(value), do: String.trim_trailing(value, "\uFFFD")
end
