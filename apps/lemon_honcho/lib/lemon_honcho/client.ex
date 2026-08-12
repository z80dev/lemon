defmodule LemonHoncho.Client do
  @moduledoc """
  The only thing in `lemon_honcho` that talks HTTP to Honcho.

  Everything above this module — the session manager, the memory provider, the
  agent tools — works in terms of `{:ok, term()} | {:error, term()}` and never
  sees a `Req.Response`, a status code, or an exception. That is the whole
  point of the module: one place where a remote service's failure modes are
  translated into values, so that a Honcho outage degrades a turn instead of
  crashing it.

  ## The contract every function upholds

  Each function takes a `t:LemonHoncho.Config.t/0` first, so nothing here reads
  process-wide state and every call can be tested by passing a struct. Each
  returns `{:ok, decoded_body}` for a 2xx response and a tagged error tuple
  otherwise. No function raises: a malformed option, a plug that blows up, a
  DNS failure, and a garbage response body all come back as `{:error, reason}`.

  The error vocabulary is small on purpose, because callers pattern-match on it:

    * `{:error, :not_configured}` — the config has neither an API key nor a
      base URL, so there is nowhere to send the request. Callers treat this as
      "memory is off", not as a failure.
    * `{:error, {:unauthorized, body}}` — a 401. Split out from the generic
      API error because it is nearly always a stale or wrong `HONCHO_API_KEY`,
      and that deserves a specific log line rather than "HTTP 401".
    * `{:error, {:api_error, status, body}}` — any other non-2xx response.
    * `{:error, {:transport, reason}}` — the request never produced a
      response: a timeout, a refused connection, a raised exception.

  A 2xx response with an empty body (a 204, or a 200 with no content) is
  normalized to `{:ok, %{}}` rather than `{:ok, ""}` or `{:ok, nil}`, so a
  caller pattern-matching on a map never has to special-case "succeeded but
  said nothing". `delete_conclusion/2` follows the same rule.

  ## Where the requests actually go

  `config.base_url` wins when it is set, and a trailing version segment is
  stripped from it. This is not cosmetic: every route below already carries its
  own `/v3` prefix, so a base URL of `https://honcho.example/v3` would produce
  `/v3/v3/workspaces` and 404 on *every* call — a failure that looks like a
  broken deployment rather than a misspelled setting. With no base URL the
  `environment` names the deployment (`production`, `demo`, `local`), and an
  unrecognized value falls back to production rather than failing.

  Authorization is sent only when an API key is actually configured. A
  self-hosted Honcho on loopback, a private network, or carrier-grade NAT space
  (where Tailscale addresses live) commonly runs with authentication off, so a
  missing key against such an endpoint is a supported configuration and not an
  error; against a public endpoint it is logged at debug, because the resulting
  401 is otherwise mystifying.

  Every path segment — the workspace, peer, session, and conclusion ids — is
  percent-encoded. Session ids in particular are derived from directories and
  gateway keys by `LemonHoncho.SessionName`, and a stray `/` there would
  silently address a different route.

  ## Retries, and how long a call can take

  A request is retried when the same request could plausibly succeed a moment
  later: a 429 or a 5xx, a timeout, a closed or refused connection, an HTTP/2
  stream that was never processed. It is *not* retried when the failure is
  structural — a name that does not resolve, a network with no route, a TLS
  handshake that will never verify, a malformed option. Those cannot become
  healthy inside a few seconds of backoff, and retrying them used to be the
  single largest contributor to how long a failing call took.

  That still leaves the ordinary bound wide: up to two retries, each waiting
  `config.timeout_ms`, with Req's exponential backoff in between. That
  is the right trade on the turn path, where a transient 502 costing three
  seconds beats a turn assembled without memory. It is the wrong trade for a
  diagnostic, where the operator is watching a terminal and needs the answer to
  arrive within the number printed on the tin — so `ensure_workspace/2` accepts
  `:max_retries` and `:total_timeout` to bound one call explicitly. Nothing else
  here takes them, because nothing else is on that path.

  ## Testing

  Request options are merged from `Application.get_env(:lemon_honcho,
  :req_options, [])` last, so a test can inject a `Req.Test` plug (and disable
  retries) without any function here growing a transport parameter.
  """

  require Logger

  alias LemonHoncho.Config

  @typedoc "What every call in this module returns."
  @type result :: {:ok, term()} | {:error, term()}

  @typedoc "Per-peer observation flags as Honcho's session API expects them."
  @type peer_flags :: %{
          optional(:observe_me) => boolean(),
          optional(:observe_others) => boolean()
        }

  @typedoc "A peer and the flags it joins a session with."
  @type peer_spec :: {String.t(), peer_flags()}

  @typedoc "One message as Honcho stores it: content plus the peer who authored it."
  @type message :: %{content: String.t(), peer_id: String.t()}

  @typedoc "One conclusion: who observed whom, saying what, optionally in a session."
  @type conclusion :: %{
          required(:observer_id) => String.t(),
          required(:observed_id) => String.t(),
          required(:content) => String.t(),
          optional(:session_id) => String.t() | nil
        }

  @api_version "v3"
  @production_url "https://api.honcho.dev"
  @demo_url "https://demo.honcho.dev"
  @local_url "http://localhost:8000"
  @retry_statuses [429, 500, 502, 503, 504]
  @max_retries 2
  @default_search_limit 10
  @default_top_k 10

  # The exception reasons a second attempt can plausibly fix. Everything absent
  # from this list fails on the first attempt; see `retry?/2`.
  @retry_reasons [
    :timeout,
    :closed,
    :econnreset,
    :econnrefused,
    :pool_timeout,
    :unprocessed,
    :pool_not_available
  ]

  # Floor for a per-attempt timeout derived from `:total_timeout`. A ceiling of
  # a few milliseconds is a typo rather than a request, and honouring it
  # literally would report a healthy endpoint as unreachable.
  @min_attempt_timeout_ms 250

  @typedoc """
  Per-call bounds for the diagnostic path. See `ensure_workspace/2`.
  """
  @type call_opts :: [max_retries: non_neg_integer(), total_timeout: pos_integer()]

  @doc """
  Creates the configured workspace, or returns the existing one.

  Honcho's create endpoints are get-or-create, so this is safe to call on every
  boot and is how the rest of the app avoids ordering problems: a peer or
  session write into a workspace that does not exist yet fails, and calling
  this first is cheaper than reasoning about which call happens to run first.

  Being both cheap and get-or-create is also why this is the call the operator
  task probes with, and why it is the only one here that takes bounds.

  ## Options

  `opts` defaults to the ordinary behaviour every other function here has:
  `config.timeout_ms` per attempt and up to #{@max_retries} retries with Req's
  exponential backoff. Pass either option to trade "try hard to succeed" for
  "answer within a stated time":

    * `:max_retries` — retries allowed for this call. `0` makes it a single
      attempt.
    * `:total_timeout` — a ceiling in milliseconds on the whole call, retries
      and backoff included. The per-attempt timeout is derived from it
      (`total_timeout` divided by the number of attempts, never above
      `config.timeout_ms` and never below #{@min_attempt_timeout_ms} ms), the
      connect timeout is bounded to the same value, and the retry backoff is
      pinned to zero — so the call returns in roughly `total_timeout` instead of
      in `attempts * timeout_ms` plus one, two, four seconds of backoff.

  ## Examples

      iex> config = %LemonHoncho.Config{}
      iex> LemonHoncho.Client.ensure_workspace(config, max_retries: 0, total_timeout: 1_000)
      {:error, :not_configured}
  """
  @spec ensure_workspace(Config.t(), call_opts()) :: result()
  def ensure_workspace(%Config{} = config, opts \\ []) do
    request(config, :post, ["workspaces"], [json: %{id: config.workspace}], opts)
  end

  @doc """
  Creates a peer in the workspace, or returns the existing one.

  A peer is the durable identity memory accumulates against — the human at the
  keyboard, or the assistant. Like workspaces, this is get-or-create.
  """
  @spec ensure_peer(Config.t(), String.t()) :: result()
  def ensure_peer(%Config{} = config, peer_id) when is_binary(peer_id) do
    request(config, :post, scoped(config, ["peers"]), json: %{id: peer_id})
  end

  @doc """
  Creates a session with its peers attached, or returns the existing one.

  `peer_specs` is a list of `{peer_id, flags}` tuples, which is turned into the
  object Honcho expects — a map of peer id to its observation flags. Only
  `:observe_me` and `:observe_others` are forwarded; anything else in the flag
  map is dropped rather than sent to an endpoint that would reject it.
  """
  @spec ensure_session(Config.t(), String.t(), [peer_spec()]) :: result()
  def ensure_session(%Config{} = config, session_id, peer_specs)
      when is_binary(session_id) and is_list(peer_specs) do
    body = %{id: session_id, peers: peers_object(peer_specs)}

    request(config, :post, scoped(config, ["sessions"]), json: body)
  end

  @doc """
  Sets one peer's observation flags inside a session.

  Used when a session already exists but the operator has changed
  `observation_mode`: the flags recorded at creation time are otherwise
  sticky, and memory would keep being written from the old perspective.
  """
  @spec set_peer_config(Config.t(), String.t(), String.t(), peer_flags()) :: result()
  def set_peer_config(%Config{} = config, session_id, peer_id, flags) when is_map(flags) do
    segments = scoped(config, ["sessions", session_id, "peers", peer_id, "config"])

    request(config, :put, segments, json: observation_flags(flags))
  end

  @doc """
  Appends messages to a session.

  Each message is `%{content: ..., peer_id: ...}`; the peer is the author, and
  Honcho adds it to the session automatically if it is not a member yet.
  Truncation is deliberately *not* done here — the caller owns
  `message_max_chars`, because only it knows which half of a turn to cut.
  """
  @spec add_messages(Config.t(), String.t(), [message()]) :: result()
  def add_messages(%Config{} = config, session_id, messages) when is_list(messages) do
    body = %{messages: Enum.map(messages, &Map.take(&1, [:content, :peer_id]))}

    request(config, :post, scoped(config, ["sessions", session_id, "messages"]), json: body)
  end

  @doc """
  Reads the assembled context for a session: summary, messages, representation.

  ## Options

    * `:summary` — ask Honcho to include its rolling summary.
    * `:tokens` — token budget for the assembled context.
    * `:peer_target` — the peer the representation should be about.
    * `:peer_perspective` — whose view of `:peer_target` to return.
    * `:search_query` — semantic query used to select relevant conclusions.
    * `:limit_to_session` — restrict the representation to this session.

  Only the options you pass are sent, so Honcho's own server-side defaults
  apply to the rest. Honcho rejects `:peer_perspective` or `:search_query`
  without a `:peer_target`; that pairing is the caller's responsibility and
  surfaces here as an ordinary `{:error, {:api_error, 4xx, _}}`.
  """
  @spec session_context(Config.t(), String.t(), keyword()) :: result()
  def session_context(%Config{} = config, session_id, opts \\ []) do
    query =
      query_params(opts, [
        :summary,
        :tokens,
        :peer_target,
        :peer_perspective,
        :search_query,
        :limit_to_session
      ])

    request(config, :get, scoped(config, ["sessions", session_id, "context"]), params: query)
  end

  @doc """
  Reads a peer's context: its representation and peer card.

  ## Options

    * `:target` — return this peer's view of another peer instead of its own.
    * `:search_query` — semantic query used to select relevant conclusions.
    * `:search_top_k` — how many semantically relevant facts to return.
    * `:max_conclusions` — cap on the conclusions included.
  """
  @spec peer_context(Config.t(), String.t(), keyword()) :: result()
  def peer_context(%Config{} = config, peer_id, opts \\ []) do
    query = query_params(opts, [:target, :search_query, :search_top_k, :max_conclusions])

    request(config, :get, scoped(config, ["peers", peer_id, "context"]), params: query)
  end

  @doc """
  Asks Honcho's dialectic endpoint a natural-language question about a peer.

  This is the expensive call in the integration — Honcho reasons over the
  peer's representation — which is why the session manager runs it on a cadence
  rather than every turn.

  Returns `{:ok, answer}`, or `{:ok, nil}` when Honcho has nothing relevant to
  say. A null or blank `content` in the response is normal rather than
  exceptional (a fresh peer knows nothing), so it is *not* an error.

  ## Options

    * `:target` — ask what this peer knows about another peer.
    * `:session_id` — scope the question to one session.
    * `:reasoning_level` — `:minimal`, `:low`, `:medium`, `:high`, or `:max`.
  """
  @spec chat(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def chat(%Config{} = config, peer_id, query, opts \\ []) when is_binary(query) do
    body =
      %{query: query, stream: false}
      |> put_present(:target, Keyword.get(opts, :target))
      |> put_present(:session_id, Keyword.get(opts, :session_id))
      |> put_present(:reasoning_level, Keyword.get(opts, :reasoning_level))

    case request(config, :post, scoped(config, ["peers", peer_id, "chat"]), json: body) do
      {:ok, %{"content" => content}} when is_binary(content) -> {:ok, blank_to_nil(content)}
      {:ok, _body} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Searches the messages of one session.

  ## Options

    * `:limit` — number of results (Honcho accepts 1..100, default #{@default_search_limit}).
    * `:filters` — additional server-side filters.
  """
  @spec session_search(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def session_search(%Config{} = config, session_id, query, opts \\ []) do
    body = search_body(query, opts)

    config
    |> request(:post, scoped(config, ["sessions", session_id, "search"]), json: body)
    |> as_list()
  end

  @doc """
  Searches every message in the workspace, across sessions.

  Takes the same options as `session_search/4`.
  """
  @spec workspace_search(Config.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def workspace_search(%Config{} = config, query, opts \\ []) do
    config
    |> request(:post, scoped(config, ["search"]), json: search_body(query, opts))
    |> as_list()
  end

  @doc """
  Reads a peer card — the short, human-readable profile Honcho keeps for a peer.

  Returns `{:ok, lines}` or `{:ok, nil}` when no card exists yet. Pass
  `:target` to read this peer's card *of* another peer.
  """
  @spec get_peer_card(Config.t(), String.t(), keyword()) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def get_peer_card(%Config{} = config, peer_id, opts \\ []) do
    params = query_params(opts, [:target])

    config
    |> request(:get, scoped(config, ["peers", peer_id, "card"]), params: params)
    |> as_peer_card()
  end

  @doc """
  Replaces a peer card with the given lines.

  Returns the stored card, or `{:ok, nil}` if Honcho does not echo one back.
  Pass `:target` to write this peer's card of another peer.
  """
  @spec set_peer_card(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, [String.t()] | nil} | {:error, term()}
  def set_peer_card(%Config{} = config, peer_id, card, opts \\ []) when is_list(card) do
    options = [json: %{peer_card: card}, params: query_params(opts, [:target])]

    config
    |> request(:put, scoped(config, ["peers", peer_id, "card"]), options)
    |> as_peer_card()
  end

  @doc """
  Writes explicit conclusions — facts stated outright rather than inferred.

  Each conclusion names an observer, an observed peer, and the content; a
  `:session_id` is optional and is omitted from the payload when absent, since
  Honcho treats a null session differently from an unset one.
  """
  @spec create_conclusions(Config.t(), [conclusion()]) :: result()
  def create_conclusions(%Config{} = config, conclusions) when is_list(conclusions) do
    body = %{conclusions: Enum.map(conclusions, &conclusion_payload/1)}

    request(config, :post, scoped(config, ["conclusions"]), json: body)
  end

  @doc """
  Semantically searches stored conclusions.

  ## Options

    * `:observer_id` / `:observed_id` — scope the search to one direction of
      observation. Both are sent inside `filters`, which is where Honcho's
      conclusion API expects them.
    * `:top_k` — maximum results (default #{@default_top_k}).
  """
  @spec query_conclusions(Config.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query_conclusions(%Config{} = config, query, opts \\ []) do
    body = %{
      query: query,
      top_k: Keyword.get(opts, :top_k, @default_top_k),
      filters: opts |> query_params([:observer_id, :observed_id]) |> Map.new()
    }

    config
    |> request(:post, scoped(config, ["conclusions", "query"]), json: body)
    |> as_list()
  end

  @doc """
  Deletes one conclusion by id.

  Honcho answers with an empty body, so a success is `{:ok, %{}}` — the same
  shape every other empty response takes here.
  """
  @spec delete_conclusion(Config.t(), String.t()) :: result()
  def delete_conclusion(%Config{} = config, conclusion_id) when is_binary(conclusion_id) do
    request(config, :delete, scoped(config, ["conclusions", conclusion_id]), [])
  end

  ## Request construction

  # Every route below the workspace shares this prefix; spelling it once is what
  # keeps a new endpoint from forgetting to scope itself to the workspace.
  defp scoped(%Config{} = config, segments), do: ["workspaces", config.workspace | segments]

  defp request(%Config{} = config, method, segments, options, call_opts \\ []) do
    case endpoint(config) do
      {:ok, base_url} -> dispatch(config, base_url, method, segments, options, call_opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(config, base_url, method, segments, options, call_opts) do
    bounds = bounds(config, call_opts)

    request_options =
      [
        method: method,
        url: base_url <> path(segments),
        headers: headers(config, base_url),
        receive_timeout: bounds.attempt_timeout,
        retry: &retry?/2,
        max_retries: bounds.max_retries
      ]
      |> Keyword.merge(bounds.extra)
      |> Keyword.merge(payload_options(options))
      |> Keyword.merge(override_options())

    request_options |> Req.new() |> Req.request() |> handle_response()
  rescue
    exception -> transport_error(exception)
  catch
    :exit, reason -> transport_error({:exit, reason})
  end

  # Ordinary calls keep the bound every caller above already relies on. A call
  # that names a `:total_timeout` is the diagnostic path and gets the opposite
  # trade: the wait is capped by the number the operator can see, even when a
  # longer one would have succeeded.
  #
  # `connect_options` is set only on that path. It is what makes the ceiling
  # cover a host that accepts a connection slowly rather than only a host that
  # answers slowly — and it is deliberately not set otherwise, because Req
  # starts a separate Finch pool per distinct connect option set and the turn
  # path should keep sharing one.
  defp bounds(%Config{} = config, call_opts) do
    max_retries = Keyword.get(call_opts, :max_retries, @max_retries)

    case Keyword.get(call_opts, :total_timeout) do
      total when is_integer(total) and total > 0 ->
        attempt = attempt_timeout(config, total, max_retries + 1)

        %{
          max_retries: max_retries,
          attempt_timeout: attempt,
          extra: [retry_delay: 0, connect_options: [timeout: attempt]]
        }

      _unbounded ->
        %{max_retries: max_retries, attempt_timeout: config.timeout_ms, extra: []}
    end
  end

  # `config.timeout_ms` is the last clamp on purpose: a caller asking for a
  # ceiling can only ever shorten a request, never extend one past the timeout
  # the deployment configured.
  defp attempt_timeout(%Config{} = config, total, attempts) do
    total |> div(attempts) |> max(@min_attempt_timeout_ms) |> min(config.timeout_ms)
  end

  # An empty params list would still add a "?" to the URL on some Req versions,
  # and a nil json body would send `null` rather than no body at all, so both
  # are dropped rather than passed through.
  defp payload_options(options) do
    Enum.reject(options, fn
      {:params, params} -> params == []
      {:json, nil} -> true
      _other -> false
    end)
  end

  # Read at call time rather than into a module attribute: tests set this after
  # the module is already compiled and loaded.
  defp override_options, do: Application.get_env(:lemon_honcho, :req_options, [])

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, normalize_body(body)}
  end

  defp handle_response({:ok, %Req.Response{status: 401, body: body}}) do
    Logger.warning("honcho: request rejected (401) — check HONCHO_API_KEY")
    {:error, {:unauthorized, body}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.debug("honcho: request failed with HTTP #{status}: #{summarize(body)}")
    {:error, {:api_error, status, body}}
  end

  defp handle_response({:error, exception}), do: transport_error(exception)

  defp transport_error(reason) do
    Logger.debug("honcho: request did not complete: #{inspect(reason)}")
    {:error, {:transport, reason}}
  end

  # Statuses are the easy half. Exceptions are the half worth explaining:
  # retrying *every* exception meant that a name which does not resolve, a
  # network with no route, a TLS handshake that will never verify, and an
  # outright bug in a request option each cost three attempts plus one, two,
  # four seconds of backoff before the caller was told something it could have
  # been told immediately — and none of those become healthy in that window.
  #
  # The allowlist is Req's own `:transient` set (a timeout, a closed connection,
  # a refused connection — a server restarting behind a load balancer really can
  # answer the next attempt — and the two HTTP/2 conditions that mean the request
  # was never processed) plus a pool checkout timeout. Anything else, including
  # an exception this module has never seen, fails on the first attempt. That is
  # the safe default here precisely because a failed call is never fatal: every
  # caller degrades to "no memory this turn".
  defp retry?(_request, %Req.Response{status: status}), do: status in @retry_statuses
  defp retry?(_request, exception) when is_exception(exception), do: retryable?(exception)
  defp retry?(_request, _other), do: false

  # Matched structurally rather than by module: `Req.TransportError`,
  # `Req.HTTPError`, `Mint.TransportError` and `Finch.Error` all carry their
  # reason in the same field, and one of them sometimes nests another.
  defp retryable?(%{reason: reason}), do: retryable_reason?(reason)
  defp retryable?(_exception), do: false

  defp retryable_reason?(%{reason: nested}), do: retryable_reason?(nested)
  defp retryable_reason?(reason), do: reason in @retry_reasons

  ## URL and auth

  defp endpoint(%Config{} = config) do
    cond do
      present?(config.base_url) -> {:ok, normalize_base_url(config.base_url)}
      present?(config.api_key) -> {:ok, environment_url(config.environment)}
      true -> {:error, :not_configured}
    end
  end

  # The routes below already carry "/v3", so an operator base URL that ends in a
  # version segment must lose it: "https://honcho.example/v3" would otherwise
  # produce "/v3/v3/workspaces" and 404 every single call.
  defp normalize_base_url(base_url) do
    base_url
    |> String.trim()
    |> String.replace(~r{/v\d+/*$}, "")
    |> String.trim_trailing("/")
  end

  defp environment_url(environment) do
    case environment |> to_string() |> String.trim() |> String.downcase() do
      "production" -> @production_url
      "demo" -> @demo_url
      "local" -> @local_url
      other -> unknown_environment(other)
    end
  end

  defp unknown_environment(other) do
    Logger.debug("honcho: unknown environment #{inspect(other)}, using production")
    @production_url
  end

  defp path(segments) do
    "/" <> Enum.map_join([@api_version | segments], "/", &encode_segment/1)
  end

  # Percent-encodes everything outside the unreserved set, so a session id built
  # from a path or a gateway key cannot escape into the route.
  defp encode_segment(segment) do
    segment |> to_string() |> URI.encode(&URI.char_unreserved?/1)
  end

  defp headers(%Config{api_key: api_key}, base_url) do
    if present?(api_key) do
      [{"authorization", "Bearer " <> String.trim(api_key)}]
    else
      warn_missing_key(base_url)
      []
    end
  end

  # A self-hosted Honcho on a private address may legitimately run without auth;
  # a public one will answer 401, and saying so here is what makes that 401
  # traceable to a missing setting rather than a bad key.
  defp warn_missing_key(base_url) do
    unless local_endpoint?(base_url) do
      Logger.debug("honcho: no API key configured for #{base_url}; expect 401")
    end

    :ok
  end

  defp local_endpoint?(base_url) do
    host = base_url |> URI.parse() |> Map.get(:host) |> to_string() |> String.downcase()

    cond do
      host in ["localhost", "127.0.0.1", "::1"] -> true
      host == "" -> false
      true -> private_host?(host)
    end
  end

  defp private_host?(host) do
    case host |> String.to_charlist() |> :inet.parse_address() do
      {:ok, address} -> private_address?(address)
      {:error, _reason} -> false
    end
  end

  defp private_address?({127, _b, _c, _d}), do: true
  defp private_address?({10, _b, _c, _d}), do: true
  defp private_address?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_address?({192, 168, _c, _d}), do: true
  defp private_address?({169, 254, _c, _d}), do: true
  # 100.64.0.0/10 is carrier-grade NAT, which is where Tailscale addresses live.
  defp private_address?({100, b, _c, _d}) when b in 64..127, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # fc00::/7 unique-local and fe80::/10 link-local.
  defp private_address?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFC00..0xFDFF, do: true
  defp private_address?({a, _b, _c, _d, _e, _f, _g, _h}) when a in 0xFE80..0xFEBF, do: true
  defp private_address?(_address), do: false

  ## Body and response shaping

  defp peers_object(peer_specs) do
    Map.new(peer_specs, fn {peer_id, flags} -> {peer_id, observation_flags(flags)} end)
  end

  defp observation_flags(flags), do: Map.take(flags, [:observe_me, :observe_others])

  defp search_body(query, opts) do
    %{query: query, limit: Keyword.get(opts, :limit, @default_search_limit)}
    |> put_present(:filters, Keyword.get(opts, :filters))
  end

  defp conclusion_payload(conclusion) do
    conclusion
    |> Map.take([:observer_id, :observed_id, :content, :session_id])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # `false` is a meaningful value for options like `:summary` and
  # `:limit_to_session`, so absence is tested with `nil` rather than
  # truthiness — a comprehension filter here would silently drop `summary:
  # false` and quietly change what Honcho returns.
  defp query_params(opts, keys) do
    keys
    |> Enum.map(fn key -> {key, Keyword.get(opts, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_body(nil), do: %{}
  defp normalize_body(""), do: %{}
  defp normalize_body(body), do: body

  defp as_list({:ok, results}) when is_list(results), do: {:ok, results}
  defp as_list({:ok, %{"items" => items}}) when is_list(items), do: {:ok, items}
  defp as_list({:ok, _body}), do: {:ok, []}
  defp as_list({:error, reason}), do: {:error, reason}

  defp as_peer_card({:ok, %{"peer_card" => card}}) when is_list(card), do: {:ok, card}
  defp as_peer_card({:ok, _body}), do: {:ok, nil}
  defp as_peer_card({:error, reason}), do: {:error, reason}

  defp blank_to_nil(content) do
    case String.trim(content) do
      "" -> nil
      _trimmed -> content
    end
  end

  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp summarize(body), do: body |> inspect() |> String.slice(0, 200)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
