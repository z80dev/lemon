defmodule LemonCore.Runtime.Profile do
  @moduledoc """
  Runtime profiles for Lemon.

  A profile is the named, ordered set of OTP applications one Lemon runtime
  starts. The profiles are compiled from `priv/runtime_profiles.exs`, the same
  file the umbrella's `mix.exs` builds the `lemon_runtime_min` and
  `lemon_runtime_full` releases from, so the source launcher
  (`LemonCore.Runtime.Boot`), the releases, `/healthz` and `lemon doctor` start
  or expect exactly the same applications.

  ## Available profiles

  | Profile | Release | Apps |
  |---|---|---|
  | `:runtime_min` | `lemon_runtime_min` | the headless runtime: everything except the web UI |
  | `:runtime_full` | `lemon_runtime_full` | `:runtime_min` plus `:lemon_web` |

  Each application has a start type: `:permanent` applications are started
  permanently (the runtime stops when one exits), `:load` applications are
  only loaded.

  ## Usage

      LemonCore.Runtime.Profile.app_list(:runtime_min)
      # => [:exqlite, :sentry, :finch, :lemon_browser, ...]

      LemonCore.Runtime.Profile.current()
      # => {:ok, :runtime_full} | :none | {:error, :unknown_profile}
  """

  @source Path.expand("../../../priv/runtime_profiles.exs", __DIR__)
  @external_resource @source

  @enforce_keys [:name, :apps, :applications, :description]
  defstruct [:name, :apps, :applications, :description]

  @type start_type :: :permanent | :load
  @type t :: %__MODULE__{
          name: atom(),
          apps: [atom()],
          applications: [{atom(), start_type()}],
          description: String.t()
        }

  {profiles, _binding} = Code.eval_file(@source)
  @profiles profiles

  @doc """
  Returns the profile struct for the given name.

  Raises `ArgumentError` for an unknown profile name.
  """
  @spec get(atom()) :: t()
  def get(name) when is_atom(name) do
    case Keyword.fetch(@profiles, name) do
      {:ok, spec} ->
        applications = Keyword.fetch!(spec, :applications)

        %__MODULE__{
          name: name,
          description: Keyword.fetch!(spec, :description),
          applications: applications,
          apps: Keyword.keys(applications)
        }

      :error ->
        raise ArgumentError, "Unknown runtime profile: #{inspect(name)}"
    end
  end

  @doc """
  Returns the list of OTP application names for the given profile, in start
  order, including the `:load`-only ones.
  """
  @spec app_list(atom()) :: [atom()]
  def app_list(name), do: get(name).apps

  @doc """
  Returns the applications of `name` that a healthy runtime has running: every
  `:permanent` application of the profile.
  """
  @spec running_apps(atom()) :: [atom()]
  def running_apps(name) do
    for {app, :permanent} <- get(name).applications, do: app
  end

  @doc """
  Returns all available profile names.
  """
  @spec names() :: [atom()]
  def names, do: Keyword.keys(@profiles)

  @doc """
  Returns the release name that ships `name` (for example `"lemon_runtime_min"`).
  """
  @spec release_name(atom()) :: String.t()
  def release_name(name), do: "lemon_#{get(name).name}"

  @doc """
  Returns the profile this node runs.

  In order: the profile `LemonCore.Runtime.Boot` started, the profile of the
  running release (`RELEASE_NAME`), then `LEMON_RUNTIME_PROFILE`. Returns
  `:none` when the node is not a Lemon runtime (for example a test VM or a
  one-shot command) and `{:error, :unknown_profile}` when the configured value
  names no profile.
  """
  @spec current() :: {:ok, atom()} | :none | {:error, :unknown_profile}
  def current do
    release = System.get_env("RELEASE_NAME")

    cond do
      booted = Application.get_env(:lemon_core, :runtime_profile) ->
        parse(to_string(booted))

      is_binary(release) and String.starts_with?(release, "lemon_runtime_") ->
        parse(String.replace_prefix(release, "lemon_", ""))

      env = System.get_env("LEMON_RUNTIME_PROFILE") ->
        parse(env)

      true ->
        :none
    end
  end

  defp parse(value) do
    case Enum.find(names(), &(Atom.to_string(&1) == value)) do
      nil -> {:error, :unknown_profile}
      name -> {:ok, name}
    end
  end

  @doc """
  Returns the default profile name for the current Mix environment.

  - `:dev` and `:test` → `:runtime_full`
  - `:prod` → `:runtime_min` (can be overridden via `LEMON_RUNTIME_PROFILE`)
  """
  @spec default_name() :: atom()
  def default_name do
    case System.get_env("LEMON_RUNTIME_PROFILE") do
      nil ->
        case Mix.env() do
          :prod -> :runtime_min
          _ -> :runtime_full
        end

      name ->
        String.to_existing_atom(name)
    end
  rescue
    ArgumentError -> :runtime_full
  end
end
