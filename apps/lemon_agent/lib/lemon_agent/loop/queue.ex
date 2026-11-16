defmodule LemonAgent.Loop.Queue do
  @moduledoc false

  alias LemonAgent.Types.AgentLoopConfig

  @spec steering(AgentLoopConfig.t()) :: [term()]
  def steering(%AgentLoopConfig{queue_owner: owner} = config) when is_pid(owner),
    do: request(config, :steering)

  def steering(%AgentLoopConfig{get_steering_messages: nil}), do: []
  def steering(%AgentLoopConfig{get_steering_messages: callback}), do: callback.() || []

  @spec has_steering?(AgentLoopConfig.t()) :: boolean()
  def has_steering?(%AgentLoopConfig{queue_owner: owner} = config) when is_pid(owner),
    do: request(config, :has_steering)

  def has_steering?(%AgentLoopConfig{has_steering_messages: nil}), do: false
  def has_steering?(%AgentLoopConfig{has_steering_messages: callback}), do: callback.() == true

  @spec follow_up(AgentLoopConfig.t()) :: [term()]
  def follow_up(%AgentLoopConfig{queue_owner: owner} = config) when is_pid(owner),
    do: request(config, :follow_up)

  def follow_up(%AgentLoopConfig{get_follow_up_messages: nil}), do: []
  def follow_up(%AgentLoopConfig{get_follow_up_messages: callback}), do: callback.() || []

  defp request(config, kind) do
    owner = config.queue_owner
    request_ref = Process.monitor(owner)

    try do
      send(owner, {:loop_queue, self(), request_ref, config.queue_ref, kind})

      receive do
        {:loop_queue, ^request_ref, messages} ->
          messages

        {:DOWN, ^request_ref, :process, ^owner, reason} ->
          exit({:loop_queue_failed, {:owner_down, reason}})
      after
        config.queue_timeout -> exit({:loop_queue_failed, :timeout})
      end
    after
      Process.demonitor(request_ref, [:flush])
    end
  end
end
