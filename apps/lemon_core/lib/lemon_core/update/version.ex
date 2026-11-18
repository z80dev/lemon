defmodule LemonCore.Update.Version do
  @moduledoc """
  CalVer version parsing and comparison for Lemon.

  Version format: `YYYY.MM.PATCH`

  Examples: `2026.03.0`, `2026.03.1`, `2026.04.0`

  The patch counter resets to 0 on each new month and increments for
  hotfixes and out-of-cycle releases.
  """

  @calver_regex ~r/^(\d{4})\.(\d{1,2})\.(\d+)(-[a-zA-Z0-9._-]+)?$/
  @source_root Path.expand("../../../../..", __DIR__)

  @type parsed :: {integer(), integer(), integer()}

  @doc """
  Returns the current Lemon version string.

  Packaged runtimes use `RELEASE_VSN`. Source checkouts use the umbrella
  CalVer, not lemon_core's independent OTP application version.
  """
  @spec current() :: String.t()
  def current do
    case System.get_env("RELEASE_VSN") do
      vsn when is_binary(vsn) and vsn != "" ->
        vsn

      _ ->
        source_version() || application_version()
    end
  end

  @doc "Build identity for diagnostics; release metadata is stamped when assembled."
  @spec info() :: map()
  def info do
    version = current()

    if System.get_env("RELEASE_VSN") not in [nil, ""] do
      metadata = release_metadata(version)

      %{
        version: version,
        mode: "release",
        commit: metadata["commit"] || "unknown",
        channel: metadata["channel"] || "unknown"
      }
    else
      %{version: version, mode: "source", commit: source_commit(), channel: "source"}
    end
  end

  @doc "Human-readable build identity. `current/0` remains machine-readable CalVer."
  @spec describe() :: String.t()
  def describe do
    build = info()
    "Lemon #{build.version} (#{build.mode}; commit #{build.commit}; channel #{build.channel})"
  end

  defp release_metadata(version) do
    root = System.get_env("RELEASE_ROOT") || List.to_string(:code.root_dir())

    with {:ok, json} <- File.read(Path.join([root, "releases", version, "lemon-build.json"])),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(json) do
      metadata
    else
      _ -> %{}
    end
  end

  defp source_version do
    with {:ok, source} <- File.read(Path.join(source_root(), "mix.exs")),
         [_, version] <- Regex.run(~r/version:\s*"(\d{4}\.\d{1,2}\.\d+[^"]*)"/, source) do
      version
    else
      _ -> nil
    end
  end

  defp source_commit do
    with {:ok, repo} <- LemonCore.SafeGit.repository(source_root()),
         {:ok, commit, 0} <- LemonCore.SafeGit.run(repo, ["rev-parse", "--short=12", "HEAD"]) do
      String.trim(commit)
    else
      _ -> "unknown"
    end
  end

  defp source_root, do: System.get_env("LEMON_PATH") || @source_root

  defp application_version do
    case Application.spec(:lemon_core, :vsn) do
      nil -> "unknown"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Parses a version string into `{year, month, patch}` tuple.

  Returns `{:ok, {year, month, patch}}` or `:error`.
  """
  @spec parse(String.t()) :: {:ok, parsed()} | :error
  def parse(str) when is_binary(str) do
    case Regex.run(@calver_regex, String.trim(str), capture: :all_but_first) do
      [year, month, patch | _] ->
        {:ok, {String.to_integer(year), String.to_integer(month), String.to_integer(patch)}}

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Compares two CalVer strings.

  Returns `:lt`, `:eq`, or `:gt`.
  Falls back to string comparison if either version cannot be parsed.
  """
  @spec compare(String.t(), String.t()) :: :lt | :eq | :gt
  def compare(v1, v2) when is_binary(v1) and is_binary(v2) do
    with {:ok, t1} <- parse(v1),
         {:ok, t2} <- parse(v2) do
      cond do
        t1 < t2 -> :lt
        t1 > t2 -> :gt
        true -> :eq
      end
    else
      _ ->
        cond do
          v1 < v2 -> :lt
          v1 > v2 -> :gt
          true -> :eq
        end
    end
  end

  @doc """
  Returns `true` when `candidate` is strictly newer than `current`.
  """
  @spec newer?(String.t(), String.t()) :: boolean()
  def newer?(current, candidate), do: compare(current, candidate) == :lt

  @doc """
  Returns `true` when the version string matches CalVer format.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(str), do: match?({:ok, _}, parse(str))
end
