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

  Components are never escaped or decoded. A component that contains `:` (or
  already looks like a hashed component) is replaced by `component/1`'s
  colon-free digest, so the key always parses and two distinct inputs never
  share a key; every other component, and so every existing key, is written
  byte-for-byte. A peer kind outside `allowed_peer_kinds/0` is written as
  `unknown`. Callers that need the original value (for delivery or reply
  threading) must keep it alongside the key rather than read it back.
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
    base =
      Enum.map_join(
        [agent_id, channel_id, account_id, key_peer_kind(peer_kind), peer_id],
        ":",
        &component/1
      )

    base = "agent:" <> base

    base =
      case opts[:thread_id] do
        nil -> base
        thread_id -> base <> ":thread:" <> component(thread_id)
      end

    case opts[:sub_id] do
      nil -> base
      sub_id -> base <> ":sub:" <> component(sub_id)
    end
  end

  @hashed_prefix "~sha256-"

  @doc """
  The session-key form of one routing component.

  Colon-free values are returned unchanged. A value containing `:`, or one that
  already starts with the reserved `~sha256-` prefix, becomes
  `"~sha256-" <> hex(sha256(value))`; the prefix makes hashed and verbatim
  components disjoint, so the mapping is injective up to SHA-256 collisions.

  Compatibility edge: the `~sha256-` prefix is reserved. A key written before
  this scheme whose component literally started with it keeps parsing and is
  never rewritten by `rebuild/1` or `put_sub/2`, but generating a key from that
  same raw value now yields its digest, so such a pre-existing conversation is
  not reached again from fresh ingress. Only a literal of the exact digest
  shape (`~sha256-` and 64 lowercase hex digits) is treated as opaque.

  The digest is one-way: callers that need the original value (delivery,
  reply threading) must keep it beside the key, and code that modifies an
  existing key must use `rebuild/1` or `put_sub/2`, never feed parsed
  components back through `channel_peer/1`.
  """
  @spec component(term()) :: binary()
  def component(value) do
    value = to_string(value)

    if String.contains?(value, ":") or String.starts_with?(value, @hashed_prefix) do
      @hashed_prefix <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
    else
      value
    end
  end

  @doc "Whether a parsed key component is exactly a `component/1` digest."
  @spec hashed_component?(term()) :: boolean()
  def hashed_component?(value) when is_binary(value),
    do: Regex.match?(~r/\A~sha256-[0-9a-f]{64}\z/, value)

  def hashed_component?(_value), do: false

  @doc """
  Whether a parsed channel-peer key has a routing component (account, peer or
  thread id) stored as a digest. Such a key is not a delivery address on its own.
  """
  @spec opaque_routing?(map()) :: boolean()
  def opaque_routing?(%{kind: :channel_peer} = parsed) do
    Enum.any?(
      [parsed.channel_id, parsed.account_id, parsed.peer_id, parsed.thread_id],
      &hashed_component?/1
    )
  end

  def opaque_routing?(_parsed), do: false

  @doc """
  Serialize a parsed channel-peer key from its already-serialized components,
  verbatim. `rebuild(parse(key)) == key` for every canonical channel-peer key
  whose extras are in `thread`, `sub` order; use this (with an updated
  `:sub_id` of `nil` to drop the sub-session) to derive a related key.
  """
  @spec rebuild(map()) :: binary()
  def rebuild(%{kind: :channel_peer} = parsed) do
    base =
      Enum.join(
        [
          "agent",
          parsed.agent_id,
          parsed.channel_id,
          parsed.account_id,
          to_string(parsed.peer_kind),
          parsed.peer_id
        ],
        ":"
      )

    base = if parsed.thread_id, do: base <> ":thread:" <> parsed.thread_id, else: base
    if parsed.sub_id, do: base <> ":sub:" <> parsed.sub_id, else: base
  end

  @doc """
  Set (or replace) the sub-session of a canonical channel-peer key.

  The key's existing components are kept byte-for-byte (never re-derived from
  parsed values) and only the new sub id goes through `component/1`. Returns
  `{:error, :invalid}` for a key that is not a canonical channel-peer key.
  """
  @spec put_sub(binary(), term()) :: {:ok, binary()} | {:error, :invalid}
  def put_sub(session_key, sub_id) when is_binary(session_key) and not is_nil(sub_id) do
    case parse(session_key) do
      %{kind: :channel_peer, sub_id: nil} ->
        {:ok, session_key <> ":sub:" <> component(sub_id)}

      %{kind: :channel_peer, sub_id: old} ->
        suffix = ":sub:" <> old

        if String.ends_with?(session_key, suffix) do
          base = binary_part(session_key, 0, byte_size(session_key) - byte_size(suffix))
          {:ok, base <> ":sub:" <> component(sub_id)}
        else
          {:error, :invalid}
        end

      _ ->
        {:error, :invalid}
    end
  end

  def put_sub(_session_key, _sub_id), do: {:error, :invalid}

  defp key_peer_kind(kind) do
    kind = to_string(kind)
    if Map.has_key?(@allowed_peer_kinds, kind), do: kind, else: "unknown"
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
