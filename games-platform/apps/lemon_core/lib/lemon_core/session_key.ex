defmodule LemonCore.SessionKey do
  @moduledoc """
  Session key generation and parsing.

  Session keys provide a stable identifier for routing and state management.

  ## Canonical Formats

  - Main: `agent:<agent_id>:main[:sub:<sub_id>]`
  - Channel: `agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>][:sub:<sub_id>]`

  ## Notes

  Session keys are strictly validated against the canonical formats above.
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
          thread_id: binary() | nil,
          sub_id: binary() | nil
        }

  @doc """
  Generate a main session key for an agent.

  ## Examples

      iex> LemonCore.SessionKey.main("my_agent")
      "agent:my_agent:main"

  """
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
  - `:sub_id`
  """
  @spec channel_peer(opts :: map()) :: binary()
  def channel_peer(
        %{
          agent_id: agent_id,
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: peer_kind,
          peer_id: peer_id
        } = opts
      ) do
    base = "agent:#{agent_id}:#{channel_id}:#{account_id}:#{peer_kind}:#{peer_id}"

    base =
      case opts[:thread_id] do
        nil -> base
        thread_id -> "#{base}:thread:#{thread_id}"
      end

    case opts[:sub_id] do
      nil -> base
      sub_id -> "#{base}:sub:#{sub_id}"
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
          thread_id: nil,
          sub_id: nil
        }

      ["agent", agent_id, "main", "sub", sub_id] ->
        %{
          agent_id: agent_id,
          kind: :main,
          channel_id: nil,
          account_id: nil,
          peer_kind: nil,
          peer_id: nil,
          thread_id: nil,
          sub_id: sub_id
        }

      ["agent", agent_id, channel_id, account_id, peer_kind, peer_id | rest] ->
        case safe_peer_kind(peer_kind) do
          {:ok, atom_kind} ->
            case parse_extras(rest) do
              {:ok, extras} ->
                %{
                  agent_id: agent_id,
                  kind: :channel_peer,
                  channel_id: channel_id,
                  account_id: account_id,
                  peer_kind: atom_kind,
                  peer_id: peer_id,
                  thread_id: Map.get(extras, "thread"),
                  sub_id: Map.get(extras, "sub")
                }

              {:error, :invalid} ->
                {:error, :invalid}
            end

          :error ->
            {:error, :invalid_peer_kind}
        end

      _ ->
        {:error, :invalid}
    end
  end

  @doc """
  Check if a session key is valid.

  ## Examples

      iex> LemonCore.SessionKey.valid?("agent:test:main")
      true

      iex> LemonCore.SessionKey.valid?("invalid")
      false

  """
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

  @doc """
  Extract the agent ID from a session key.

  ## Examples

      iex> LemonCore.SessionKey.agent_id("agent:my_bot:main")
      "my_bot"

      iex> LemonCore.SessionKey.agent_id("invalid")
      nil

  """
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

  # Parse key/value extras after the peer_id.
  #
  # Current supported keys:
  # - thread:<thread_id>
  # - sub:<sub_id>
  defp parse_extras([]), do: {:ok, %{}}
  defp parse_extras(nil), do: {:ok, %{}}

  defp parse_extras(rest) when is_list(rest) do
    if rem(length(rest), 2) != 0 do
      {:error, :invalid}
    else
      rest
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, %{}}, fn
        [k, v], {:ok, acc} when is_binary(k) and is_binary(v) and k in ["thread", "sub"] ->
          if Map.has_key?(acc, k) do
            {:halt, {:error, :invalid}}
          else
            {:cont, {:ok, Map.put(acc, k, v)}}
          end

        _other, _acc ->
          {:halt, {:error, :invalid}}
      end)
    end
  end

  defp parse_extras(_), do: {:error, :invalid}
end
