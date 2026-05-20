defmodule LemonControlPlane.UsageStore do
  @moduledoc """
  Typed wrapper for control-plane usage records and summaries.
  """

  @spec get_record(binary()) :: map() | nil
  defdelegate get_record(date_key), to: LemonCore.UsageStore

  @spec put_record(binary(), map()) :: :ok
  defdelegate put_record(date_key, record), to: LemonCore.UsageStore

  @spec get_summary(term()) :: map() | nil
  defdelegate get_summary(key), to: LemonCore.UsageStore

  @spec put_summary(term(), map()) :: :ok
  defdelegate put_summary(key, summary), to: LemonCore.UsageStore

  @spec get_stats(term()) :: map() | nil
  defdelegate get_stats(key), to: LemonCore.UsageStore
end
