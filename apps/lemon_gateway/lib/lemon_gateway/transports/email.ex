defmodule LemonGateway.Transports.Email do
  @moduledoc false

  use GenServer
  use LemonGateway.Transport

  require Logger

  alias LemonGateway.Transports.Email.{Inbound, Outbound}
  alias LemonGateway.Types.Job

  @impl LemonGateway.Transport
  def id, do: "email"

  @impl LemonGateway.Transport
  def start_link(opts) do
    cond do
      not enabled?() ->
        Logger.info("email transport disabled")
        :ignore

      true ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @impl true
  def init(_opts) do
    cfg = config()

    inbound_pid =
      case Inbound.start_link(config: cfg) do
        {:ok, pid} ->
          pid

        :ignore ->
          nil

        {:error, reason} ->
          Logger.warning("email inbound server failed to start: #{inspect(reason)}")
          nil
      end

    {:ok, %{inbound_pid: inbound_pid}}
  end

  @impl true
  def handle_info({:lemon_gateway_run_completed, %Job{} = job, completed}, state) do
    Task.start(fn ->
      Outbound.deliver(job, completed)
    end)

    {:noreply, state}
  rescue
    error ->
      Logger.warning("email outbound dispatch failed: #{inspect(error)}")
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec enabled?() :: boolean()
  def enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_email) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      cond do
        is_list(cfg) -> Keyword.get(cfg, :enable_email, false)
        is_map(cfg) -> Map.get(cfg, :enable_email, false)
        true -> false
      end
    end
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(:email) || %{}
      else
        Application.get_env(:lemon_gateway, :email, %{})
      end

    cond do
      is_list(cfg) -> Enum.into(cfg, %{})
      is_map(cfg) -> cfg
      true -> %{}
    end
  rescue
    _ -> %{}
  end
end
