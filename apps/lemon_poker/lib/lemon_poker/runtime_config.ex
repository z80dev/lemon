defmodule LemonPoker.RuntimeConfig do
  @moduledoc false

  @doc """
  Applies runtime overrides for poker-only local runs.

  Goals:
  - avoid port collisions with an already-running Lemon runtime
  - prevent Telegram polling transport from starting in this process
  - optionally isolate store writes only when explicitly requested
  """
  @spec apply_for_local_poker!() :: :ok
  def apply_for_local_poker! do
    # Ensure SMS webhook stays disabled even if inherited env had it enabled.
    System.put_env("LEMON_SMS_WEBHOOK_ENABLED", "false")

    # Store override is opt-in (LEMON_POKER_ISOLATE_STORE=true). Default behavior
    # keeps canonical Lemon store access so encrypted provider secrets resolve.
    LemonPoker.Store.install_runtime_override!()

    # Avoid health/control-plane port collisions with another runtime.
    Application.put_env(:lemon_control_plane, :port, 0, persistent: true)
    Application.put_env(:lemon_gateway, :health_port, 0, persistent: true)
    Application.put_env(:lemon_router, :health_port, 0, persistent: true)

    # Force gateway config for poker-mode process: no Telegram, no SMS webhook,
    # and no inherited channel bindings from user config.
    Application.put_env(
      :lemon_gateway,
      LemonGateway.Config,
      %{
        enable_telegram: false,
        bindings: [],
        projects: %{},
        sms: %{
          webhook_enabled: false
        },
        telegram: %{}
      },
      persistent: true
    )

    # Mirror disablement on lemon_channels side because it reads canonical
    # config plus :lemon_channels runtime overrides.
    Application.put_env(
      :lemon_channels,
      :gateway,
      %{
        enable_telegram: false,
        bindings: [],
        telegram: %{}
      },
      persistent: true
    )

    Application.put_env(:lemon_channels, :telegram, %{}, persistent: true)

    :ok
  end

  @doc """
  Asserts that runtime isolation is effective after apps are started.

  Raises if a conflict-prone transport is unexpectedly active.
  """
  @spec assert_isolated_runtime!() :: :ok
  def assert_isolated_runtime! do
    cond do
      LemonGateway.Config.get(:enable_telegram) == true ->
        raise "Poker runtime isolation failed: LemonGateway enable_telegram is true"

      LemonChannels.GatewayConfig.get(:enable_telegram, false) == true ->
        raise "Poker runtime isolation failed: LemonChannels enable_telegram is true"

      is_pid(Process.whereis(LemonChannels.Adapters.Telegram.Transport)) ->
        raise "Poker runtime isolation failed: Telegram transport process is running"

      LemonGateway.Sms.Config.webhook_enabled?() == true ->
        raise "Poker runtime isolation failed: SMS webhook is enabled"

      true ->
        :ok
    end
  end
end
