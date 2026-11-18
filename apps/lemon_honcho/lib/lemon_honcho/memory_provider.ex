defmodule LemonHoncho.MemoryProvider do
  @moduledoc """
  Honcho as a searchable `LemonMemory.Provider`.

  `LemonMemory` fans a memory search out to every registered provider and merges
  what comes back. This module is the entry Honcho occupies in that fan-out: it
  turns a Lemon memory query into a Honcho search and turns Honcho's messages
  back into `LemonMemory.Document` structs, so past conversations stored in a
  remote service become searchable next to the local SQLite index without
  anything in the platform knowing Honcho exists.

  ## The one property that matters most: `search/2` returns a list, or nothing

  Every failure this module can have — Honcho not configured, no endpoint to
  talk to, a timeout, a 401, a 500, a response that is not a list, a message
  that is not a map, a date that will not parse, a query withheld by the egress
  screen, an exception raised anywhere in the mapping — comes back as `[]`. It never returns `{:ok, documents}`, never
  returns `nil`, and never raises. That is what `LemonMemory.Provider` asks for,
  and it is not a formality: the registry discards a whole result set that is
  not a plain list of documents, and a memory search runs on the agent's path,
  where a raise would cost a turn rather than a search. Failures are logged at
  debug and the caller is told "no results", because the behaviour has no
  channel for saying anything richer.

  ## How a Lemon scope becomes a Honcho search

  Honcho partitions memory by *session* inside a *workspace*. A result may only
  ever be the requester's own memory, so the mapping narrows or answers `[]`;
  it never widens:

    * `:session` with a `:scope_key` whose Honcho session id is already known to
      `LemonHoncho.SessionManager` searches that one session, filtered to the
      requesting owner (`LemonHoncho.Owner`: the key's agent and the human peer
      resolved from the key and its `:channel_identity`). The client drops
      every hit not tagged for exactly that owner.
    * A `:session` whose key has no Honcho mapping yet returns `[]` without a
      request. Searching the workspace instead would answer with other
      people's conversations.
    * `:agent`, `:workspace`, `:all` and any unrecognised scope return `[]`
      without a request. The provider options name an agent id or a Lemon
      workspace key but not the human peer asking, so none of them can be
      partitioned by person, and a workspace-wide search is every user's memory.
    * A `:session` search with no `:scope_key` returns `[]` too.

  ## What a Honcho message becomes

  A Honcho search hit is a single message — one utterance by one peer — not a
  finished run with a prompt and an answer, so most of `LemonMemory.Document`
  has no counterpart and is filled with the empty value of its declared type
  rather than invented. The choices worth knowing:

    * **`answer_summary` carries the message, `prompt_summary` stays `""`.** A
      message has one body and no question/answer split. Attributing a user's
      message to `prompt_summary` and an assistant's to `answer_summary` was the
      alternative and is worse: every reading surface would then show half the
      corpus as blank. The author is recorded in `meta.peer_id` instead, which is
      where a caller that cares about attribution can find it.
    * **`doc_id` is `"hon_"` plus Honcho's message id**, or a digest of the
      message when it has none, so that the registry's dedupe by `doc_id` treats
      the same message returned by two searches as one document.
    * **`scope` is `:session`**, `session_key` is the requested key and
      `agent_id` is that key's agent: every returned message was checked to
      belong to that session's owner, so the labels are true.
    * **`run_id` is `""`**, not `nil`: it is declared `binary()` and the
      registry sorts and dedupes over these structs, so a `nil` in a `binary()`
      field is a type error waiting to surface somewhere far from here.

  An entry that is not a map, or that carries no text, is dropped rather than
  turned into an empty document.

  ## The query is screened before it leaves

  A memory search runs on whatever the user just typed, and the query travels as
  a URL query parameter on a `GET`, so it lands in the far side's access log as
  well as their store. It goes through `LemonHoncho.Egress.screen/2` — the same
  gate `LemonHoncho.SessionManager` puts its retrieval query through — and a
  query that looks like it carries a credential searches nothing.

  Unlike the tools, this path *cannot* explain itself: `LemonMemory.Provider`
  gives `search/2` one channel, a list of documents, and the honest value for
  "this was not searched" is the same `[]` every other failure returns. A caller
  that needs to know why asks a tool.

  ## `put/2` always returns `:ok`

  Writing is `LemonHoncho.SessionManager`'s job — it uploads a finished run's
  summaries off the caller's path — so `put/2` hands the document over and
  returns `:ok`. It returns `:ok` when Honcho is unconfigured too, and when the
  manager is not even running. That is deliberate rather than sloppy: `put/2`
  runs on the run-finalisation path where the registry logs the error and
  discards it, so an `{:error, _}` for the ordinary state of "this optional
  integration is switched off" buys nothing but a warning per finished run.

  ## Testing seam

  The client module is read from
  `Application.get_env(:lemon_honcho, :client, LemonHoncho.Client)` — the same
  seam `LemonHoncho.SessionManager` resolves at `init/1` — so a test can drive
  this module against a stub without a network and without a second mechanism
  to remember.
  """

  @behaviour LemonMemory.Provider

  require Logger

  alias LemonHoncho.{Config, Egress, Owner, SessionManager}
  alias LemonMemory.Document

  @default_limit 5
  @max_limit 100

  # Honcho embeds the query to search semantically, so an unbounded one is both
  # slow and liable to be rejected outright. A pasted file is clipped to the
  # part that can plausibly act as a query.
  @max_query_chars 2_000

  @provider_name "honcho"
  @doc_id_prefix "hon_"
  @doc_id_digest_bytes 8

  # Honcho answers in JSON, so every key arrives as a string. A stub — or a
  # future client that decodes into atoms — is read just as happily rather than
  # silently producing documents with no content.
  @atom_keys %{
    "content" => :content,
    "created_at" => :created_at,
    "id" => :id,
    "peer_id" => :peer_id,
    "session_id" => :session_id
  }

  @doc """
  Hands a finished run's document to `LemonHoncho.SessionManager` for upload.

  Always returns `:ok` — see the moduledoc for why an unconfigured or unreachable
  Honcho is not reported as an error here. The upload itself is asynchronous and
  gated by the manager, which owns `save_messages?` and the "is this configured"
  decision so that they live in exactly one place.
  """
  @impl true
  @spec put(Document.t(), keyword()) :: :ok
  def put(%Document{} = document, _opts) do
    SessionManager.sync_document(document)
    :ok
  end

  @doc """
  Searches Honcho and returns matching documents, or `[]`.

  Honours `:scope`, `:scope_key`, `:channel_identity` and `:limit` (default
  #{@default_limit}, capped at #{@max_limit}); every other option, known to the
  platform or not, is ignored. The query itself is trimmed and clipped to
  #{@max_query_chars} characters, because Honcho searches semantically and a
  pasted transcript is a slow embedding rather than a useful query, and then
  screened by `LemonHoncho.Egress.screen/2` so that a query which looks like it
  carries a credential is never put on the wire.

  Returns `[]` — never an error tuple, never a raise — for a blank query, a
  query withheld by the screen, an unconfigured integration, any scope other
  than a mapped `:session`, an unreachable Honcho, and a response it cannot
  make sense of.
  """
  @impl true
  @spec search(binary(), keyword()) :: [Document.t()]
  def search(query, opts) when is_binary(query) and is_list(opts) do
    config = Config.load()

    with true <- Config.configured?(config),
         :session <- Keyword.get(opts, :scope, :session),
         key when is_binary(key) <- present(Keyword.get(opts, :scope_key)),
         {:ok, trimmed} <- usable_query(query),
         {:ok, session_id, owner} <- session_route(key, opts, config) do
      config
      |> client().session_search(session_id, trimmed, limit: limit(opts), owner: owner)
      |> to_documents(key, owner)
    else
      _not_searchable -> []
    end
  rescue
    error ->
      Logger.debug("honcho: memory search failed: #{inspect(error)}")
      []
  catch
    kind, reason ->
      Logger.debug("honcho: memory search exited: #{inspect({kind, reason})}")
      []
  end

  def search(_query, _opts), do: []

  ## Routing

  # A session Honcho has never been told about cannot be searched by id, and
  # inventing one from `LemonHoncho.SessionName` would address a session that
  # may not exist. "Not mapped" is `[]`, never a wider search. The owner comes
  # from the options' admitted proof and transport identity, with the scope key
  # as the session key; without a proven owner nothing is searched.
  defp session_route(key, opts, config) do
    with {:ok, owner} <- Owner.from_context(config, Keyword.put(opts, :session_key, key)),
         {:ok, session_id} when is_binary(session_id) <-
           SessionManager.honcho_session_id(SessionManager.entry_key(key, owner)) do
      {:ok, session_id, owner}
    else
      _unmapped_or_unproven -> :error
    end
  end

  defp client, do: LemonHoncho.client()

  # The clip and the credential check are one operation, applied in that order:
  # what is screened is the text that would actually be sent, not the longer
  # original. A withheld query is `:error` here, which the `with` in `search/2`
  # turns into the `[]` the behaviour asks for.
  defp usable_query(query) do
    case query |> String.trim() |> Egress.screen(@max_query_chars) do
      nil -> :error
      screened -> {:ok, screened}
    end
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      limit when is_integer(limit) and limit > 0 -> min(limit, @max_limit)
      _other -> @default_limit
    end
  end

  ## Response mapping

  defp to_documents({:ok, results}, key, owner) when is_list(results) do
    Enum.flat_map(results, &document(&1, key, owner))
  end

  defp to_documents({:ok, _other}, _key, _owner), do: []

  defp to_documents({:error, reason}, _key, _owner) do
    Logger.debug("honcho: memory search failed: #{inspect(reason)}")
    []
  end

  defp to_documents(_other, _key, _owner), do: []

  # The client already drops hits of other owners; checking again here keeps
  # the labels below true whichever client module is installed.
  defp document(entry, key, owner) when is_map(entry) do
    with true <- Owner.owns?(owner, entry),
         content when content != "" <- content(entry) do
      [build(entry, content, key, owner)]
    else
      _foreign_or_empty -> []
    end
  end

  defp document(_entry, _key, _owner), do: []

  defp build(entry, content, key, %Owner{} = owner) do
    created_at = field(entry, "created_at")
    at_ms = timestamp(created_at)
    session_id = entry |> field("session_id") |> string() |> to_empty()
    message_id = entry |> field("id") |> string()

    %Document{
      doc_id: doc_id(message_id, [content, session_id, string(created_at) || ""]),
      run_id: "",
      session_key: key,
      agent_id: owner.agent_id,
      workspace_key: nil,
      scope: :session,
      started_at_ms: at_ms,
      ingested_at_ms: at_ms,
      prompt_summary: "",
      answer_summary: clip(content),
      tools_used: [],
      provider: @provider_name,
      model: nil,
      outcome: :unknown,
      meta: %{
        source: @provider_name,
        peer_id: entry |> field("peer_id") |> string(),
        message_id: message_id,
        session_id: session_id
      }
    }
  end

  # Honcho ids are stable, so they make the best dedupe key. A message without
  # one still needs an id that is the same every time the same message comes
  # back, which is what a digest of its content and provenance provides —
  # deliberately not of anything derived from the clock, or the same message
  # would arrive under a new id on every search and defeat the dedupe.
  defp doc_id(nil, parts) do
    digest =
      :sha256
      |> :crypto.hash(parts)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @doc_id_digest_bytes * 2)

    @doc_id_prefix <> digest
  end

  defp doc_id(message_id, _parts), do: @doc_id_prefix <> message_id

  defp content(entry) do
    case field(entry, "content") do
      value when is_binary(value) -> String.trim(value)
      _other -> ""
    end
  end

  defp field(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> Map.get(entry, Map.fetch!(@atom_keys, key))
    end
  end

  # Only ISO-8601 is understood, because that is what Honcho sends. Anything
  # else — a missing field, a unix integer, a malformed string — becomes "now",
  # which keeps the document sortable rather than dropping it over a timestamp.
  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      {:error, _reason} -> naive_timestamp(value)
    end
  end

  defp timestamp(_value), do: now_ms()

  defp naive_timestamp(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
      {:error, _reason} -> now_ms()
    end
  end

  # The same figure `LemonMemory.Document` caps its summaries at, applied as
  # characters rather than bytes so a clip can never split a codepoint.
  defp clip(content), do: String.slice(content, 0, Document.max_summary_bytes())

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp to_empty(nil), do: ""
  defp to_empty(value), do: value

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp present(_value), do: nil

  defp now_ms, do: System.system_time(:millisecond)
end
