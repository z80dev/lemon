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
  degradation the installer applies to pre-TUI releases. `LEMON_NO_TUI=1`
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
  alias LemonCore.Update.{Archive, ManagedInstall, Plan, ReceiptStore, Version}

  @default_base_url "https://github.com/z80dev/lemon"
  @default_channel "stable"
  @keep_versions 2
  @tui_profile "lemon_tui"
  @manifest_max_bytes 1_048_576
  @artifact_max_bytes 2_147_483_648

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
         {:ok, manifest, manifest_sha256} <- fetch_manifest(url) do
      current = running_version(opts)
      latest = manifest["version"]

      {:ok,
       %{
         current: current,
         latest: latest,
         update_available?: update_available?(current, latest),
         artifact: select_artifact(manifest, opts),
         tui_artifact: select_tui_artifact(manifest, opts),
         channel: channel,
         auto_update: auto_update?(opts),
         manifest_commit: manifest["commit"],
         manifest_sha256: manifest_sha256
       }}
    end
  end

  @doc """
  Builds a non-mutating, time-bounded update plan for a managed installation.

  The opaque digest binds the exact active/running version, channel, raw
  manifest hash and commit, target, platform/profile, and every selected
  artifact's filename, size, and SHA-256. Planning performs no filesystem
  writes and never downloads an artifact.
  """
  @spec plan(opts()) :: {:ok, map()} | {:error, term()}
  def plan(opts \\ []) do
    with {:ok, current} <- ManagedInstall.current(opts),
         {:ok, info} <- check(opts) do
      Plan.build(info,
        current: current,
        running: running_version(opts),
        profile: profile(opts),
        platform: platform(opts),
        now_ms: now_ms(opts),
        max_artifact_bytes: Keyword.get(opts, :max_artifact_bytes, @artifact_max_bytes)
      )
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
    confirm = Keyword.get(opts, :confirm)

    with {:ok, preview} <- plan(opts),
         :ok <- require_confirmation(confirm, preview.digest) do
      ReceiptStore.with_lock(opts, fn -> apply_locked(opts, preview.digest) end)
    end
  end

  @doc """
  Restores the exact checkpoint named by a successful update receipt.

  Both `:receipt` and its exact `:confirm` rollback digest are required. The
  current pointer and checkpoint launcher checksum must still match the
  receipt; rollback never selects an arbitrary directory by recency.
  """
  @spec rollback(opts()) :: {:ok, map()} | {:error, term()}
  def rollback(opts \\ []) do
    ReceiptStore.with_lock(opts, fn -> rollback_locked(opts) end)
  end

  @doc "Returns bounded, content-free update receipts newest first."
  @spec history(opts()) :: {:ok, [map()]} | {:error, term()}
  def history(opts \\ []), do: ReceiptStore.history(opts)

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
      {:ok, {{_, 200, _}, _headers, body}} when byte_size(body) <= @manifest_max_bytes ->
        with {:ok, manifest} <- decode_manifest(body) do
          {:ok, manifest, sha256_bytes(body)}
        end

      {:ok, {{_, 200, _}, _headers, _body}} ->
        {:error, :manifest_too_large}

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:manifest_http_status, status}}

      {:error, reason} ->
        {:error, {:manifest_request_failed, reason}}
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
  # such entry, and LEMON_NO_TUI=1 is the same opt-out the installer honours — an operator who installed
  # runtime-only should not have one appear underneath them on update.
  defp select_tui_artifact(manifest, opts) do
    if System.get_env("LEMON_NO_TUI") == "1" do
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

  defp apply_locked(opts, expected_digest) do
    with {:ok, plan} <- plan(opts),
         :ok <- require_confirmation(expected_digest, plan.digest),
         true <- now_ms(opts) < plan.expires_at_ms || {:error, :plan_expired} do
      if plan.action == "none" do
        {:ok,
         %{
           staged: nil,
           restart_required: false,
           current: plan.current,
           latest: plan.latest
         }}
      else
        with {:ok, checkpoint} <- create_checkpoint(plan, opts) do
          apply_plan(plan, checkpoint, opts)
        end
      end
    end
  end

  defp require_confirmation(confirm, digest) when is_binary(confirm) do
    if Plan.secure_equal?(confirm, digest), do: :ok, else: {:error, :confirmation_mismatch}
  end

  defp require_confirmation(_confirm, digest), do: {:error, {:confirmation_required, digest}}

  defp create_checkpoint(plan, opts) do
    with {:ok, digest} <- ManagedInstall.launcher_sha256(plan.current, opts),
         {:ok, checkpoint} <-
           ReceiptStore.put_checkpoint(
             %{
               "action" => "update_checkpoint",
               "created_at_ms" => now_ms(opts),
               "from_version" => plan.current,
               "launcher_sha256" => digest,
               "plan_digest" => plan.digest,
               "platform" => plan.platform,
               "profile" => plan.profile,
               "status" => "verified"
             },
             opts
           ),
         {:ok, reread} <- ReceiptStore.fetch_checkpoint(checkpoint["id"], opts),
         true <- Plan.secure_equal?(reread["launcher_sha256"], digest) do
      {:ok, checkpoint}
    else
      false -> {:error, :checkpoint_verification_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_plan(plan, checkpoint, opts) do
    artifact = plan.artifact
    tui_artifact = plan.tui_artifact

    case stage(artifact, tui_artifact, plan.target, opts) do
      {:ok, final_dir} ->
        case flip_and_record(plan, checkpoint, final_dir, opts) do
          {:ok, result} ->
            ManagedInstall.prune([plan.target, plan.current], opts)
            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        _ = failed_receipt(plan, checkpoint, reason, opts)
        {:error, reason}
    end
  end

  defp flip_and_record(plan, checkpoint, final_dir, opts) do
    with :ok <- ManagedInstall.flip(plan.target, opts),
         :ok <- ManagedInstall.verify_active(plan.target, opts),
         rollback_digest <- Plan.rollback_digest(plan, checkpoint),
         {:ok, receipt} <-
           ReceiptStore.put_receipt(
             %{
               "action" => "apply",
               "channel" => plan.channel,
               "checkpoint_id" => checkpoint["id"],
               "created_at_ms" => now_ms(opts),
               "from_version" => plan.current,
               "manifest_commit" => plan.manifest_commit,
               "plan_digest" => plan.digest,
               "platform" => plan.platform,
               "profile" => plan.profile,
               "rollback_digest" => rollback_digest,
               "status" => "applied",
               "to_version" => plan.target
             },
             opts
           ) do
      {:ok,
       %{
         staged: plan.target,
         restart_required: true,
         current: plan.current,
         latest: plan.target,
         path: final_dir,
         receipt: receipt
       }}
    else
      {:error, reason} ->
        ManagedInstall.restore_after_failed_flip(plan.current, plan.target, opts)
        _ = failed_receipt(plan, checkpoint, reason, opts)
        {:error, reason}
    end
  end

  defp failed_receipt(plan, checkpoint, reason, opts) do
    ReceiptStore.put_receipt(
      %{
        "action" => "apply",
        "channel" => plan.channel,
        "checkpoint_id" => checkpoint["id"],
        "created_at_ms" => now_ms(opts),
        "from_version" => plan.current,
        "manifest_commit" => plan.manifest_commit,
        "plan_digest" => plan.digest,
        "platform" => plan.platform,
        "profile" => plan.profile,
        "status" => "failed_#{reason_kind(reason)}",
        "to_version" => plan.target
      },
      opts
    )
  end

  defp rollback_locked(opts) do
    receipt_id = Keyword.get(opts, :receipt)
    confirm = Keyword.get(opts, :confirm)

    with {:ok, _active} <- ManagedInstall.current(opts),
         {:ok, receipt} <- ReceiptStore.fetch_receipt(receipt_id, opts),
         :ok <- validate_rollback_receipt(receipt, confirm, opts),
         {:ok, checkpoint} <- ReceiptStore.fetch_checkpoint(receipt["checkpoint_id"], opts),
         :ok <- verify_checkpoint(receipt, checkpoint, opts) do
      perform_rollback(receipt, opts)
    end
  end

  # Recovery belongs strictly inside the post-flip boundary. Validation
  # failures (including a stale current pointer) must never move the pointer.
  defp perform_rollback(receipt, opts) do
    previous = receipt["to_version"]
    target = receipt["from_version"]

    with :ok <- ManagedInstall.flip(target, opts),
         :ok <- ManagedInstall.verify_active(target, opts),
         {:ok, rollback_receipt} <- put_rollback_receipt(receipt, opts) do
      {:ok,
       %{
         active: target,
         restart_required: true,
         receipt: rollback_receipt
       }}
    else
      {:error, reason} ->
        _ = ManagedInstall.restore_after_failed_flip(previous, target, opts)
        {:error, reason}
    end
  end

  defp validate_rollback_receipt(receipt, confirm, opts) do
    active = ManagedInstall.active(opts)

    cond do
      receipt["action"] != "apply" or receipt["status"] != "applied" ->
        {:error, :receipt_not_rollbackable}

      not is_binary(confirm) ->
        {:error, {:confirmation_required, receipt["rollback_digest"]}}

      not Plan.secure_equal?(confirm, receipt["rollback_digest"]) ->
        {:error, :confirmation_mismatch}

      active != receipt["to_version"] ->
        {:error, :stale_current_version}

      true ->
        :ok
    end
  end

  defp verify_checkpoint(receipt, checkpoint, opts) do
    cond do
      checkpoint["status"] != "verified" ->
        {:error, :checkpoint_not_verified}

      checkpoint["from_version"] != receipt["from_version"] ->
        {:error, :checkpoint_version_mismatch}

      checkpoint["plan_digest"] != receipt["plan_digest"] ->
        {:error, :checkpoint_plan_mismatch}

      true ->
        with {:ok, actual} <- ManagedInstall.launcher_sha256(receipt["from_version"], opts),
             true <- Plan.secure_equal?(actual, checkpoint["launcher_sha256"]) do
          :ok
        else
          false -> {:error, :checkpoint_checksum_mismatch}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp put_rollback_receipt(receipt, opts) do
    ReceiptStore.put_receipt(
      %{
        "action" => "rollback",
        "channel" => receipt["channel"],
        "checkpoint_id" => receipt["checkpoint_id"],
        "created_at_ms" => now_ms(opts),
        "from_version" => receipt["to_version"],
        "plan_digest" => receipt["plan_digest"],
        "platform" => receipt["platform"],
        "profile" => receipt["profile"],
        "rolled_back_receipt_id" => receipt["id"],
        "status" => "rolled_back",
        "to_version" => receipt["from_version"]
      },
      opts
    )
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
           :ok <- Archive.preflight(tarballs, opts),
           :ok <- unpack(tarballs, partial, opts),
           :ok <- Archive.validate_tree(partial, opts),
           :ok <- verify_staged(partial, tui_artifact, version, opts) do
        ManagedInstall.promote(partial, version, opts)
      end
    rescue
      _error -> {:error, :staging_failed}
    catch
      _kind, _reason -> {:error, :staging_failed}
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
         :ok <- verify_download_size(tarball, artifact, opts),
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

  defp verify_download_size(path, artifact, opts) do
    expected = artifact["size"]
    max_bytes = Keyword.get(opts, :max_artifact_bytes, @artifact_max_bytes)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: ^expected}} when expected <= max_bytes ->
        :ok

      {:ok, %File.Stat{type: :regular, size: actual}} ->
        File.rm(path)
        {:error, {:artifact_size_mismatch, expected, actual}}

      {:ok, _stat} ->
        File.rm(path)
        {:error, :invalid_download_file}

      {:error, reason} ->
        {:error, {:download_stat_failed, reason}}
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
  defp unpack({tarball, tui_tarball}, partial, opts) do
    File.rm_rf(partial)

    case File.mkdir_p(partial) do
      :ok -> extract_all(partial, [tarball, tui_tarball], opts)
      {:error, reason} -> {:error, {:staging_failed, reason}}
    end
  end

  # Nothing is promoted until the staged tree actually holds the launchers it
  # is supposed to, mirroring the same assertions install.sh makes. A tarball
  # that unpacked into the wrong shape must not become `versions/current`.
  defp verify_staged(partial, tui_artifact, version, opts) do
    cond do
      not executable?(Path.join(partial, "bin/lemon")) ->
        {:error, {:incomplete_release, "bin/lemon"}}

      not is_nil(tui_artifact) and not executable?(Path.join(partial, "tui/bin/lemon-tui")) ->
        {:error, {:incomplete_release, "tui/bin/lemon-tui"}}

      true ->
        ManagedInstall.verify_launcher_version(Path.join(partial, "bin/lemon"), version, opts)
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp extract_all(partial, tarballs, opts) do
    Enum.reduce_while(tarballs, :ok, fn tarball, :ok ->
      case extract_into(partial, tarball, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp extract_into(_partial, nil, _opts), do: :ok

  defp extract_into(partial, tarball, opts) do
    task =
      Task.async(fn ->
        System.cmd("tar", ["-xzf", tarball, "-C", partial], stderr_to_stdout: true)
      end)

    case Task.yield(task, Keyword.get(opts, :extract_timeout_ms, 120_000)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, code}} -> {:error, {:extract_failed, code}}
      {:exit, _reason} -> {:error, :extract_failed}
      nil -> {:error, :extract_timeout}
    end
  end

  defp running_version(opts),
    do: Keyword.get(opts, :current_version) || Version.current()

  defp now_ms(opts), do: Keyword.get(opts, :now_ms, System.system_time(:millisecond))

  defp sha256_bytes(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  defp reason_kind({kind, _rest}) when is_atom(kind), do: kind
  defp reason_kind({kind, _a, _b}) when is_atom(kind), do: kind
  defp reason_kind(kind) when is_atom(kind), do: kind
  defp reason_kind(_reason), do: :update_failed

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
  defp versions_dir(opts), do: ManagedInstall.versions_dir(opts)
  defp tmp_dir(opts), do: Path.join(state_home(opts), "tmp")
end
