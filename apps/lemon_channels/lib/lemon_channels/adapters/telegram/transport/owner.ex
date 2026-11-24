defmodule LemonChannels.Adapters.Telegram.Transport.Owner do
  @moduledoc """
  The Telegram transport shell process, as seen from its worker tasks.

  Updates and timer events run in a supervised worker task, so timers and Bus
  subscriptions they create must target the long-lived shell, not the task.
  """

  @key :telegram_transport

  @doc "Mark the calling worker task as acting for `owner`."
  @spec put(pid()) :: :ok
  def put(owner) when is_pid(owner) do
    Process.put(@key, owner)
    :ok
  end

  @doc "The shell pid (the caller itself when it is the shell)."
  @spec pid() :: pid()
  def pid, do: Process.get(@key, self())

  @doc "Subscribe or unsubscribe the shell to a Bus topic."
  @spec bus(:subscribe | :unsubscribe, String.t()) :: :ok
  def bus(action, topic) when action in [:subscribe, :unsubscribe] do
    case Process.get(@key) do
      nil -> apply(LemonCore.Bus, action, [topic])
      owner -> send(owner, {:telegram_bus, action, topic})
    end

    :ok
  end
end
