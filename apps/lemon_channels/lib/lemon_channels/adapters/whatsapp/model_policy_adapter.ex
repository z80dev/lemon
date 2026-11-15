defmodule LemonChannels.Adapters.WhatsApp.ModelPolicyAdapter do
  @moduledoc """
  Adapter that integrates WhatsApp with the unified ModelPolicy system.

  Provides model and thinking-level resolution for the WhatsApp transport.
  Uses session overrides (ephemeral, stored in ETS) and persistent policy
  storage via `LemonChannels.ModelPolicy`. No legacy fallback needed — WhatsApp
  is a new channel with no pre-ModelPolicy data to migrate.

  This application's supervised child owns the ETS table. Reads and writes do
  not call the owner, and short-lived command callers cannot destroy overrides.
  Overrides are volatile and reset when the owner or application restarts.
  """

  use GenServer

  use LemonChannels.Adapters.ModelPolicyShared

  @session_table :whatsapp_session_models

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@session_table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @impl true
  def channel_name, do: "whatsapp"

  @impl true
  def build_route(account_id, chat_id, thread_id) do
    thread_str = if is_binary(thread_id) and thread_id != "", do: thread_id, else: nil
    Route.new("whatsapp", account_id, chat_id, thread_str)
  end

  @impl true
  def session_get(session_key) do
    case :ets.lookup(@session_table, {:model, session_key}) do
      [{_, model}] when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @impl true
  def session_put(session_key, model) do
    :ets.insert(@session_table, {{:model, session_key}, model})
    :ok
  end

  @impl true
  def format_source_labels, do: %{topic: "topic default", chat: "chat default"}
end
