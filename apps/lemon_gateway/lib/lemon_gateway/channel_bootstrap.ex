defmodule LemonGateway.ChannelBootstrap do
  @moduledoc false

  use GenServer

  require Logger

  # Bootstraps lemon_channels after LemonGateway.Config is running.
  # If lemon_channels cannot be started, we fall back to starting the legacy
  # TransportSupervisor (Telegram polling + outbox) so Telegram can still work.

  @retry_ms 100
  @max_attempts 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    send(self(), :bootstrap)
    {:ok, Map.put_new(state, :attempts, 0)}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    case ensure_channels_started() do
      :ok ->
        {:noreply, state}

      {:retry, reason} ->
        attempts = Map.get(state, :attempts, 0) + 1

        if attempts >= @max_attempts do
          Logger.warning(
            "lemon_channels still unavailable after #{attempts} attempts; starting legacy transport supervisor: #{inspect(reason)}"
          )

          _ = start_legacy_transport_supervisor()
          {:noreply, %{state | attempts: attempts}}
        else
          Process.send_after(self(), :bootstrap, @retry_ms)
          {:noreply, %{state | attempts: attempts}}
        end

      {:fallback_to_legacy, reason} ->
        Logger.warning(
          "lemon_channels unavailable; starting legacy transport supervisor: #{inspect(reason)}"
        )

        _ = start_legacy_transport_supervisor()
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_channels_started do
    case Application.ensure_started(:lemon_channels) do
      :ok -> :ok
      {:error, {:already_started, :lemon_channels}} -> :ok
      {:error, {:not_started, _dep} = reason} -> {:retry, reason}
      {:error, reason} -> {:fallback_to_legacy, reason}
    end
  rescue
    e -> {:fallback_to_legacy, e}
  end

  defp start_legacy_transport_supervisor do
    # Start under the existing LemonGateway supervisor so it is supervised.
    # If it is already started, treat it as success.
    case Supervisor.start_child(LemonGateway.Supervisor, {LemonGateway.TransportSupervisor, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, {:already_present, _child}} -> :ok
      other -> other
    end
  rescue
    _ -> :ok
  end
end
