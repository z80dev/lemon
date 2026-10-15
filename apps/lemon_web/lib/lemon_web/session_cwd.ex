defmodule LemonWeb.SessionCwd do
  @moduledoc """
  Resolves the workspace directory of an existing session.

  Native-session RPCs (`chat.history` with `cwd`, `sessions.fork`,
  `sessions.plan`, `sessions.context`, `sessions.compact`) need the session's
  workspace. A coding-agent session records it in its `:session_started`
  introspection event; a session that never ran resolves to the runtime's
  default workspace for operator-initiated runs (`LemonCore.Cwd.default_cwd/0`),
  which is also what `chat.send` uses when no `cwd` is given.

  Sessions the web workspace starts or forks also have their workspace
  remembered (`remember/2`, a small `LemonCore.Store` table) so a pane opened
  before the first run — or a fork that has not run yet — still finds it.

  The value is an operator workspace path: show it only on operator chat
  surfaces, never in logs or management projections.
  """

  alias LemonCore.Introspection

  @doc "The workspace recorded by the session's latest start, if any."
  @spec recorded(String.t()) :: {:ok, String.t()} | :error | {:error, :unavailable}
  def recorded(session_key) when is_binary(session_key) and session_key != "" do
    case Introspection.list(session_key: session_key, event_type: :session_started, limit: 1) do
      [event | _] ->
        case event |> field(:payload) |> field(:cwd) do
          cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
          _ -> :error
        end

      {:error, _} ->
        {:error, :unavailable}

      [] ->
        remembered(session_key)
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def recorded(_session_key), do: :error

  @table :web_session_cwds

  @doc "Remembers the workspace a web-started or forked session runs in."
  @spec remember(String.t(), String.t() | nil) :: :ok
  def remember(session_key, cwd) when is_binary(session_key) and is_binary(cwd) and cwd != "" do
    _ = LemonCore.Store.put(@table, session_key, cwd)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def remember(_session_key, _cwd), do: :ok

  defp remembered(session_key) do
    case LemonCore.Store.get(@table, session_key) do
      cwd when is_binary(cwd) and cwd != "" -> {:ok, cwd}
      _ -> :error
    end
  end

  @doc "The recorded workspace, else the default workspace for operator runs."
  @spec resolve(String.t()) :: String.t() | {:error, :unavailable}
  def resolve(session_key) do
    case recorded(session_key) do
      {:ok, cwd} -> cwd
      :error -> default()
      {:error, :unavailable} = error -> error
    end
  end

  @doc "Default workspace for operator-initiated runs."
  @spec default() :: String.t()
  def default do
    LemonCore.Cwd.default_cwd()
  rescue
    _ -> File.cwd!()
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
