defmodule LemonCore.Paths do
  @moduledoc """
  Filesystem layout used by lemon_core.

  Everything the library reads or writes by convention hangs off two
  directories: a per-user state directory (`~/.lemon`) and a per-project one
  (`<project>/.lemon`). Both are configurable, and the defaults are the
  reference runtime's layout, so an application embedding lemon_core can put
  its state somewhere that is not named after Lemon:

      config :lemon_core, :paths,
        state_dir: ".myapp",
        config_file: "config.toml"

  Individual locations can also be pinned outright, which wins over the
  composed default:

      config :lemon_core, :paths,
        home_state_dir: "/var/lib/myapp",
        global_config: "/etc/myapp/config.toml"

  Every function also accepts the same keys as options, which is how callers
  (and tests) scope a lookup to a temporary home without touching app env.

  ## Not covered here

  The secrets master key file has its own `:key_file` setting — see
  `LemonCore.Secrets.KeyProvider`, which resolves `~` against a caller-supplied
  home so that a scoped `HOME` cannot leak into the real key file.
  """

  @default_state_dir ".lemon"
  @default_config_file "config.toml"

  @type opts :: keyword()

  @doc "Name of the state directory, `.lemon` by default."
  @spec state_dir_name(opts()) :: String.t()
  def state_dir_name(opts \\ []), do: setting(opts, :state_dir, @default_state_dir)

  @doc "Name of the config file inside a state directory, `config.toml` by default."
  @spec config_file_name(opts()) :: String.t()
  def config_file_name(opts \\ []), do: setting(opts, :config_file, @default_config_file)

  @doc """
  The user's home directory: the `:home_dir` option, then `$HOME`.
  """
  @spec home_dir(opts()) :: String.t()
  def home_dir(opts \\ []) do
    case setting(opts, :home_dir, nil) || System.get_env("HOME") do
      value when is_binary(value) and value != "" -> value
      _ -> Path.expand("~")
    end
  end

  @doc "Per-user state directory, `~/.lemon` by default."
  @spec home_state_dir(opts()) :: String.t()
  def home_state_dir(opts \\ []) do
    case setting(opts, :home_state_dir, nil) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Path.join(home_dir(opts), state_dir_name(opts))
    end
  end

  @doc "Per-project state directory, `<cwd>/.lemon` by default."
  @spec project_state_dir(Path.t(), opts()) :: String.t()
  def project_state_dir(cwd, opts \\ []) do
    Path.join(Path.expand(cwd), state_dir_name(opts))
  end

  @doc """
  A path inside the per-user state directory.

      iex> LemonCore.Paths.home_path(["store"], home_dir: "/home/x")
      "/home/x/.lemon/store"
  """
  @spec home_path([String.t()] | String.t(), opts()) :: String.t()
  def home_path(segments, opts \\ []) do
    Path.join([home_state_dir(opts) | List.wrap(segments)])
  end

  @doc """
  A path inside a project's state directory.

      iex> LemonCore.Paths.project_path("/srv/app", ["proofs"])
      "/srv/app/.lemon/proofs"
  """
  @spec project_path(Path.t(), [String.t()] | String.t(), opts()) :: String.t()
  def project_path(cwd, segments, opts \\ []) do
    Path.join([project_state_dir(cwd, opts) | List.wrap(segments)])
  end

  @doc "Global config file, `~/.lemon/config.toml` by default."
  @spec global_config(opts()) :: String.t()
  def global_config(opts \\ []) do
    case setting(opts, :global_config, nil) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> home_path(config_file_name(opts), opts)
    end
  end

  @doc "Project config file for `cwd`, `<cwd>/.lemon/config.toml` by default."
  @spec project_config(Path.t(), opts()) :: String.t()
  def project_config(cwd, opts \\ []) do
    project_path(cwd, config_file_name(opts), opts)
  end

  defp setting(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        :lemon_core
        |> Application.get_env(:paths, [])
        |> Keyword.get(key, default)
    end
  end
end
