defmodule LemonChannels.Telegram.StateStore do
  @moduledoc """
  Typed wrapper for Telegram per-chat/session preference state.
  """

  alias LemonCore.Store

  @session_model_table :telegram_session_model
  @default_model_table :telegram_default_model
  @default_thinking_table :telegram_default_thinking
  @selected_resume_table :telegram_selected_resume
  @thread_generation_table :telegram_thread_generation

  @spec get_session_model(term()) :: term()
  def get_session_model(key), do: Store.get(@session_model_table, key)

  @spec put_session_model(term(), term()) :: :ok
  def put_session_model(key, value), do: Store.put(@session_model_table, key, value)

  @spec delete_session_model(term()) :: :ok
  def delete_session_model(key), do: Store.delete(@session_model_table, key)

  @spec get_default_model(term()) :: term()
  def get_default_model(key), do: Store.get(@default_model_table, key)

  @spec put_default_model(term(), term()) :: :ok
  def put_default_model(key, value), do: Store.put(@default_model_table, key, value)

  @spec delete_default_model(term()) :: :ok
  def delete_default_model(key), do: Store.delete(@default_model_table, key)

  @spec get_default_thinking(term()) :: term()
  def get_default_thinking(key), do: Store.get(@default_thinking_table, key)

  @spec put_default_thinking(term(), term()) :: :ok
  def put_default_thinking(key, value), do: Store.put(@default_thinking_table, key, value)

  @spec delete_default_thinking(term()) :: :ok
  def delete_default_thinking(key), do: Store.delete(@default_thinking_table, key)

  @spec get_selected_resume(term()) :: term()
  def get_selected_resume(key), do: Store.get(@selected_resume_table, key)

  @spec put_selected_resume(term(), term()) :: :ok
  def put_selected_resume(key, value), do: Store.put(@selected_resume_table, key, value)

  @spec delete_selected_resume(term()) :: :ok
  def delete_selected_resume(key), do: Store.delete(@selected_resume_table, key)

  @spec get_thread_generation(term()) :: term()
  def get_thread_generation(key), do: Store.get(@thread_generation_table, key)

  @spec put_thread_generation(term(), term()) :: :ok
  def put_thread_generation(key, value), do: Store.put(@thread_generation_table, key, value)

  @spec delete_thread_generation(term()) :: :ok
  def delete_thread_generation(key), do: Store.delete(@thread_generation_table, key)
end
