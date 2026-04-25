defmodule LemonGateway.LegacyIngressSupervisor do
  @moduledoc """
  Transitional supervisor for gateway-native ingress children.

  Default `LemonGateway.Application` startup is execution-only. This supervisor
  preserves legacy transport, command, SMS, and voice startup when explicitly
  enabled through `:legacy_ingress_enabled`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        LemonGateway.TransportRegistry,
        LemonGateway.TransportSupervisor,
        LemonGateway.CommandRegistry,
        LemonGateway.Sms.Inbox,
        LemonGateway.Sms.WebhookServer,
        {Registry, keys: :unique, name: LemonGateway.Voice.CallRegistry},
        {Registry, keys: :unique, name: LemonGateway.Voice.DeepgramRegistry},
        {DynamicSupervisor,
         name: LemonGateway.Voice.CallSessionSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: LemonGateway.Voice.DeepgramSupervisor, strategy: :one_for_one}
      ] ++ maybe_voice_server_child()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp maybe_voice_server_child do
    if LemonGateway.Voice.Config.enabled?() do
      [voice_server_child_spec()]
    else
      []
    end
  end

  defp voice_server_child_spec do
    port = LemonGateway.Voice.Config.websocket_port() |> maybe_test_voice_port()

    %{
      id: LemonGateway.Voice.Server,
      start:
        {Bandit, :start_link,
         [[plug: LemonGateway.Voice.WebhookRouter, port: port, scheme: :http]]},
      type: :supervisor
    }
  end

  defp maybe_test_voice_port(4047) do
    if test_env?(), do: 0, else: 4047
  end

  defp maybe_test_voice_port(port), do: port

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  end
end
