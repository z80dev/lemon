defmodule LemonServices.Service.State do
  @moduledoc """
  Runtime state for a service.

  This represents the current state of a running (or stopped) service instance.
  It is separate from the Definition, which is the declarative configuration.
  """

  alias LemonServices.Service.Definition

  @type status :: :pending | :starting | :running | :unhealthy | :stopping | :stopped | :crashed

  @type t :: %__MODULE__{
          definition: Definition.t(),
          pid: pid() | nil,
          port: port() | nil,
          status: status(),
          started_at: DateTime.t() | nil,
          stopped_at: DateTime.t() | nil,
          restart_count: non_neg_integer(),
          last_exit_code: integer() | nil,
          last_error: term() | nil,
          last_health_check: DateTime.t() | nil,
          health_status: :unknown | :healthy | :unhealthy,
          log_subscribers: MapSet.t(pid()),
          event_subscribers: MapSet.t(pid())
        }

  defstruct [
    :definition,
    :pid,
    :port,
    :started_at,
    :stopped_at,
    :last_exit_code,
    :last_error,
    :last_health_check,
    status: :pending,
    restart_count: 0,
    health_status: :unknown,
    log_subscribers: MapSet.new(),
    event_subscribers: MapSet.new()
  ]

  @doc """
  Creates a new runtime state from a definition.
  """
  @spec new(Definition.t()) :: t()
  def new(%Definition{} = definition) do
    %__MODULE__{
      definition: definition
    }
  end

  @doc """
  Updates the status and related fields.
  """
  @spec set_status(t(), status(), keyword()) :: t()
  def set_status(%__MODULE__{} = state, new_status, opts \\ []) do
    state = %{state | status: new_status}

    state =
      case new_status do
        :starting -> %{state | started_at: DateTime.utc_now()}
        :running -> %{state | started_at: state.started_at || DateTime.utc_now()}
        status when status in [:stopped, :crashed] -> %{state | stopped_at: DateTime.utc_now()}
        _ -> state
      end

    state =
      if opts[:exit_code] do
        %{state | last_exit_code: opts[:exit_code]}
      else
        state
      end

    state =
      if opts[:error] do
        %{state | last_error: opts[:error]}
      else
        state
      end

    state
  end

  @doc """
  Increments the restart count.
  """
  @spec increment_restart_count(t()) :: t()
  def increment_restart_count(%__MODULE__{} = state) do
    %{state | restart_count: state.restart_count + 1}
  end

  @doc """
  Sets the health status.
  """
  @spec set_health(t(), :healthy | :unhealthy) :: t()
  def set_health(%__MODULE__{} = state, health_status) when health_status in [:healthy, :unhealthy] do
    %{state |
      health_status: health_status,
      last_health_check: DateTime.utc_now()
    }
  end

  @doc """
  Adds a log subscriber.
  """
  @spec add_log_subscriber(t(), pid()) :: t()
  def add_log_subscriber(%__MODULE__{} = state, pid) do
    %{state | log_subscribers: MapSet.put(state.log_subscribers, pid)}
  end

  @doc """
  Removes a log subscriber.
  """
  @spec remove_log_subscriber(t(), pid()) :: t()
  def remove_log_subscriber(%__MODULE__{} = state, pid) do
    %{state | log_subscribers: MapSet.delete(state.log_subscribers, pid)}
  end

  @doc """
  Adds an event subscriber.
  """
  @spec add_event_subscriber(t(), pid()) :: t()
  def add_event_subscriber(%__MODULE__{} = state, pid) do
    %{state | event_subscribers: MapSet.put(state.event_subscribers, pid)}
  end

  @doc """
  Removes an event subscriber.
  """
  @spec remove_event_subscriber(t(), pid()) :: t()
  def remove_event_subscriber(%__MODULE__{} = state, pid) do
    %{state | event_subscribers: MapSet.delete(state.event_subscribers, pid)}
  end

  @doc """
  Converts state to a map for external representation.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      id: state.definition.id,
      name: state.definition.name,
      description: state.definition.description,
      status: state.status,
      pid: state.pid && :erlang.pid_to_list(state.pid),
      health_status: state.health_status,
      started_at: state.started_at && DateTime.to_iso8601(state.started_at),
      stopped_at: state.stopped_at && DateTime.to_iso8601(state.stopped_at),
      restart_count: state.restart_count,
      last_exit_code: state.last_exit_code,
      last_error: format_error(state.last_error),
      tags: state.definition.tags,
      command: format_command(state.definition.command)
    }
  end

  defp format_error(nil), do: nil
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp format_command({:shell, cmd}) when is_binary(cmd), do: cmd
  defp format_command({:shell, args}) when is_list(args), do: Enum.join(args, " ")
  defp format_command({:module, mod, fun, _args}), do: "#{inspect(mod)}.#{fun}"
end
