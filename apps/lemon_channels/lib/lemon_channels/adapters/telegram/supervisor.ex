defmodule LemonChannels.Adapters.Telegram.Supervisor do
  @moduledoc """
  Supervisor for Telegram adapter processes.

  Starts both the inbound transport (polling) and manages outbound delivery.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Allow running lemon_channels without any Telegram token configured.
    explicit = Keyword.get(opts, :config)
    base = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}
    config = merge_config(base, explicit)

    token = config[:bot_token] || config["bot_token"] || resolve_bot_token_secret(config)

    children =
      if is_binary(token) and token != "" do
        # The child spec must not freeze the gateway config: the transport merges
        # the persisted policy (including the allowlist) fresh on every start, so
        # a supervised restart keeps approvals and revocations made since boot.
        # Only explicit startup overrides and the resolved token are carried over.
        child_config = merge_config(%{}, explicit) |> Map.put(:bot_token, token)

        [
          {Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor},
          # Start the inbound transport (polling)
          {LemonChannels.Adapters.Telegram.Transport, [config: child_config]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp merge_config(base, opts), do: LemonCore.MapHelpers.merge_config(base, opts)

  defp resolve_bot_token_secret(config) do
    secret_name = config[:bot_token_secret] || config["bot_token_secret"]

    if is_binary(secret_name) and secret_name != "" do
      LemonCore.Secrets.fetch_value(secret_name)
    else
      nil
    end
  end
end
