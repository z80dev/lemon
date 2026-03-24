defmodule LemonChannels.Adapters.Discord.ModelPolicyAdapter do
  @moduledoc """
  Adapter that integrates Discord with the unified ModelPolicy system.

  Provides model and thinking-level resolution for the Discord transport,
  with session overrides (ephemeral) and persistent policy storage via
  `LemonCore.ModelPolicy`.
  """

  use LemonChannels.Adapters.ModelPolicyShared

  alias LemonCore.Store

  @session_model_table :discord_session_model

  @impl true
  def channel_name, do: "discord"

  @impl true
  def build_route(account_id, channel_id, thread_id) do
    thread_str = if is_integer(thread_id), do: to_string(thread_id), else: nil
    Route.new("discord", account_id, to_string(channel_id), thread_str)
  end

  @impl true
  def session_get(session_key) do
    case Store.get(@session_model_table, session_key) do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @impl true
  def session_put(session_key, model) do
    Store.put(@session_model_table, session_key, model)
    :ok
  end

  @impl true
  def format_source_labels, do: %{topic: "thread default", chat: "channel default"}

  # Discord-specific: delete session model override

  @spec delete_session_model_override(term()) :: :ok
  def delete_session_model_override(session_key) when is_binary(session_key) do
    Store.delete(@session_model_table, session_key)
    :ok
  rescue
    _ -> :ok
  end

  def delete_session_model_override(_session_key), do: :ok
end
