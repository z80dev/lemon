defmodule LemonCore.Update.Plan do
  @moduledoc """
  Pure update-plan validation and digest construction.

  The plan is intentionally data-only. It binds the managed installation's
  current pointer and running version to the raw schema-2 manifest hash,
  release commit, selected target/profile/platform, and exact runtime/TUI
  artifact integrity fields. No function in this module reads or writes disk,
  performs network requests, or executes release code.
  """

  @default_artifact_max_bytes 2_147_483_648
  @default_ttl_ms 15 * 60 * 1_000
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @safe_version_pattern ~r/\A[0-9A-Za-z][0-9A-Za-z._~-]{0,63}\z/
  @safe_identifier_pattern ~r/\A[0-9A-Za-z][0-9A-Za-z._-]{0,63}\z/

  @spec build(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(info, opts) when is_map(info) and is_list(opts) do
    current = Keyword.fetch!(opts, :current)
    running = Keyword.fetch!(opts, :running)
    profile = Keyword.fetch!(opts, :profile)
    platform = Keyword.fetch!(opts, :platform)
    now_ms = Keyword.fetch!(opts, :now_ms)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    with :ok <- validate_version(info.latest),
         :ok <- validate_identifier(info.channel, :invalid_channel),
         :ok <- validate_identifier(profile, :invalid_profile),
         :ok <- validate_identifier(platform, :invalid_platform),
         :ok <- validate_commit(info.manifest_commit),
         :ok <- validate_sha256(info.manifest_sha256, :invalid_manifest_checksum),
         :ok <- validate_artifact(info.artifact, profile, platform, opts),
         :ok <- validate_optional_tui(info.tui_artifact, platform, opts) do
      epoch = div(now_ms, ttl_ms)

      plan = %{
        schema: 1,
        action: if(info.update_available?, do: "apply", else: "none"),
        current: current,
        running: running,
        latest: info.latest,
        target: info.latest,
        channel: info.channel,
        profile: profile,
        platform: platform,
        manifest_commit: info.manifest_commit,
        manifest_sha256: info.manifest_sha256,
        artifact: artifact_summary(info.artifact),
        tui_artifact: artifact_summary(info.tui_artifact),
        plan_epoch: epoch,
        expires_at_ms: (epoch + 1) * ttl_ms
      }

      {:ok, Map.put(plan, :digest, digest(plan))}
    end
  end

  @spec digest(map()) :: String.t()
  def digest(plan) when is_map(plan) do
    plan
    |> Map.take([
      :action,
      :artifact,
      :channel,
      :current,
      :expires_at_ms,
      :latest,
      :manifest_commit,
      :manifest_sha256,
      :plan_epoch,
      :platform,
      :profile,
      :running,
      :schema,
      :target,
      :tui_artifact
    ])
    |> canonical_term()
    |> sha256()
  end

  @spec rollback_digest(map(), map()) :: String.t()
  def rollback_digest(plan, checkpoint) do
    %{
      schema: 1,
      action: "rollback",
      checkpoint_id: checkpoint["id"],
      checkpoint_sha256: checkpoint["launcher_sha256"],
      from_version: plan.target,
      plan_digest: plan.digest,
      to_version: plan.current
    }
    |> canonical_term()
    |> sha256()
  end

  @spec secure_equal?(term(), term()) :: boolean()
  def secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  def secure_equal?(_left, _right), do: false

  @spec safe_version?(term()) :: boolean()
  def safe_version?(version) when is_binary(version),
    do: Regex.match?(@safe_version_pattern, version)

  def safe_version?(_version), do: false

  defp validate_version(version) do
    if safe_version?(version), do: :ok, else: {:error, :invalid_manifest_version}
  end

  defp validate_identifier(value, error) do
    if is_binary(value) and Regex.match?(@safe_identifier_pattern, value),
      do: :ok,
      else: {:error, error}
  end

  defp validate_commit(commit) do
    if is_binary(commit) and Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, commit),
      do: :ok,
      else: {:error, :invalid_manifest_commit}
  end

  defp validate_optional_tui(nil, _platform, _opts), do: :ok

  defp validate_optional_tui(artifact, platform, opts),
    do: validate_artifact(artifact, "lemon_tui", platform, opts)

  defp validate_artifact(nil, _profile, _platform, _opts), do: {:error, :no_matching_artifact}

  defp validate_artifact(artifact, expected_profile, expected_platform, opts) do
    file = artifact["file"]
    size = artifact["size"]
    max_bytes = Keyword.get(opts, :max_artifact_bytes, @default_artifact_max_bytes)

    cond do
      not safe_filename?(file) ->
        {:error, :invalid_artifact_file}

      artifact["profile"] != expected_profile ->
        {:error, :artifact_profile_mismatch}

      artifact["platform"] != expected_platform ->
        {:error, :artifact_platform_mismatch}

      true ->
        with :ok <- validate_sha256(artifact["sha256"], :invalid_artifact_checksum),
             true <- is_integer(size) and size > 0 and size <= max_bytes do
          :ok
        else
          false -> {:error, :invalid_artifact_size}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_sha256(value, error) do
    if is_binary(value) and Regex.match?(@sha256_pattern, String.downcase(value)),
      do: :ok,
      else: {:error, error}
  end

  defp safe_filename?(file) do
    is_binary(file) and file != "" and Path.basename(file) == file and String.valid?(file) and
      not String.contains?(file, ["\n", "\r", "\0"])
  end

  defp artifact_summary(nil), do: nil

  defp artifact_summary(artifact),
    do: Map.take(artifact, ["file", "profile", "platform", "sha256", "size"])

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ?:, canonical_term(nested)] end)
    |> Enum.intersperse(?,)
    |> then(&[?{, &1, ?}])
  end

  defp canonical_term(value) when is_list(value) do
    value |> Enum.map(&canonical_term/1) |> Enum.intersperse(?,) |> then(&[?[, &1, ?]])
  end

  defp canonical_term(value), do: Jason.encode!(value)

  defp sha256(bytes) do
    binary = IO.iodata_to_binary(bytes)
    :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
  end
end
