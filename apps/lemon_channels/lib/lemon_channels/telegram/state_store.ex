defmodule LemonChannels.Telegram.StateStore do
  @moduledoc """
  Typed wrapper for Telegram per-chat resume selection and thread generation
  state. Model and thinking preferences live in `LemonCore.PolicyStore`.
  """

  alias LemonCore.Store

  @selected_resume_table :telegram_selected_resume
  @thread_generation_table :telegram_thread_generation

  @spec get_selected_resume(term()) :: term()
  def get_selected_resume(key), do: Store.get(@selected_resume_table, key)

  @doc "Strict read for admission: an unreadable selection is an error, never none."
  @spec fetch_selected_resume(term()) :: {:ok, term()} | {:error, :store_unavailable}
  def fetch_selected_resume(key), do: Store.fetch(@selected_resume_table, key)

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
