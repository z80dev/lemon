defmodule LemonGateway.IngressSupervisor do
  @moduledoc """
  Supervisor for gateway-owned ingress children.

  Default `LemonGateway.Application` startup is execution-only; this supervisor
  starts transport, command, SMS, and voice children only when
  `:gateway_ingress_enabled` is set.

  These surfaces are gateway-owned **by design**, not pending migration. SMS is
  an OTP-code inbox exposed as agent tools with no reply path; webhook is a
  synchronous automation trigger that must answer in the request cycle that
  called it; voice holds a live bidirectional media session. None of the three
  fit `LemonChannels.Plugin`, whose `deliver/1` is fire-and-forget. Email is the
  one surface slated to move to `lemon_channels`.

  See `docs/platform/transport-unification.md` for the disposition of each
  surface and the plugin-contract gaps behind it.
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
