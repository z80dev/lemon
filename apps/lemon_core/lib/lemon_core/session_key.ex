defmodule LemonCore.SessionKey do
  @moduledoc """
  Session key generation and parsing.

  Session keys provide a stable identifier for routing and state management.
  They are compatible with the OpenClaw session key format.

  ## Canonical Formats

  - Main: `agent:<agent_id>:main`
  - Channel: `agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>]`

  ## Notes

  This module also supports parsing a legacy Telegram format:

  - `channel:telegram:<transport>:<chat_id>[:thread:<thread_id>]`
  """

  # Allowed peer_kind values - whitelist to prevent atom exhaustion
  @allowed_peer_kinds %{
    "dm" => :dm,
    "group" => :group,
    "channel" => :channel,
    "main" => :main,
    "unknown" => :unknown
  }

  @type parsed :: %{
          agent_id: binary(),
          kind: :main | :channel_peer,
          channel_id: binary() | nil,
          account_id: binary() | nil,
          peer_kind: atom() | nil,
          peer_id: binary() | nil,
          thread_id: binary() | nil
        }

  @doc "Generate a main session key for an agent."
  @spec main(agent_id :: binary()) :: binary()
  def main(agent_id) when is_binary(agent_id) do
    "agent:#{agent_id}:main"
  end

  @doc """
  Generate a channel peer session key.

  Required keys in opts:
  - `:agent_id`
  - `:channel_id`
  - `:account_id`
  - `:peer_kind` (:dm, :group, :channel, :unknown)
  - `:peer_id`

  Optional:
  - `:thread_id`
  """
  @spec channel_peer(opts :: map()) :: binary()
  def channel_peer(%{
        agent_id: agent_id,
        channel_id: channel_id,
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: peer_id
      } = opts) do
    base = "agent:#{agent_id}:#{channel_id}:#{account_id}:#{peer_kind}:#{peer_id}"

    case opts[:thread_id] do
      nil -> base
      thread_id -> "#{base}:thread:#{thread_id}"
    end
  end

  @doc """
  Parse a session key into its components.

  Returns the parsed components or `{:error, :invalid}` for malformed keys.
  """
  @spec parse(binary()) :: parsed() | {:error, :invalid} | {:error, :invalid_peer_kind}
  def parse(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id, "main"] ->
        %{
          agent_id: agent_id,
          kind: :main,
          channel_id: nil,
          account_id: nil,
          peer_kind: nil,
          peer_id: nil,
          thread_id: nil
        }

      ["agent", agent_id, channel_id, account_id, peer_kind, peer_id] ->
        case safe_peer_kind(peer_kind) do
          {:ok, atom_kind} ->
            %{
              agent_id: agent_id,
              kind: :channel_peer,
              channel_id: channel_id,
              account_id: account_id,
              peer_kind: atom_kind,
              peer_id: peer_id,
              thread_id: nil
            }

          :error ->
            {:error, :invalid_peer_kind}
        end

      ["agent", agent_id, channel_id, account_id, peer_kind, peer_id, "thread", thread_id] ->
        case safe_peer_kind(peer_kind) do
          {:ok, atom_kind} ->
            %{
              agent_id: agent_id,
              kind: :channel_peer,
              channel_id: channel_id,
              account_id: account_id,
              peer_kind: atom_kind,
              peer_id: peer_id,
              thread_id: thread_id
            }

          :error ->
            {:error, :invalid_peer_kind}
        end

      # Legacy format support (Telegram)
      ["channel", "telegram", transport, chat_id | rest] ->
        thread_id =
          case rest do
            ["thread", tid] -> tid
            _ -> nil
          end

        %{
          agent_id: "default",
          kind: :channel_peer,
          channel_id: "telegram",
          account_id: transport,
          peer_kind: :dm,
          peer_id: chat_id,
          thread_id: thread_id
        }

      _ ->
        {:error, :invalid}
    end
  end

  @doc "Check if a session key is valid."
  @spec valid?(binary()) :: boolean()
  def valid?(session_key) do
    case parse(session_key) do
      {:error, _} -> false
      _ -> true
    end
  end

  @doc "Returns the list of allowed peer_kind strings."
  @spec allowed_peer_kinds() :: [String.t()]
  def allowed_peer_kinds, do: Map.keys(@allowed_peer_kinds)

  @doc "Extract the agent ID from a session key."
  @spec agent_id(binary()) :: binary() | nil
  def agent_id(session_key) do
    case parse(session_key) do
      {:error, _} -> nil
      %{agent_id: id} -> id
    end
  end

  @doc "Check if a session key is for the main session."
  @spec main?(binary()) :: boolean()
  def main?(session_key) do
    case parse(session_key) do
      %{kind: :main} -> true
      _ -> false
    end
  end

  @doc "Check if a session key is for a channel peer."
  @spec channel_peer?(binary()) :: boolean()
  def channel_peer?(session_key) do
    case parse(session_key) do
      %{kind: :channel_peer} -> true
      _ -> false
    end
  end

  defp safe_peer_kind(peer_kind) when is_binary(peer_kind) do
    case Map.get(@allowed_peer_kinds, peer_kind) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end
end

