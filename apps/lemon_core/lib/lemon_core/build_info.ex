defmodule LemonCore.BuildInfo do
  @moduledoc """
  Runtime build and release metadata: the Lemon version identity (`version/0`,
  `identity/0`, `describe/0`) and the support-surface snapshot (`current/1`).
  """

  @env_commit_keys ~w(LEMON_GIT_SHA GITHUB_SHA SOURCE_VERSION VERCEL_GIT_COMMIT_SHA)
  @env_branch_keys ~w(LEMON_GIT_BRANCH GITHUB_REF_NAME VERCEL_GIT_COMMIT_REF)
  @source_root Path.expand("../../../..", __DIR__)

  @doc """
  Returns the current Lemon version string.

  Packaged runtimes use `RELEASE_VSN`. Source checkouts use the umbrella
  CalVer, not lemon_core's independent OTP application version.
  """
  @spec version() :: String.t()
  def version do
    case System.get_env("RELEASE_VSN") do
      vsn when is_binary(vsn) and vsn != "" ->
        vsn

      _ ->
        source_version() || application_version()
    end
  end

  @doc "Build identity for diagnostics; release metadata is stamped when assembled."
  @spec identity() :: map()
  def identity do
    version = version()

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

  @doc "Human-readable build identity. `version/0` remains machine-readable CalVer."
  @spec describe() :: String.t()
  def describe do
    build = identity()
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

  @spec current(keyword()) :: map()
  def current(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    git = git_info(cwd, Keyword.get(opts, :include_git, true))

    %{
      lemon_version: app_version(:lemon_core),
      release_name: blank_to_nil(System.get_env("RELEASE_NAME")),
      release_version: blank_to_nil(System.get_env("RELEASE_VSN")),
      release_channel: release_channel(),
      runtime_mode: runtime_mode(),
      mix_env: blank_to_nil(System.get_env("MIX_ENV")),
      git: git,
      elixir: System.version(),
      otp: System.otp_release(),
      system_architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      os: inspect(:os.type())
    }
  end

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> to_string(version)
    end
  end

  defp runtime_mode do
    if blank_to_nil(System.get_env("RELEASE_NAME")) do
      "release-runtime"
    else
      "source-dev"
    end
  end

  defp release_channel do
    blank_to_nil(System.get_env("LEMON_RELEASE_CHANNEL")) ||
      infer_channel(blank_to_nil(System.get_env("RELEASE_VSN")))
  end

  defp infer_channel(nil), do: nil

  defp infer_channel(version) do
    cond do
      String.contains?(version, "stable") -> "stable"
      String.contains?(version, "preview") -> "preview"
      String.contains?(version, "nightly") -> "nightly"
      true -> nil
    end
  end

  defp git_info(cwd, include_git) do
    if not include_git or blank_to_nil(System.get_env("RELEASE_NAME")) do
      %{
        commit:
          first_env(@env_commit_keys) ||
            blank_to_nil(Application.get_env(:lemon_core, :build_git_sha)),
        branch:
          first_env(@env_branch_keys) ||
            blank_to_nil(Application.get_env(:lemon_core, :build_git_branch)),
        dirty?: nil,
        describe: nil
      }
    else
      repo =
        case LemonCore.SafeGit.repository(cwd) do
          {:ok, repo} -> repo
          _ -> nil
        end

      %{
        commit:
          first_env(@env_commit_keys) || git_value(repo, ["rev-parse", "--short=12", "HEAD"]),
        branch:
          first_env(@env_branch_keys) || git_value(repo, ["rev-parse", "--abbrev-ref", "HEAD"]),
        dirty?: git_dirty?(repo, ["status", "--porcelain"]),
        describe: git_describe(repo)
      }
    end
  end

  defp first_env(keys) do
    Enum.find_value(keys, &blank_to_nil(System.get_env(&1)))
  end

  # The checkout is read through LemonCore.SafeGit (support bundles inspect a
  # project directory). `describe --dirty` would inspect submodule checkouts,
  # so the suffix is added here from a tracked-files status instead.
  defp git_describe(repo) do
    case git_value(repo, ["describe", "--tags", "--always"]) do
      nil ->
        nil

      describe ->
        if git_dirty?(repo, ["status", "--porcelain", "--untracked-files=no"]),
          do: describe <> "-dirty",
          else: describe
    end
  end

  defp git_value(nil, _args), do: nil

  defp git_value(repo, args) do
    case LemonCore.SafeGit.run(repo, args) do
      {:ok, value, 0} -> blank_to_nil(value)
      _ -> nil
    end
  end

  defp git_dirty?(nil, _args), do: nil

  defp git_dirty?(repo, args) do
    case LemonCore.SafeGit.run(repo, args) do
      {:ok, value, 0} -> String.trim(value) != ""
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
