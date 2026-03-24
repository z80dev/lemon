defmodule LemonChannels.Adapters.Telegram.ModelPolicyAdapter do
  @moduledoc """
  Adapter that integrates Telegram with the unified ModelPolicy system.

  Provides model and thinking-level resolution for the Telegram transport,
  with session overrides (ephemeral) and persistent policy storage via
  `LemonCore.ModelPolicy`. Falls back to legacy `StateStore` for backward
  compatibility with data written before the ModelPolicy system existed.
  """

  use LemonChannels.Adapters.ModelPolicyShared

  alias LemonChannels.Telegram.StateStore

  @impl true
  def channel_name, do: "telegram"

  @impl true
  def build_route(account_id, chat_id, thread_id) do
    thread_str = if is_integer(thread_id), do: to_string(thread_id), else: nil
    Route.new("telegram", account_id, to_string(chat_id), thread_str)
  end

  @impl true
  def session_get(session_key) do
    case StateStore.get_session_model(session_key) do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @impl true
  def session_put(session_key, model) do
    StateStore.put_session_model(session_key, model)
    :ok
  end

  @impl true
  def format_source_labels, do: %{topic: "topic default", chat: "chat default"}

  # Legacy fallback for pre-ModelPolicy data

  @impl true
  def legacy_model_fallback(account_id, chat_id, thread_id) when is_integer(chat_id) do
    key = {account_id, chat_id, thread_id}

    case StateStore.get_default_model(key) do
      %{model: model} when is_binary(model) and model != "" -> model
      %{"model" => model} when is_binary(model) and model != "" -> model
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def legacy_model_fallback(_account_id, _chat_id, _thread_id), do: nil

  @impl true
  def legacy_thinking_fallback(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    key = {account_id, chat_id, thread_id}

    case StateStore.get_default_thinking(key) do
      %{thinking_level: level} -> normalize_thinking_level(level)
      %{"thinking_level" => level} -> normalize_thinking_level(level)
      level -> normalize_thinking_level(level)
    end
  rescue
    _ -> nil
  end

  def legacy_thinking_fallback(_account_id, _chat_id, _thread_id), do: nil

  @impl true
  def clear_legacy_thinking(legacy_key) do
    StateStore.delete_default_thinking(legacy_key)
  end
end
