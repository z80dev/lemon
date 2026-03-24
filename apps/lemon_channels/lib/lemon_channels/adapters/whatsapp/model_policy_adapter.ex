defmodule LemonChannels.Adapters.WhatsApp.ModelPolicyAdapter do
  @moduledoc """
  Adapter that integrates WhatsApp with the unified ModelPolicy system.

  Provides model and thinking-level resolution for the WhatsApp transport.
  Uses session overrides (ephemeral, stored in ETS) and persistent policy
  storage via `LemonCore.ModelPolicy`. No legacy fallback needed — WhatsApp
  is a new channel with no pre-ModelPolicy data to migrate.
  """

  use LemonChannels.Adapters.ModelPolicyShared

  @session_table :whatsapp_session_models

  @impl true
  def channel_name, do: "whatsapp"

  @impl true
  def build_route(account_id, chat_id, thread_id) do
    thread_str = if is_binary(thread_id) and thread_id != "", do: thread_id, else: nil
    Route.new("whatsapp", account_id, chat_id, thread_str)
  end

  @impl true
  def session_get(session_key) do
    ensure_session_table()

    case :ets.lookup(@session_table, {:model, session_key}) do
      [{_, model}] when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @impl true
  def session_put(session_key, model) do
    ensure_session_table()
    :ets.insert(@session_table, {{:model, session_key}, model})
    :ok
  end

  @impl true
  def format_source_labels, do: %{topic: "topic default", chat: "chat default"}

  # WhatsApp-specific: ETS session table management

  def ensure_session_table do
    if :ets.whereis(@session_table) == :undefined do
      :ets.new(@session_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  rescue
    _ -> :ok
  end
end
