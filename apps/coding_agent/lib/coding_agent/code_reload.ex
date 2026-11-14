defmodule CodingAgent.CodeReload do
  @moduledoc """
  Rebuilds idle sessions' tool closures after a development code reload.
  Wired as `LemonCore.CodeReload`'s session refresher in the runtime config.
  """

  @type counts :: %{
          refreshed: non_neg_integer(),
          busy: non_neg_integer(),
          failed: non_neg_integer()
        }

  @doc "Refresh every registered session, or only `session_ids`."
  @spec refresh_sessions([String.t()]) :: counts()
  def refresh_sessions(session_ids \\ CodingAgent.SessionRegistry.list_ids()) do
    Enum.reduce(session_ids, %{refreshed: 0, busy: 0, failed: 0}, fn id, counts ->
      Map.update!(counts, refresh_session(id), &(&1 + 1))
    end)
  end

  defp refresh_session(id) do
    case CodingAgent.SessionRegistry.lookup(id) do
      {:ok, pid} ->
        case CodingAgent.Session.reload_extensions(pid) do
          {:ok, _report} -> :refreshed
          {:error, :already_streaming} -> :busy
          _ -> :failed
        end

      :error ->
        :failed
    end
  rescue
    _ -> :failed
  catch
    :exit, _ -> :failed
  end
end
