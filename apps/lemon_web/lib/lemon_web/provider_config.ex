defmodule LemonWeb.ProviderConfig do
  @moduledoc """
  Web adapter for `LemonAgent.ModelRuntime.ProviderConfiguration`, shared by
  the Models and Settings pages.

  Every failure collapses to a fixed `{:error, code, message}` so callers can
  map codes to their own safe text; raw messages are never rendered. Tests may
  inject `:lemon_web, :provider_configuration_fun` (arity 1) and
  `:provider_snapshot_fun` (arity 0); the project directory comes from
  `:lemon_web, :provider_configuration_project_dir` (default: the daemon cwd).
  """

  alias LemonAgent.ModelRuntime.ProviderConfiguration
  alias LemonCore.Config

  @doc "Preview (default) or apply one `ProviderConfiguration` change at global scope."
  @spec configure(map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def configure(params) do
    params = Map.merge(%{"scope" => "global", "projectDir" => project_dir()}, params)
    fun = Application.get_env(:lemon_web, :provider_configuration_fun)

    result =
      if is_function(fun, 1),
        do: fun.(params),
        else: ProviderConfiguration.configure(params)

    case result do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, code, message} when is_atom(code) and is_binary(message) -> {:error, code, message}
      _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
    end
  rescue
    _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
  catch
    :exit, _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
  end

  @doc """
  Current routing snapshot and `[defaults]` from one config load. Defaults are
  `nil` when a test snapshot function supplies only routing.
  """
  @spec snapshot() :: {:ok, map(), map() | nil} | {:error, :unavailable}
  def snapshot do
    fun = Application.get_env(:lemon_web, :provider_snapshot_fun)

    if is_function(fun, 0) do
      case fun.() do
        routing when is_map(routing) -> {:ok, routing, nil}
        _ -> {:error, :unavailable}
      end
    else
      config = Config.load(project_dir(), cache: false)

      {:ok, ProviderConfiguration.snapshot(config),
       ProviderConfiguration.defaults_snapshot(config)}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Project directory used for config loads and previews."
  @spec project_dir() :: String.t()
  def project_dir do
    case Application.get_env(:lemon_web, :provider_configuration_project_dir) do
      value when is_binary(value) and value != "" -> value
      _ -> File.cwd!()
    end
  end
end
