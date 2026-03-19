defmodule LemonCore.Runtime.Profile do
  @moduledoc """
  Runtime profiles for Lemon.

  A profile is a named set of OTP applications that should be started together.
  Profiles replace the ad-hoc app lists that were hard-coded in `bin/lemon`.

  ## Available profiles

  | Profile | Apps | Use case |
  |---|---|---|
  | `:runtime_min` | gateway, router, channels, control_plane, coding_agent | CI, headless, embedded |
  | `:runtime_full` | all of the above + automation, skills, web, sim_ui | Local development |

  ## Usage

      profile = LemonCore.Runtime.Profile.get(:runtime_full)
      profile.apps
      # => [:lemon_gateway, :lemon_router, ...]

      LemonCore.Runtime.Profile.app_list(:runtime_min)
      # => [:lemon_gateway, :lemon_router, :lemon_channels, :lemon_control_plane]
  """

  @enforce_keys [:name, :apps, :description]
  defstruct [:name, :apps, :description]

  @type t :: %__MODULE__{
          name: atom(),
          apps: [atom()],
          description: String.t()
        }

  @profiles_data %{
    runtime_min: {
      "Minimal runtime: gateway, router, channels, control plane, and coding agent.",
      [:coding_agent, :lemon_gateway, :lemon_router, :lemon_channels, :lemon_control_plane]
    },
    runtime_full: {
      "Full runtime: all core apps including skills, web UI, and sim UI.",
      [
        :coding_agent,
        :lemon_gateway,
        :lemon_router,
        :lemon_channels,
        :lemon_control_plane,
        :lemon_automation,
        :lemon_skills,
        :lemon_web,
        :lemon_sim_ui
      ]
    }
  }

  @doc """
  Returns the profile struct for the given name.

  Raises `ArgumentError` for an unknown profile name.

  ## Examples

      iex> LemonCore.Runtime.Profile.get(:runtime_full)
      %LemonCore.Runtime.Profile{name: :runtime_full, ...}
  """
  @spec get(atom()) :: t()
  def get(name) when is_atom(name) do
    case Map.get(@profiles_data, name) do
      nil ->
        raise ArgumentError, "Unknown runtime profile: #{inspect(name)}"

      {description, apps} ->
        %__MODULE__{name: name, description: description, apps: apps}
    end
  end

  @doc """
  Returns the list of OTP application names for the given profile.
  """
  @spec app_list(atom()) :: [atom()]
  def app_list(name), do: get(name).apps

  @doc """
  Returns all available profile names.
  """
  @spec names() :: [atom()]
  def names, do: Map.keys(@profiles_data)

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
