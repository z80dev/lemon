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

  Honcho partitions memory by *session* inside a *workspace*, and knows nothing
  about Lemon's agents or workspaces. The mapping follows from that:

    * `:session` with a `:scope_key` whose Honcho session id is already known to
      `LemonHoncho.SessionManager` searches that one session. This is the only
      case that can be narrowed truthfully.
    * `:agent`, `:workspace`, `:all`, and a `:session` whose key has no Honcho
      mapping yet search the whole workspace. Honcho has no partition matching
      an agent id or a Lemon workspace key, so a workspace-wide semantic search
      is the most honest thing a scoped request can be answered with.
    * A *scoped* search (`:session`, `:agent`, `:workspace`) that arrives with no
      `:scope_key` returns `[]` without calling Honcho at all. The behaviour is
      explicit that a missing scope key must narrow to nothing rather than widen
      to everything, and that rule outranks the mapping above.

  Only `:all` is unscoped, so only `:all` reaches Honcho without a key.

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
    * **`scope` echoes the requested scope**, except that `:all` — which is a
      search scope but not a document scope — is recorded as `:global`, the
      document scope with the same meaning.
    * **`run_id` and `agent_id` are `""`**, not `nil`: both are declared
      `binary()` and the registry sorts and dedupes over these structs, so a
      `nil` in a `binary()` field is a type error waiting to surface somewhere
      far from here.

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

  alias LemonHoncho.Config
  alias LemonHoncho.Egress
  alias LemonHoncho.SessionManager
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

  @scopes [:session, :agent, :workspace, :all]
  @scoped [:session, :agent, :workspace]

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

  Honours `:scope`, `:scope_key` and `:limit` (default #{@default_limit}, capped
  at #{@max_limit}); every other option, known to the platform or not, is
  ignored. The query itself is trimmed and clipped to #{@max_query_chars}
  characters, because Honcho searches semantically and a pasted transcript is a
  slow embedding rather than a useful query, and then screened by
  `LemonHoncho.Egress.screen/2` so that a query which looks like it carries a
  credential is never put on the wire.

  Returns `[]` — never an error tuple, never a raise — for a blank query, a
  query withheld by the screen, an unconfigured integration, a scoped search
  with no scope key, an unreachable Honcho, and a response it cannot make sense
  of.
  """
  @impl true
  @spec search(binary(), keyword()) :: [Document.t()]
  def search(query, opts) when is_binary(query) and is_list(opts) do
    config = Config.load()
    scope = normalize_scope(Keyword.get(opts, :scope, :session))

    with true <- Config.configured?(config),
         {:ok, trimmed} <- usable_query(query),
         {:ok, route} <- route(scope, opts) do
      config
      |> fetch(route, trimmed, opts)
      |> to_documents(scope, opts)
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

  # An unrecognized scope is treated as the unscoped one rather than rejected:
  # the platform adds keys and values over time, and answering a future scope
  # with a workspace-wide search is better than answering it with nothing.
  defp normalize_scope(scope) when scope in @scopes, do: scope
  defp normalize_scope(_other), do: :all

  defp route(scope, opts) do
    case {scope, present(Keyword.get(opts, :scope_key))} do
      {:session, nil} -> :error
      {:session, key} -> {:ok, session_route(key)}
      {scoped, nil} when scoped in @scoped -> :error
      {_scope, _key} -> {:ok, :workspace}
    end
  end

  # A session Honcho has never been told about cannot be searched by id, and
  # inventing one from `LemonHoncho.SessionName` would address a session that
  # does not exist and 404. The workspace search is the degraded answer.
  defp session_route(key) do
    case SessionManager.honcho_session_id(key) do
      {:ok, session_id} when is_binary(session_id) -> {:session, session_id}
      _unmapped -> :workspace
    end
  end

  defp fetch(config, {:session, session_id}, query, opts) do
    client().session_search(config, session_id, query, limit: limit(opts))
  end

  defp fetch(config, :workspace, query, opts) do
    client().workspace_search(config, query, limit: limit(opts))
  end

  defp client, do: Application.get_env(:lemon_honcho, :client, LemonHoncho.Client)

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

  defp to_documents({:ok, results}, scope, opts) when is_list(results) do
    Enum.flat_map(results, &document(&1, scope, opts))
  end

  defp to_documents({:ok, _other}, _scope, _opts), do: []

  defp to_documents({:error, reason}, _scope, _opts) do
    Logger.debug("honcho: memory search failed: #{inspect(reason)}")
    []
  end

  defp to_documents(_other, _scope, _opts), do: []

  defp document(entry, scope, opts) when is_map(entry) do
    case content(entry) do
      "" -> []
      content -> [build(entry, content, scope, opts)]
    end
  end

  defp document(_entry, _scope, _opts), do: []

  defp build(entry, content, scope, opts) do
    created_at = field(entry, "created_at")
    at_ms = timestamp(created_at)
    session_id = entry |> field("session_id") |> string() |> to_empty()
    message_id = entry |> field("id") |> string()

    %Document{
      doc_id: doc_id(message_id, [content, session_id, string(created_at) || ""]),
      run_id: "",
      session_key: session_key(scope, opts, session_id),
      agent_id: agent_id(scope, opts),
      workspace_key: nil,
      scope: document_scope(scope),
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

  # `:all` is a search scope but not a document scope; `:global` is the document
  # scope that means the same thing.
  defp document_scope(:all), do: :global
  defp document_scope(scope), do: scope

  defp session_key(:session, opts, _session_id) do
    opts |> Keyword.get(:scope_key) |> string() |> to_empty()
  end

  defp session_key(_scope, _opts, session_id), do: session_id

  # An agent-scoped search is keyed by the agent id, so the scope key *is* the
  # agent id when no explicit one was passed.
  defp agent_id(:agent, opts) do
    to_empty(string(Keyword.get(opts, :agent_id)) || string(Keyword.get(opts, :scope_key)))
  end

  defp agent_id(_scope, opts) do
    opts |> Keyword.get(:agent_id) |> string() |> to_empty()
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
