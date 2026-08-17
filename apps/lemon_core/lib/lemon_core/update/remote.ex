defmodule LemonCore.Update.Remote do
  @moduledoc """
  Stage-2 self-update: check a published manifest, stage a new release under
  `~/.lemon/versions/`, and atomically flip the `current` symlink.

  Never restarts the running node — `apply/1` stages a version and reports
  `restart_required: true`; the shim/operator restarts the process.

  ## Manifest v2

  Fetched from `<base_url>/releases/latest/download/manifest.json` (stable) or
  `<base_url>/releases/download/v<pin>/manifest.json` (pinned), the same
  no-rate-limit URL scheme the installer uses. `base_url` defaults to
  `https://github.com/z80dev/lemon`, overridable via the `:base_url` option or
  `config :lemon_core, :update_base_url` (test seam).

  ## Install layout

      ~/.lemon/versions/<version>/          # extracted release
      ~/.lemon/versions/<version>/tui/bin/  # terminal UI, when published
      ~/.lemon/versions/current             # symlink, atomic flip point
      ~/.lemon/tmp/                         # download staging

  The terminal UI ships as its own per-platform artifact (profile
  `lemon_tui`) that unpacks into `tui/` beside the runtime's `bin/`. Both
  tarballs are downloaded and checksum-verified before either is extracted,
  and both are staged into the same `versions/<version>.partial` directory, so
  the single rename plus symlink flip installs them together or not at all. A
  manifest without a `lemon_tui` entry updates the runtime only — the same
  degradation the installer applies to pre-TUI releases. The
  `sim_broadcast_platform` profile never fetches one, and `LEMON_NO_TUI=1`
  opts out, mirroring the installer.

  `apply/1` refuses to run outside this layout (manual tarball / server
  installs opt out by construction — they don't live under
  `versions/<version>/`).

  ## Options

  Every function accepts:

    * `:base_url` — manifest/artifact host, see above.
    * `:channel` — defaults to the `[runtime].channel` TOML setting, then
      `"stable"`.
    * `:version` — a pin (e.g. `"2026.09.0"`), defaults to
      `[runtime].pinned_version`. Non-stable channels require a pin.
    * `:profile` — defaults to `RELEASE_NAME` (the running release profile).
    * `:platform` — defaults to the detected `os-arch` tag; override for tests.
    * `:paths_opts` — forwarded to `LemonCore.Paths` so callers/tests can scope
      the state directory away from the real `~/.lemon`.
    * `:release_root` — defaults to `RELEASE_ROOT`, then `:code.root_dir/0`.
  """

  alias LemonCore.Paths
  alias LemonCore.Update.Version

  @default_base_url "https://github.com/z80dev/lemon"
  @default_channel "stable"
  @keep_versions 2
  @tui_profile "lemon_tui"
  @sim_profile "sim_broadcast_platform"

  @type opts :: keyword()
  @type artifact :: %{optional(String.t()) => term()}
  @type check_result :: %{
          current: String.t(),
          latest: String.t() | nil,
          update_available?: boolean(),
          artifact: artifact() | nil,
          tui_artifact: artifact() | nil,
          channel: String.t(),
          auto_update: boolean()
        }

  @doc """
  Fetches the manifest for the configured channel/pin and compares it against
  the running version.

  Hard-fails unless the manifest declares `"schema": 2`. Does not download or
  stage anything.
  """
  @spec check(opts()) :: {:ok, check_result()} | {:error, term()}
  def check(opts \\ []) do
    channel = channel(opts)
    pin = pin(opts)

    with :ok <- validate_channel(channel, pin),
         url <- manifest_url(base_url(opts), pin),
         {:ok, manifest} <- fetch_manifest(url) do
      current = Version.current()
      latest = manifest["version"]

      {:ok,
       %{
         current: current,
         latest: latest,
         update_available?: update_available?(current, latest),
         artifact: select_artifact(manifest, opts),
         tui_artifact: select_tui_artifact(manifest, opts),
         channel: channel,
         auto_update: auto_update?(opts)
       }}
    end
  end

  @doc """
  Downloads, verifies, and stages the latest matching artifacts.

  Refuses to run unless the current release is installed under
  `<state_home>/versions/<version>/` (the layout guard). Streams each download
  to `<state_home>/tmp/` — the response body is never buffered in memory —
  and verifies its SHA-256 against the manifest (mandatory; a missing or
  mismatched checksum is a hard error and the partial downloads are deleted).
  Only once the runtime and, when published, the TUI are both verified does it
  extract them into `versions/<version>.partial`, assert the staged tree holds
  the executables it should, rename that into place, and atomically flip
  `versions/current` via symlink-tmp + rename. An existing usable install of
  the same version is reused rather than deleted and re-extracted, so the
  directory `current` points at is never cleared to make room. Prunes old
  versions, keeping the newly staged one plus the #{@keep_versions} most recent others.

  Never restarts the node. On success, `restart_required: true` tells the
  caller a restart is needed to run the staged version.
  """
  @spec apply(opts()) :: {:ok, map()} | {:error, term()}
  def apply(opts \\ []) do
    with :ok <- guard_layout(opts),
         {:ok, info} <- check(opts) do
      do_apply(info, opts)
    end
  end

  @doc """
  Flips `versions/current` to the newest retained version other than the
  active one.
  """
  @spec rollback(opts()) :: {:ok, %{active: String.t()}} | {:error, term()}
  def rollback(opts \\ []) do
    with :ok <- guard_layout(opts) do
      dir = versions_dir(opts)
      active = active_version(dir)

      case candidates(dir, active) do
        [newest | _] ->
          case flip_current(newest, opts) do
            :ok -> {:ok, %{active: newest}}
            {:error, reason} -> {:error, reason}
          end

        [] ->
          {:error, :no_rollback_candidate}
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # check/1
  # ──────────────────────────────────────────────────────────────────────────

  defp channel(opts),
    do: Keyword.get(opts, :channel) || runtime_setting(opts, "channel") || @default_channel

  defp pin(opts), do: Keyword.get(opts, :version) || runtime_setting(opts, "pinned_version")

  defp validate_channel(@default_channel, _pin), do: :ok
  defp validate_channel(_channel, pin) when is_binary(pin) and pin != "", do: :ok
  defp validate_channel(channel, _pin), do: {:error, {:channel_requires_pin, channel}}

  defp manifest_url(base_url, pin) when is_binary(pin) and pin != "" do
    "#{base_url}/releases/download/v#{pin}/manifest.json"
  end

  defp manifest_url(base_url, _pin), do: "#{base_url}/releases/latest/download/manifest.json"

  defp fetch_manifest(url) do
    request = {String.to_charlist(url), []}

    case LemonCore.Httpc.request(:get, request, [timeout: 10_000, autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, body}} -> decode_manifest(body)
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:manifest_http_status, status}}
      {:error, reason} -> {:error, {:manifest_request_failed, reason}}
    end
  end

  defp decode_manifest(body) do
    case Jason.decode(body) do
      {:ok, %{"schema" => 2} = manifest} -> {:ok, manifest}
      {:ok, %{"schema" => other}} -> {:error, {:unsupported_manifest_schema, other}}
      {:ok, _manifest} -> {:error, :missing_manifest_schema}
      {:error, reason} -> {:error, {:invalid_manifest_json, reason}}
    end
  end

  defp update_available?(_current, nil), do: false
  defp update_available?(current, latest), do: Version.newer?(current, latest)

  defp select_artifact(manifest, opts) do
    case profile(opts) do
      profile when is_binary(profile) -> find_artifact(manifest, platform(opts), profile)
      _ -> nil
    end
  end

  # The terminal UI is optional: releases published before it existed have no
  # such entry, the sim profile has no terminal UI at all, and LEMON_NO_TUI=1
  # is the same opt-out the installer honours — an operator who installed
  # runtime-only should not have one appear underneath them on update.
  defp select_tui_artifact(manifest, opts) do
    if profile(opts) == @sim_profile or System.get_env("LEMON_NO_TUI") == "1" do
      nil
    else
      find_artifact(manifest, platform(opts), @tui_profile)
    end
  end

  defp find_artifact(manifest, platform, profile) when is_binary(platform) do
    case manifest["artifacts"] do
      artifacts when is_list(artifacts) ->
        Enum.find(artifacts, fn a -> a["platform"] == platform and a["profile"] == profile end)

      _ ->
        nil
    end
  end

  defp find_artifact(_manifest, _platform, _profile), do: nil

  defp profile(opts), do: Keyword.get(opts, :profile) || System.get_env("RELEASE_NAME")
  defp platform(opts), do: Keyword.get(opts, :platform) || detect_platform()

  defp detect_platform do
    with os when is_binary(os) <- detect_os(),
         arch when is_binary(arch) <- detect_arch() do
      "#{os}-#{arch}"
    else
      _ -> nil
    end
  end

  defp detect_os do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      _ -> nil
    end
  end

  defp detect_arch do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    cond do
      String.starts_with?(arch, "x86_64") or String.starts_with?(arch, "amd64") -> "x86_64"
      String.starts_with?(arch, "aarch64") or String.starts_with?(arch, "arm64") -> "arm64"
      true -> nil
    end
  end

  defp auto_update?(opts) do
    case Keyword.get(opts, :auto_update, runtime_setting(opts, "auto_update")) do
      true -> true
      _ -> false
    end
  end

  defp runtime_setting(opts, key) do
    settings = raw_runtime_settings(opts)
    Map.get(settings, key)
  end

  defp raw_runtime_settings(opts) do
    po = paths_opts(opts)
    global = LemonCore.Config.load_file(Paths.global_config(po))
    project = LemonCore.Config.load_file(Paths.project_config(File.cwd!(), po))
    merged = LemonCore.MapHelpers.deep_merge(global, project)

    case merged["runtime"] do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # apply/1
  # ──────────────────────────────────────────────────────────────────────────

  defp do_apply(%{update_available?: false, current: current, latest: latest}, _opts) do
    {:ok, %{staged: nil, restart_required: false, current: current, latest: latest}}
  end

  defp do_apply(%{artifact: nil}, _opts), do: {:error, :no_matching_artifact}

  defp do_apply(%{artifact: artifact, latest: version, current: current} = info, opts) do
    tui_artifact = Map.get(info, :tui_artifact)

    with {:ok, final_dir} <- stage(artifact, tui_artifact, version, opts),
         :ok <- flip_current(version, opts) do
      prune(opts, version)

      {:ok,
       %{
         staged: version,
         restart_required: true,
         current: current,
         latest: version,
         path: final_dir
       }}
    end
  end

  # Downloads, extraction, and validation, with a guaranteed cleanup of the
  # staging directory and both downloads. The `after` block also covers raises
  # from the bang calls and file streaming below, which would otherwise sail
  # past every explicit cleanup path and strand a `<version>.partial` directory
  # that the next update would have to guess about. On the success path it is a
  # no-op: `promote/2` has already renamed the staging directory away.
  defp stage(artifact, tui_artifact, version, opts) do
    dir = versions_dir(opts)
    partial = Path.join(dir, "#{version}.partial")
    downloads = Enum.map([artifact, tui_artifact], &artifact_path(&1, opts))

    try do
      with {:ok, tarballs} <- download_verified(artifact, tui_artifact, version, opts),
           :ok <- unpack(tarballs, partial),
           :ok <- verify_staged(partial, tui_artifact) do
        promote(partial, Path.join(dir, version))
      end
    after
      File.rm_rf(partial)

      Enum.each(downloads, fn
        nil -> :ok
        path -> File.rm(path)
      end)
    end
  end

  # Every byte is on disk and checksum-verified before anything is extracted:
  # a bad TUI download must not leave a half-staged version behind.
  defp download_verified(artifact, tui_artifact, version, opts) do
    with {:ok, tarball} <- download_one(artifact, version, opts) do
      case download_optional(tui_artifact, version, opts) do
        {:ok, tui_tarball} ->
          {:ok, {tarball, tui_tarball}}

        {:error, reason} ->
          File.rm(tarball)
          {:error, reason}
      end
    end
  end

  defp download_optional(nil, _version, _opts), do: {:ok, nil}
  defp download_optional(artifact, version, opts), do: download_one(artifact, version, opts)

  defp download_one(artifact, version, opts) do
    with {:ok, tarball} <- download_artifact(artifact, version, opts),
         :ok <- verify_checksum(tarball, artifact) do
      {:ok, tarball}
    end
  end

  # A manifest is fetched over the network, so its `file` is untrusted input:
  # anything that is not a bare filename would let a release write outside the
  # download directory.
  defp artifact_path(nil, _opts), do: nil

  defp artifact_path(artifact, opts) do
    case Map.get(artifact, "file") do
      file when is_binary(file) and file != "" ->
        if Path.basename(file) == file, do: Path.join(tmp_dir(opts), file)

      _ ->
        nil
    end
  end

  defp download_artifact(artifact, version, opts) do
    case artifact_path(artifact, opts) do
      nil -> {:error, {:invalid_artifact_file, Map.get(artifact, "file")}}
      dest -> download_to(dest, Map.get(artifact, "file"), version, opts)
    end
  end

  defp download_to(dest, file, version, opts) do
    url = "#{base_url(opts)}/releases/download/v#{version}/#{file}"
    File.mkdir_p!(tmp_dir(opts))
    File.rm(dest)

    request = {String.to_charlist(url), []}
    http_opts = [timeout: 300_000, connect_timeout: 10_000, autoredirect: true]
    stream_opts = [stream: String.to_charlist(dest), sync: true]

    case LemonCore.Httpc.request(:get, request, http_opts, stream_opts) do
      {:ok, :saved_to_file} ->
        {:ok, dest}

      {:ok, {{_, status, _}, _headers, _body}} ->
        File.rm(dest)
        {:error, {:download_http_status, status}}

      {:error, reason} ->
        File.rm(dest)
        {:error, {:download_failed, reason}}
    end
  end

  defp verify_checksum(path, artifact) do
    expected = artifact["sha256"]

    cond do
      not (is_binary(expected) and expected != "") ->
        File.rm(path)
        {:error, :missing_checksum}

      true ->
        actual = sha256_file(path)

        if String.downcase(expected) == actual do
          :ok
        else
          File.rm(path)
          {:error, {:checksum_mismatch, expected: expected, actual: actual}}
        end
    end
  end

  defp sha256_file(path) do
    path
    |> File.stream!(2 * 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # The runtime owns bin/ and lib/, the TUI owns tui/, so both unpack into one
  # staging directory and ride the same rename into place.
  defp unpack({tarball, tui_tarball}, partial) do
    File.rm_rf(partial)

    case File.mkdir_p(partial) do
      :ok -> extract_all(partial, [tarball, tui_tarball])
      {:error, reason} -> {:error, {:staging_failed, reason}}
    end
  end

  # Nothing is promoted until the staged tree actually holds the launchers it
  # is supposed to, mirroring the same assertions install.sh makes. A tarball
  # that unpacked into the wrong shape must not become `versions/current`.
  defp verify_staged(partial, tui_artifact) do
    cond do
      not executable?(Path.join(partial, "bin/lemon")) ->
        {:error, {:incomplete_release, "bin/lemon"}}

      not is_nil(tui_artifact) and not executable?(Path.join(partial, "tui/bin/lemon-tui")) ->
        {:error, {:incomplete_release, "tui/bin/lemon-tui"}}

      true ->
        :ok
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp extract_all(partial, tarballs) do
    Enum.reduce_while(tarballs, :ok, fn tarball, :ok ->
      case extract_into(partial, tarball) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp extract_into(_partial, nil), do: :ok

  defp extract_into(partial, tarball) do
    case System.cmd("tar", ["-xzf", tarball, "-C", partial], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:extract_failed, code, output}}
    end
  end

  # Never clear the destination to make room. Re-staging a version that is
  # already installed would otherwise delete the very directory `current`
  # points at, and an interruption mid-delete leaves a dangling `current` with
  # nothing to fall back to. A usable install is kept as-is; only a broken one
  # is replaced, and it is moved aside rather than deleted so the swap can be
  # undone if the rename fails.
  defp promote(partial, final) do
    cond do
      usable_install?(final) -> {:ok, final}
      File.exists?(final) -> replace(partial, final)
      true -> rename_into_place(partial, final)
    end
  end

  defp replace(partial, final) do
    aside = "#{final}.broken.#{os_pid()}"
    File.rm_rf(aside)

    case File.rename(final, aside) do
      :ok -> swap_in(partial, final, aside)
      {:error, reason} -> {:error, {:rename_failed, reason}}
    end
  end

  defp swap_in(partial, final, aside) do
    case rename_into_place(partial, final) do
      {:ok, dir} ->
        File.rm_rf(aside)
        {:ok, dir}

      {:error, reason} ->
        File.rename(aside, final)
        {:error, reason}
    end
  end

  defp rename_into_place(partial, final) do
    case File.rename(partial, final) do
      :ok -> {:ok, final}
      {:error, reason} -> {:error, {:rename_failed, reason}}
    end
  end

  defp usable_install?(dir), do: executable?(Path.join(dir, "bin/lemon"))

  defp os_pid, do: List.to_string(:os.getpid())

  # A fixed temp name races a concurrent updater and, if the rename fails,
  # leaves a stray symlink sitting in versions/ forever.
  defp flip_current(version, opts) do
    dir = versions_dir(opts)
    current = Path.join(dir, "current")
    tmp = Path.join(dir, ".current.tmp.#{os_pid()}")

    try do
      File.rm(tmp)

      with :ok <- File.ln_s(version, tmp),
           :ok <- File.rename(tmp, current) do
        :ok
      else
        {:error, reason} -> {:error, {:symlink_failed, reason}}
      end
    after
      File.rm(tmp)
    end
  end

  defp prune(opts, current_version) do
    dir = versions_dir(opts)

    dir
    |> version_dirs()
    |> Enum.reject(&(&1 == current_version))
    |> newest_first()
    |> Enum.drop(@keep_versions)
    |> Enum.each(&File.rm_rf(Path.join(dir, &1)))

    :ok
  end

  defp candidates(dir, active) do
    dir
    |> version_dirs()
    |> Enum.reject(&(&1 == active))
    |> newest_first()
  end

  defp newest_first(versions), do: Enum.sort(versions, &(Version.compare(&1, &2) != :lt))

  defp version_dirs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "current"))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reject(&(String.ends_with?(&1, ".partial") or String.contains?(&1, ".broken.")))
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))

      {:error, _reason} ->
        []
    end
  end

  defp active_version(dir) do
    case File.read_link(Path.join(dir, "current")) do
      {:ok, target} -> Path.basename(target)
      {:error, _reason} -> nil
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Layout guard
  # ──────────────────────────────────────────────────────────────────────────

  defp guard_layout(opts) do
    root = Path.expand(release_root(opts))
    versions = Path.expand(versions_dir(opts))

    if String.starts_with?(root, versions <> "/") do
      :ok
    else
      {:error,
       {:unsupported_layout,
        "not running from #{versions}/<version> — this looks like a manual tarball or " <>
          "server install; use the tarball/docker upgrade flow instead of `lemon update`"}}
    end
  end

  defp release_root(opts) do
    Keyword.get(opts, :release_root) || System.get_env("RELEASE_ROOT") ||
      List.to_string(:code.root_dir())
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Shared config
  # ──────────────────────────────────────────────────────────────────────────

  defp base_url(opts) do
    Keyword.get(opts, :base_url) ||
      Application.get_env(:lemon_core, :update_base_url) ||
      @default_base_url
  end

  defp paths_opts(opts), do: Keyword.get(opts, :paths_opts, [])
  defp state_home(opts), do: Paths.home_state_dir(paths_opts(opts))
  defp versions_dir(opts), do: Path.join(state_home(opts), "versions")
  defp tmp_dir(opts), do: Path.join(state_home(opts), "tmp")
end
