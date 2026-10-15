defmodule LemonSkills.CuratorReferences do
  @moduledoc """
  Runtime seam for cron skill references, registered by automation at boot.

  Like the platform contributor registries, registration uses `:persistent_term`
  without introducing a reverse application dependency. The owner's liveness is
  checked on every lookup so a stopped automation app cannot authorize archival.
  Providers must return all references, including disabled jobs, or an error.
  """

  @callback referenced_skills([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  @key {__MODULE__, :provider}

  def register(module, owner) when is_atom(module) and is_pid(owner) do
    :persistent_term.put(@key, {module, owner})
    :ok
  end

  def unregister do
    :persistent_term.erase(@key)
    :ok
  end

  def lookup(names) do
    case :persistent_term.get(@key, nil) do
      {module, owner} ->
        if Process.alive?(owner) do
          case module.referenced_skills(names) do
            {:ok, skills} when is_list(skills) ->
              if Enum.all?(skills, &is_binary/1),
                do: {:ok, skills},
                else: {:error, :cron_references_unavailable}

            _ ->
              {:error, :cron_references_unavailable}
          end
        else
          {:error, :cron_references_unavailable}
        end

      nil ->
        {:error, :cron_references_unavailable}
    end
  rescue
    _ -> {:error, :cron_references_unavailable}
  catch
    _, _ -> {:error, :cron_references_unavailable}
  end
end
