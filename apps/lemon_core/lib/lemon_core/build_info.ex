defmodule LemonCore.BuildInfo do
  @moduledoc """
  Runtime build and release metadata for support surfaces.
  """

  @env_commit_keys ~w(LEMON_GIT_SHA GITHUB_SHA SOURCE_VERSION VERCEL_GIT_COMMIT_SHA)
  @env_branch_keys ~w(LEMON_GIT_BRANCH GITHUB_REF_NAME VERCEL_GIT_COMMIT_REF)

  @spec current(keyword()) :: map()
  def current(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    git = git_info(cwd)

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

  defp git_info(cwd) do
    commit = first_env(@env_commit_keys) || git_value(cwd, ["rev-parse", "--short=12", "HEAD"])
    branch = first_env(@env_branch_keys) || git_value(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])

    %{
      commit: commit,
      branch: branch,
      dirty?: git_dirty?(cwd),
      describe: git_value(cwd, ["describe", "--tags", "--always", "--dirty"])
    }
  end

  defp first_env(keys) do
    Enum.find_value(keys, &blank_to_nil(System.get_env(&1)))
  end

  defp git_value(cwd, args) do
    with git when is_binary(git) <- System.find_executable("git"),
         {value, 0} <- System.cmd(git, args, cd: cwd, stderr_to_stdout: true) do
      blank_to_nil(String.trim(value))
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp git_dirty?(cwd) do
    with git when is_binary(git) <- System.find_executable("git"),
         {value, 0} <- System.cmd(git, ["status", "--porcelain"], cd: cwd, stderr_to_stdout: true) do
      String.trim(value) != ""
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
