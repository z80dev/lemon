defmodule LemonHoncho.Owner do
  @moduledoc """
  Whose memory a Honcho record is, and the Honcho identities that hold it.

  An owner is three things at once:

    * the Lemon **agent** (profile), from the session key's `agent:<id>:` segment;
    * the resolved **human** (`LemonHoncho.UserPeer.resolve/2`: pin, alias,
      operator, platform-qualified sender, unverified sender);
    * the **memory ownership** — `"legacy"`, or `"private:<context key>"` for a
      verified private memory context (`LemonMemory.ContextScope`).

  Every Honcho identity is derived from the complete owner, never from a part
  of it:

    * `user_peer` (`v2-u-…`) — the human as this agent knows them in this memory;
    * `ai_peer` (`v2-a-…`) — the assistant as it is known to this owner. The
      assistant's self-representation is built from its replies, so a shared
      assistant peer would carry one person's memory into everyone's prompt;
    * the message tag (`metadata/1`) every upload carries and every search
      requires.

  Representations, peer cards, the dialectic, and conclusions all hang off
  these peers in Honcho, so two profiles, two people, or a private context and
  legacy memory never share any of them.

  ## The `v2` namespace

  Peer ids, session ids and message tags are all versioned. Records written
  before owner partitioning (bare `user_peer`/`ai_peer` peers, untagged
  messages, sessions named after a directory) have no provable owner, so
  nothing in this namespace ever reads them: the upgrade starts every owner
  with empty Honcho memory instead of inheriting possibly-mixed history.

  ## Proof

  Memory ownership comes only from proof: on a live request, the admitted atom
  fields `ContextScope.scope/1` accepts; on an uploaded document, the owning
  writer's persisted stamps. A partial or unproven claim, a shared or unproven
  stamp, and a channel conversation that does not name its sender (a subagent
  of a channel run, for one) have no owner at all (`:error`): nothing is
  uploaded, served or searched for them.
  """

  alias LemonHoncho.{Config, UserPeer}
  alias LemonMemory.ContextScope

  @enforce_keys [:agent_id, :human, :memory, :digest, :user_peer, :ai_peer]
  defstruct @enforce_keys

  @type memory :: String.t()
  @type t :: %__MODULE__{
          agent_id: String.t(),
          human: String.t(),
          memory: memory(),
          digest: String.t(),
          user_peer: String.t(),
          ai_peer: String.t()
        }

  @namespace "v2"
  @tag_key "lemon_owner_v2"
  @label_max 48

  @doc """
  The owner of a run keyed by `session_key`, whose transport identity (already
  filtered by `LemonHoncho.UserPeer.identity/2`) is `identity`, in `memory`.
  """
  @spec new(Config.t(), String.t() | nil, map() | nil, memory()) :: t()
  def new(%Config{} = config, session_key, identity, memory) when is_binary(memory) do
    agent_id = agent_id(session_key)
    human = UserPeer.resolve(config, identity)
    digest = digest(["lemon-honcho-owner", @namespace, agent_id, human, memory])

    %__MODULE__{
      agent_id: agent_id,
      human: human,
      memory: memory,
      digest: digest,
      user_peer: peer_id("u", human, digest),
      ai_peer: peer_id("a", config.ai_peer, digest)
    }
  end

  @doc """
  The owner a live request or tool option set proves: `:session_key`,
  `:channel_identity`, `:session_scope` and the `ContextScope` admission fields.
  """
  @spec from_context(Config.t(), map() | keyword()) :: {:ok, t()} | :error
  def from_context(config, context) when is_list(context),
    do: from_context(config, Map.new(context))

  def from_context(%Config{} = config, context) when is_map(context) do
    session_key = Map.get(context, :session_key)

    claimed =
      if Map.get(context, :session_scope) == :subagent,
        do: nil,
        else: Map.get(context, :channel_identity)

    with true <- identified?(session_key, claimed),
         {:ok, memory} <- memory(context) do
      {:ok, new(config, session_key, UserPeer.identity(session_key, claimed), memory)}
    else
      _unproven -> :error
    end
  end

  def from_context(_config, _context), do: :error

  @doc """
  The owner a finished run's document records: its session key, the transport
  identity in its metadata and the owning writer's persisted ownership stamps.
  """
  @spec from_document(Config.t(), LemonMemory.Document.t()) :: {:ok, t()} | :error
  def from_document(%Config{} = config, %LemonMemory.Document{} = document) do
    meta = document.meta || %{}
    claimed = LemonCore.MapHelpers.get_key(meta, :channel_identity)

    with true <- identified?(document.session_key, claimed),
         {:ok, memory} <- document_memory(meta) do
      identity = UserPeer.identity(document.session_key, claimed)
      {:ok, new(config, document.session_key, identity, memory)}
    else
      _unproven -> :error
    end
  end

  @doc "The agent segment of a session key, or `\"\"`."
  @spec agent_id(term()) :: String.t()
  def agent_id(session_key) when is_binary(session_key) do
    LemonCore.SessionKey.agent_id(session_key) || ""
  end

  def agent_id(_session_key), do: ""

  @doc """
  Whether a run keyed by `session_key` names its human: always for a local or
  unrecognised key, and for a channel conversation only with a channel identity.
  Without the sender the only peer left is the operator's, and a stranger's
  run must never read or write that.
  """
  @spec identified?(term(), term()) :: boolean()
  def identified?(session_key, identity) when is_binary(session_key) do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :channel_peer} -> is_map(identity)
      _other -> true
    end
  end

  def identified?(_session_key, _identity), do: true

  @doc "The metadata every message uploaded for this owner carries."
  @spec metadata(t()) :: %{String.t() => String.t()}
  def metadata(%__MODULE__{digest: digest}), do: %{@tag_key => digest}

  @doc "The server-side search filter for this owner's messages."
  @spec filters(t()) :: map()
  def filters(%__MODULE__{} = owner), do: %{"metadata" => metadata(owner)}

  @doc "Whether a search hit carries exactly this owner's tag."
  @spec owns?(t(), term()) :: boolean()
  def owns?(%__MODULE__{digest: digest}, hit) when is_map(hit) do
    case Map.get(hit, "metadata") || Map.get(hit, :metadata) do
      %{} = metadata -> Map.get(metadata, @tag_key) == digest
      _missing -> false
    end
  end

  def owns?(%__MODULE__{}, _hit), do: false

  @doc """
  Length-prefixed SHA-256 (128-bit hex) of `parts`: no two different part lists
  share an encoding, so a value in one position can never pose as another.
  """
  @spec digest([String.t()]) :: String.t()
  def digest(parts) when is_list(parts) do
    encoded = Enum.map(parts, &[Integer.to_string(byte_size(&1)), ":", &1])

    :sha256
    |> :crypto.hash(encoded)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp memory(context) do
    case ContextScope.scope(context) do
      {:ok, {:private, key}} -> {:ok, "private:" <> key}
      {:ok, :legacy} -> {:ok, "legacy"}
      {:error, _unproven} -> :error
    end
  end

  defp document_memory(meta) when is_map(meta) do
    key = Map.get(meta, "memory_context_key")

    cond do
      ContextScope.matches?(meta, {:private, key}) -> {:ok, "private:" <> key}
      ContextScope.matches?(meta, :shared) -> :error
      ContextScope.matches?(meta, :legacy) -> {:ok, "legacy"}
      true -> :error
    end
  end

  defp document_memory(_meta), do: :error

  # `v2-<role>-<readable label>-<owner digest>`: the label is for a human
  # reading Honcho's dashboard; identity is the digest. Within Honcho's
  # `[A-Za-z0-9_-]{1,512}` peer id rule by construction.
  defp peer_id(role, label, digest) do
    label =
      label
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
      |> String.trim("_")
      |> String.slice(0, @label_max)

    label = if label == "", do: "peer", else: label
    Enum.join([@namespace, role, label, digest], "-")
  end
end
