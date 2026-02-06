defmodule LemonGateway.ChannelBootstrap do
  @moduledoc false

  use GenServer

  require Logger

  # Bootstraps lemon_channels after LemonGateway.Config is running.
  # If lemon_channels cannot be started, we fall back to starting the legacy
  # TransportSupervisor (Telegram polling + outbox) so Telegram can still work.

  @retry_ms 100
  @retry_after_legacy_ms 1_000
  # If dependencies are still coming up (common in dev), avoid flipping on the legacy
  # Telegram poller too early. If we do start legacy, keep retrying and shut it down
  # once lemon_channels is available to prevent duplicate Telegram replies.
  @legacy_after_attempts 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    send(self(), :bootstrap)

    state =
      state
      |> Map.put_new(:attempts, 0)
      |> Map.put_new(:legacy_started?, false)

    {:ok, state}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    case ensure_channels_started() do
      :ok ->
        if state.legacy_started? do
          _ = stop_legacy_transport_supervisor()
        end

        {:noreply, state}

      {:retry, reason} ->
        attempts = state.attempts + 1

        state =
          if attempts >= @legacy_after_attempts and not state.legacy_started? do
            Logger.warning(
              "lemon_channels still unavailable after #{attempts} attempts; starting legacy transport supervisor: #{inspect(reason)}"
            )

            _ = start_legacy_transport_supervisor()
            %{state | legacy_started?: true}
          else
            state
          end

        delay = if state.legacy_started?, do: @retry_after_legacy_ms, else: @retry_ms
        Process.send_after(self(), :bootstrap, delay)
        {:noreply, %{state | attempts: attempts}}

      {:fallback_to_legacy, reason} ->
        if not state.legacy_started? do
          Logger.warning(
            "lemon_channels unavailable; starting legacy transport supervisor: #{inspect(reason)}"
          )

          _ = start_legacy_transport_supervisor()
        end

        # Even if we have to fall back, keep retrying: transient startup ordering issues
        # should converge to lemon_channels and then we can shut legacy down.
        Process.send_after(self(), :bootstrap, @retry_after_legacy_ms)
        {:noreply, %{state | legacy_started?: true, attempts: state.attempts + 1}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_channels_started do
    # Use ensure_all_started so we don't depend on external callers starting deps (notably :lemon_router).
    # This avoids the "start legacy after 10s, then later also start lemon_channels" duplicate poller scenario.
    case Application.ensure_all_started(:lemon_channels) do
      {:ok, _apps} -> :ok
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

  defp stop_legacy_transport_supervisor do
    # If legacy is running as a child under LemonGateway.Supervisor, shut it down so
    # we don't have two Telegram pollers producing "replayed" replies.
    _ = Supervisor.terminate_child(LemonGateway.Supervisor, LemonGateway.TransportSupervisor)
    _ = Supervisor.delete_child(LemonGateway.Supervisor, LemonGateway.TransportSupervisor)
    :ok
  rescue
    _ -> :ok
  end
end
