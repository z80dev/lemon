defmodule LemonRouter.NativeFollowupAdmissionStore do
  @moduledoc false

  alias LemonCore.Store

  # No profile/config/history/management projection reads this owner-only table.
  @table :native_followup_admission_configs

  def fetch(profile_id) do
    locked(profile_id, fn ->
      with :ok <- Store.sync(), do: Store.fetch(@table, profile_id)
    end)
  end

  def put(%{profile_id: profile_id} = config) do
    locked(profile_id, fn ->
      with :ok <- Store.put(@table, profile_id, config),
           :ok <- Store.sync() do
        :ok
      else
        error ->
          # A failed durable write must not leave newly published authority.
          Store.delete(@table, profile_id)
          error
      end
    end)
  end

  defp locked(profile_id, callback) do
    :global.trans({{__MODULE__, profile_id}, self()}, callback, [node()])
  end
end
