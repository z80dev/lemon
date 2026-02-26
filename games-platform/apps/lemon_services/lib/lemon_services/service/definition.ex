defmodule LemonServices.Service.Definition do
  @moduledoc """
  Service definition struct and validation.

  A service definition is the declarative configuration for a service.
  It can be loaded from YAML or created at runtime.
  """

  @type command ::
          {:shell, String.t()}
          | {:shell, [String.t()]}
          | {:module, module(), atom(), [term()]}

  @type restart_policy :: :permanent | :transient | :temporary

  @type health_check ::
          {:http, String.t(), pos_integer()}
          | {:tcp, String.t(), pos_integer(), pos_integer()}
          | {:command, String.t(), pos_integer()}
          | {:function, module(), atom(), [term()], pos_integer()}

  @type t :: %__MODULE__{
          id: atom(),
          name: String.t(),
          description: String.t(),
          command: command(),
          working_dir: Path.t() | nil,
          env: %{String.t() => String.t()},
          auto_start: boolean(),
          restart_policy: restart_policy(),
          health_check: health_check() | nil,
          max_restarts: pos_integer(),
          max_memory_mb: pos_integer() | nil,
          tags: [atom()],
          created_by: String.t() | nil,
          persistent: boolean()
        }

  defstruct [
    :id,
    :name,
    :description,
    :command,
    :working_dir,
    :env,
    :health_check,
    auto_start: false,
    restart_policy: :transient,
    max_restarts: 5,
    max_memory_mb: nil,
    tags: [],
    created_by: nil,
    persistent: false
  ]

  @doc """
  Creates a new service definition with validation.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) do
    definition = struct(__MODULE__, attrs)

    case validate(definition) do
      :ok -> {:ok, definition}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new service definition, raising on invalid input.
  """
  @spec new!(keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, message: reason
    end
  end

  @doc """
  Validates a service definition.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(%__MODULE__{} = definition) do
    cond do
      is_nil(definition.id) or not is_atom(definition.id) ->
        {:error, "id is required and must be an atom"}

      is_nil(definition.name) or not is_binary(definition.name) ->
        {:error, "name is required and must be a string"}

      is_nil(definition.command) ->
        {:error, "command is required"}

      not valid_command?(definition.command) ->
        {:error, "invalid command format"}

      not valid_restart_policy?(definition.restart_policy) ->
        {:error, "invalid restart_policy"}

      definition.health_check != nil and not valid_health_check?(definition.health_check) ->
        {:error, "invalid health_check format"}

      true ->
        :ok
    end
  end

  defp valid_command?({:shell, cmd}) when is_binary(cmd), do: true
  defp valid_command?({:shell, args}) when is_list(args), do: true
  defp valid_command?({:module, mod, fun, args}) when is_atom(mod) and is_atom(fun) and is_list(args), do: true
  defp valid_command?(_), do: false

  defp valid_restart_policy?(policy) when policy in [:permanent, :transient, :temporary], do: true
  defp valid_restart_policy?(_), do: false

  defp valid_health_check?({:http, url, interval}) when is_binary(url) and is_integer(interval) and interval > 0, do: true
  defp valid_health_check?({:tcp, host, port, interval}) when is_binary(host) and is_integer(port) and is_integer(interval) and interval > 0, do: true
  defp valid_health_check?({:command, cmd, interval}) when is_binary(cmd) and is_integer(interval) and interval > 0, do: true
  defp valid_health_check?({:function, mod, fun, args, interval}) when is_atom(mod) and is_atom(fun) and is_list(args) and is_integer(interval) and interval > 0, do: true
  defp valid_health_check?(_), do: false

  @doc """
  Converts a service definition to a map (for serialization).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = definition) do
    %{
      "id" => Atom.to_string(definition.id),
      "name" => definition.name,
      "description" => definition.description,
      "command" => command_to_map(definition.command),
      "working_dir" => definition.working_dir,
      "env" => definition.env,
      "auto_start" => definition.auto_start,
      "restart_policy" => Atom.to_string(definition.restart_policy),
      "health_check" => health_check_to_map(definition.health_check),
      "max_restarts" => definition.max_restarts,
      "max_memory_mb" => definition.max_memory_mb,
      "tags" => Enum.map(definition.tags, &Atom.to_string/1),
      "persistent" => definition.persistent
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Creates a service definition from a map (from YAML/deserialization).
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()
      |> Map.update(:id, nil, &String.to_atom/1)
      |> Map.update(:restart_policy, :transient, &String.to_atom/1)
      |> Map.update(:tags, [], fn tags -> Enum.map(tags, &String.to_atom/1) end)
      |> Map.update(:command, nil, &map_to_command/1)
      |> Map.update(:health_check, nil, &map_to_health_check/1)

    new(Map.to_list(attrs))
  end

  defp command_to_map({:shell, cmd}) when is_binary(cmd), do: %{"type" => "shell", "cmd" => cmd}
  defp command_to_map({:shell, args}) when is_list(args), do: %{"type" => "shell", "args" => args}
  defp command_to_map({:module, mod, fun, args}), do: %{"type" => "module", "module" => inspect(mod), "function" => Atom.to_string(fun), "args" => args}

  defp map_to_command(%{"type" => "shell", "cmd" => cmd}), do: {:shell, cmd}
  defp map_to_command(%{"type" => "shell", "args" => args}), do: {:shell, args}
  defp map_to_command(%{"type" => "module", "module" => mod, "function" => fun, "args" => args}) do
    {:module, Module.concat([mod]), String.to_atom(fun), args}
  end

  defp health_check_to_map(nil), do: nil
  defp health_check_to_map({:http, url, interval}), do: %{"type" => "http", "url" => url, "interval_ms" => interval}
  defp health_check_to_map({:tcp, host, port, interval}), do: %{"type" => "tcp", "host" => host, "port" => port, "interval_ms" => interval}
  defp health_check_to_map({:command, cmd, interval}), do: %{"type" => "command", "cmd" => cmd, "interval_ms" => interval}
  defp health_check_to_map({:function, mod, fun, args, interval}), do: %{"type" => "function", "module" => inspect(mod), "function" => Atom.to_string(fun), "args" => args, "interval_ms" => interval}

  defp map_to_health_check(nil), do: nil
  defp map_to_health_check(%{"type" => "http", "url" => url, "interval_ms" => interval}), do: {:http, url, interval}
  defp map_to_health_check(%{"type" => "tcp", "host" => host, "port" => port, "interval_ms" => interval}), do: {:tcp, host, port, interval}
  defp map_to_health_check(%{"type" => "command", "cmd" => cmd, "interval_ms" => interval}), do: {:command, cmd, interval}
  defp map_to_health_check(%{"type" => "function", "module" => mod, "function" => fun, "args" => args, "interval_ms" => interval}) do
    {:function, Module.concat([mod]), String.to_atom(fun), args, interval}
  end
end
