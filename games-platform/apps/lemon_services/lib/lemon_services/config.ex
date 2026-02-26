defmodule LemonServices.Config do
  @moduledoc """
  Configuration loading for service definitions.

  Loads service definitions from:
  - config/services.yml (static config)
  - config/services.d/*.yml (additional static configs)
  - Runtime-created persistent services
  """

  alias LemonServices.Service.Definition

  require Logger

  @services_file Path.join([File.cwd!(), "config", "services.yml"])
  @services_d_dir Path.join([File.cwd!(), "config", "services.d"])
  @persistent_dir Path.join([File.cwd!(), "config", "services.d"])

  @doc """
  Loads all service definitions from configuration files.
  """
  @spec load_all() :: [Definition.t()]
  def load_all do
    static_defs = load_static_configs()
    persistent_defs = load_persistent_configs()

    # Merge, with persistent taking precedence
    static_defs
    |> Enum.concat(persistent_defs)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Loads service definitions from the main services.yml file.
  """
  @spec load_services_yml() :: [Definition.t()]
  def load_services_yml do
    if File.exists?(@services_file) do
      case YamlElixir.read_from_file(@services_file) do
        {:ok, %{"services" => services}} when is_map(services) ->
          parse_services_map(services)

        {:ok, %{"services" => services}} when is_list(services) ->
          parse_services_list(services)

        {:ok, other} ->
          Logger.warning("Unexpected format in services.yml: #{inspect(other)}")
          []

        {:error, reason} ->
          Logger.error("Failed to load services.yml: #{inspect(reason)}")
          []
      end
    else
      Logger.debug("No services.yml found at #{@services_file}")
      []
    end
  end

  @doc """
  Loads service definitions from config/services.d/*.yml files.
  """
  @spec load_services_d() :: [Definition.t()]
  def load_services_d do
    if File.dir?(@services_d_dir) do
      @services_d_dir
      |> Path.join("*.yml")
      |> Path.wildcard()
      |> Enum.flat_map(&load_service_file/1)
    else
      []
    end
  end

  @doc """
  Saves a service definition to the persistent config directory.
  """
  @spec save_definition(Definition.t()) :: :ok | {:error, term()}
  def save_definition(%Definition{persistent: true} = definition) do
    # Ensure directory exists
    File.mkdir_p!(@persistent_dir)

    file_path = Path.join(@persistent_dir, "#{definition.id}.yml")
    content = definition_to_yaml(definition)

    File.write(file_path, content)
  end

  def save_definition(%Definition{persistent: false}) do
    # Non-persistent definitions don't get saved
    :ok
  end

  @doc """
  Removes a persistent service definition.
  """
  @spec remove_definition(atom()) :: :ok | {:error, term()}
  def remove_definition(service_id) when is_atom(service_id) do
    file_path = Path.join(@persistent_dir, "#{service_id}.yml")

    if File.exists?(file_path) do
      File.rm(file_path)
    else
      :ok
    end
  end

  # Private functions

  defp load_static_configs do
    load_services_yml() ++ load_services_d()
  end

  defp load_persistent_configs do
    # Persistent configs are in services.d/ with persistent: true
    load_services_d()
    |> Enum.filter(& &1.persistent)
  end

  defp load_service_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"services" => services}} when is_map(services) ->
        parse_services_map(services)

      {:ok, %{"service" => service}} when is_map(service) ->
        parse_single_service(service)

      {:ok, service} when is_map(service) ->
        # Single service without wrapper
        parse_single_service(service)

      {:error, reason} ->
        Logger.error("Failed to load #{path}: #{inspect(reason)}")
        []
    end
  end

  defp parse_services_map(services_map) do
    services_map
    |> Enum.map(fn {id, config} ->
      config
      |> Map.put("id", id)
      |> parse_single_service()
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_services_list(services_list) do
    services_list
    |> Enum.map(&parse_single_service/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_service(config) when is_map(config) do
    case Definition.from_map(config) do
      {:ok, definition} ->
        definition

      {:error, reason} ->
        Logger.warning("Failed to parse service config: #{reason}")
        nil
    end
  end

  defp definition_to_yaml(definition) do
    map = Definition.to_map(definition)

    # Build YAML manually for cleaner output
    lines = [
      "# Service definition for #{map["id"]}"
    ]

    lines =
      if map["description"] do
        lines ++ ["# #{map["description"]}"]
      else
        lines
      end

    lines ++ ["", "service:"]
  end

  # Config Loader GenServer - loads services on boot
  defmodule Loader do
    @moduledoc """
    GenServer that loads static service definitions on application startup.
    """
    use GenServer

    alias LemonServices.Service.Store

    require Logger

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_) do
      # Load all static service definitions
      definitions = LemonServices.Config.load_all()

      # Register each definition
      for definition <- definitions do
        case Store.register_definition(definition) do
          :ok ->
            Logger.debug("Registered service definition: #{definition.id}")

            # Auto-start if configured
            if definition.auto_start do
              Logger.info("Auto-starting service: #{definition.id}")
              LemonServices.start_service(definition.id)
            end

          {:error, reason} ->
            Logger.error("Failed to register service #{definition.id}: #{reason}")
        end
      end

      {:ok, %{loaded: length(definitions)}}
    end
  end
end
