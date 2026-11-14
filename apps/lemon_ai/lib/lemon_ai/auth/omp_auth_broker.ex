defmodule LemonAi.Auth.OmpAuthBroker do
  @moduledoc """
  Client for omp's auth broker (`omp auth-broker serve`).

  The broker is the only holder of OAuth refresh tokens and refreshes access
  tokens server-side. Its `/v1/snapshot` lists every active credential with the
  refresh token redacted: OAuth access tokens plus stored API keys. Lemon is a
  direct (trusted) broker client: it reads access tokens and API keys, never
  receives a refresh token, and never writes credentials back to the broker.

  ## Caching, watcher and concurrency

  Parsed snapshots are cached in ETS per endpoint (URL plus a digest of the
  bearer). After the first successful fetch the cache owner starts one
  background watcher for the endpoint. It long-polls
  `GET /v1/snapshot?wait=<ms>` with `If-None-Match: "<generation>"`: a 200
  replaces the cached snapshot wholesale (rotations, revocations and rate-limit
  blocks arrive immediately), a 304 confirms the cache is still current. While
  the watcher is healthy the cached snapshot is served regardless of age.

  If the watcher fails (broker unreachable, unauthorized, invalid response) it
  stops and the cache falls back to a 15 second TTL; the next successful fetch
  starts a new watcher. A watcher also stops after ten minutes without a read
  of its endpoint. A failed fetch is cached for 5 seconds so a down broker does
  not stall every resolution. Watchers are linked to the cache owner and die
  with it. Snapshot fetches and credential refreshes are single-flight per
  endpoint. Without the cache owner (the `:lemon_ai` application not started)
  there is no cache, no watcher, and every call goes to the broker.

  Watcher options (read from the fetch that starts it): `:watch` (boolean,
  default the `:lemon_ai, :omp_broker_watch` app env, `true`),
  `:watch_wait_ms` (default 25 000) and `:watch_idle_ms` (default 600 000);
  `:req_options` is reused for every poll.

  ## Expiry

  `credential/3` asks the broker to refresh an OAuth credential that expires
  within a minute of the broker's clock (`serverNowMs`, advanced by local
  monotonic time). `refresh/3` with `reason: "auth-recovery"` is the
  provider-rejected-token path: the broker may return a token it minted within
  the last five minutes instead of minting again.

  Requests send `OMP-Auth-Broker-Capabilities: codex-meter-block-scopes`, so
  Codex rate-limit blocks arrive with their canonical per-meter scopes. Errors
  are bare atoms that never contain broker responses or credentials.
  """

  use GenServer

  @table :lemon_ai_omp_auth_broker
  @snapshot_ttl_ms 15_000
  @failure_ttl_ms 5_000
  @timeout_ms 5_000
  @expiry_skew_ms 60_000
  @watch_wait_ms 25_000
  @watch_slack_ms 10_000
  @watch_idle_ms 600_000
  @capabilities "codex-meter-block-scopes"

  @type endpoint :: %{url: String.t(), token: String.t()}

  @type credential ::
          %{
            type: :oauth,
            access: String.t(),
            expires: integer(),
            project_id: String.t() | nil,
            enterprise_url: String.t() | nil
          }
          | %{type: :api_key, key: String.t(), source: String.t() | nil}

  @type entry :: %{
          id: integer(),
          provider: String.t(),
          identity_key: String.t() | nil,
          credential: credential(),
          blocks: [%{provider_key: String.t(), scope: String.t(), blocked_until_ms: integer()}]
        }

  @type snapshot :: %{
          generation: integer(),
          server_now_ms: integer(),
          fetched_at: integer(),
          entries: [entry()]
        }

  @type error ::
          :invalid_broker_url
          | :missing_broker_token
          | :broker_unreachable
          | :broker_unauthorized
          | :broker_not_found
          | :broker_http_error
          | :invalid_broker_response
          | :no_credential
          | :not_refreshable

  # ---------------------------------------------------------------------------
  # Cache owner
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Watchers are linked; trapping exits lets the owner reap them one by one.
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{watchers: %{}}}
  end

  @impl true
  def handle_call({:ensure_watcher, key, ctx}, _from, state) do
    existing = Map.get(state.watchers, key)

    if existing && match?([{_, ^existing, _}], :ets.lookup(@table, {:watcher, key})) do
      {:reply, :ok, state}
    else
      # A watcher that unregistered itself is on its way out.
      if existing, do: kill_watcher(existing)
      {:reply, :ok, %{state | watchers: Map.put(state.watchers, key, start_watcher(key, ctx))}}
    end
  end

  def handle_call(:stop_watchers, _from, state) do
    Enum.each(state.watchers, fn {_key, pid} -> kill_watcher(pid) end)
    :ets.match_delete(@table, {{:watcher, :_}, :_, :_})
    {:reply, :ok, %{state | watchers: %{}}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(state.watchers, fn {_key, watcher} -> watcher == pid end) do
      {key, _pid} ->
        :ets.match_delete(@table, {{:watcher, key}, pid, :_})
        {:noreply, %{state | watchers: Map.delete(state.watchers, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_watcher(key, ctx) do
    pid =
      spawn_link(fn ->
        # Req.Test stubs (and other caller-scoped lookups) follow the fetcher.
        Process.put(:"$callers", ctx.callers)

        receive do
          :registered -> watch_loop(key, ctx)
        end
      end)

    :ets.insert(@table, {{:watcher, key}, pid, System.monotonic_time(:millisecond)})
    send(pid, :registered)
    pid
  end

  defp kill_watcher(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end

  @doc "Drops every cached snapshot (all endpoints) and stops their watchers."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    stop_watchers()
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  defp stop_watchers do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :stop_watchers)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Unauthenticated liveness probe: `GET /v1/healthz`."
  @spec healthz(String.t(), keyword()) :: {:ok, %{version: String.t() | nil}} | {:error, error()}
  def healthz(url, opts \\ []) do
    with {:ok, url} <- normalize_url(url),
         {:ok, %{"ok" => true} = body} <- request(:get, url, nil, "/v1/healthz", opts) do
      {:ok, %{version: if(is_binary(body["version"]), do: body["version"])}}
    else
      {:ok, _} -> {:error, :invalid_broker_response}
      {:error, _} = error -> error
    end
  end

  @doc """
  The broker's redacted snapshot, from cache when fresh.

  Options: `fresh: true` bypasses the cache; `:req_options` and `:timeout_ms`
  tune the request.
  """
  @spec snapshot(endpoint(), keyword()) :: {:ok, snapshot()} | {:error, error()}
  def snapshot(endpoint, opts \\ []) do
    with {:ok, endpoint} <- normalize_endpoint(endpoint) do
      key = cache_key(endpoint)

      case if(Keyword.get(opts, :fresh, false), do: :miss, else: cached(key)) do
        {:hit, result} ->
          result

        :miss ->
          single_flight(key, fn ->
            # Another caller may have fetched while this one waited.
            case if(Keyword.get(opts, :fresh, false), do: :miss, else: cached(key)) do
              {:hit, result} -> result
              :miss -> fetch_snapshot(endpoint, key, opts)
            end
          end)
      end
    end
  end

  @doc """
  Every credential the broker holds for `provider`, in selection order (see
  `credential/3`), without refreshing any of them. `{:ok, []}` when there are
  none. Honours `:account`.
  """
  @spec credentials(endpoint(), String.t(), keyword()) :: {:ok, [entry()]} | {:error, error()}
  def credentials(endpoint, provider, opts \\ []) when is_binary(provider) do
    with {:ok, endpoint} <- normalize_endpoint(endpoint),
         {:ok, snapshot} <- snapshot(endpoint, opts) do
      {:ok, candidates(snapshot, provider, opts)}
    end
  end

  @doc """
  The credential the broker holds for `provider` (an omp provider id such as
  `"anthropic"` or `"openai-codex"`), with an OAuth access token that is not
  about to expire.

  Selection: with `account: identity_key`, only that OAuth identity; otherwise
  OAuth credentials before login API keys before other API keys (omp's order),
  unblocked before rate-limit-blocked, then by id. With `id: id`, exactly that
  entry (which must belong to `provider`). An expiring OAuth access token is
  refreshed through the broker first.
  """
  @spec credential(endpoint(), String.t(), keyword()) :: {:ok, entry()} | {:error, error()}
  def credential(endpoint, provider, opts \\ []) when is_binary(provider) do
    with {:ok, endpoint} <- normalize_endpoint(endpoint),
         {:ok, snapshot} <- snapshot(endpoint, opts),
         %{} = entry <- pick(snapshot, provider, opts) || {:error, :no_credential} do
      ensure_fresh(endpoint, snapshot, entry, opts)
    end
  end

  defp pick(snapshot, provider, opts) do
    case Keyword.get(opts, :id) do
      id when is_integer(id) ->
        Enum.find(snapshot.entries, &(&1.id == id and &1.provider == provider))

      _ ->
        select(snapshot, provider, opts)
    end
  end

  @doc """
  Reports a provider rate limit to the broker:
  `POST /v1/credential/:id/block` with the catch-all scope (`""`), which every
  request for `provider_key` honours. `blocked_until_ms` is wall-clock epoch
  milliseconds. On success the cached snapshot entry is updated too (same
  provider key and scope replaced, the later expiry kept), so the next
  `credentials/3` orders it last.
  """
  @spec block(endpoint(), integer(), String.t(), integer(), keyword()) :: :ok | {:error, error()}
  def block(endpoint, id, provider_key, blocked_until_ms, opts \\ [])
      when is_integer(id) and is_binary(provider_key) and provider_key != "" and
             is_integer(blocked_until_ms) do
    with {:ok, endpoint} <- normalize_endpoint(endpoint),
         {:ok, body} <-
           request(:post, endpoint.url, endpoint.token, "/v1/credential/#{id}/block", opts,
             json: %{
               "providerKey" => provider_key,
               "blockScope" => "",
               "blockedUntilMs" => blocked_until_ms
             }
           ) do
      case body do
        %{"ok" => true} ->
          store_block(cache_key(endpoint), id, provider_key, blocked_until_ms)

        _ ->
          {:error, :invalid_broker_response}
      end
    end
  end

  @doc """
  Asks the broker to refresh one OAuth credential:
  `POST /v1/credential/:id/refresh`. Pass `reason: "auth-recovery"` after the
  provider rejected the current access token. The cached snapshot is updated
  with the returned entry.
  """
  @spec refresh(endpoint(), integer(), keyword()) :: {:ok, entry()} | {:error, error()}
  def refresh(endpoint, id, opts \\ []) when is_integer(id) do
    with {:ok, endpoint} <- normalize_endpoint(endpoint) do
      key = cache_key(endpoint)

      path =
        case Keyword.get(opts, :reason) do
          "auth-recovery" -> "/v1/credential/#{id}/refresh?reason=auth-recovery"
          _ -> "/v1/credential/#{id}/refresh"
        end

      single_flight({key, :refresh, id}, fn ->
        with {:ok, %{"entry" => raw}} <- request(:post, endpoint.url, endpoint.token, path, opts),
             [entry] <- parse_entry(raw) do
          {:ok, store_refreshed(key, entry)}
        else
          {:ok, _} -> {:error, :invalid_broker_response}
          [] -> {:error, :invalid_broker_response}
          {:error, _} = error -> error
        end
      end)
    end
  end

  @doc """
  Picks the credential for `provider` from a snapshot (see `credential/3`), or
  `nil`. Pure; exposed for diagnostics and tests.
  """
  @spec select(snapshot(), String.t(), keyword()) :: entry() | nil
  def select(snapshot, provider, opts \\ []) do
    snapshot |> candidates(provider, opts) |> List.first()
  end

  @doc """
  The `providerKey` the broker uses for blocks on an entry:
  `"<provider>:oauth"` or `"<provider>:api_key"` (omp's provider type key).
  """
  @spec provider_key(entry()) :: String.t()
  def provider_key(%{provider: provider, credential: %{type: :oauth}}), do: provider <> ":oauth"

  def provider_key(%{provider: provider, credential: %{type: :api_key}}),
    do: provider <> ":api_key"

  # Every entry for `provider`, in selection order.
  defp candidates(%{entries: entries} = snapshot, provider, opts) do
    now = server_now(snapshot)

    filtered =
      case Keyword.get(opts, :account) do
        account when is_binary(account) and account != "" ->
          Enum.filter(entries, fn entry ->
            entry.provider == provider and entry.credential.type == :oauth and
              entry.identity_key == account
          end)

        _ ->
          Enum.filter(entries, &(&1.provider == provider))
      end

    Enum.sort_by(filtered, fn entry ->
      {type_rank(entry.credential), blocked?(entry, now), entry.id}
    end)
  end

  @doc "The usable secret of an entry: the OAuth access token or the API key."
  @spec secret(entry()) :: String.t()
  def secret(%{credential: %{type: :oauth, access: access}}), do: access
  def secret(%{credential: %{type: :api_key, key: key}}), do: key

  @doc "Credential-free operator guidance for an error reason."
  @spec error_message(error() | term()) :: String.t()
  def error_message(:invalid_broker_url),
    do: "the omp auth broker URL must be an http(s) URL without credentials, query or fragment."

  def error_message(:missing_broker_token),
    do:
      "no omp auth broker token: set OMP_AUTH_BROKER_TOKEN or run `omp auth-broker token` on this host."

  def error_message(:broker_unreachable),
    do:
      "the omp auth broker is unreachable; check `omp auth-broker serve` and OMP_AUTH_BROKER_URL."

  def error_message(:broker_unauthorized),
    do: "the omp auth broker rejected the bearer token; check OMP_AUTH_BROKER_TOKEN."

  def error_message(:no_credential),
    do:
      "the omp auth broker holds no matching credential; run `omp auth-broker login <provider>`."

  def error_message(:not_refreshable),
    do: "the omp auth broker credential is an API key and cannot be refreshed."

  def error_message(_), do: "the omp auth broker returned an unexpected response."

  # ---------------------------------------------------------------------------
  # Snapshot fetch and cache
  # ---------------------------------------------------------------------------

  defp fetch_snapshot(endpoint, key, opts) do
    result =
      with {:ok, body} <- request(:get, endpoint.url, endpoint.token, "/v1/snapshot", opts) do
        parse_snapshot(body)
      end

    cache_put(key, result)
    if match?({:ok, _}, result), do: ensure_watcher(endpoint, key, opts)
    result
  end

  # A snapshot is served while it is younger than the TTL, or for as long as
  # its watcher is healthy (reading also marks the endpoint as in use).
  defp cached(key) do
    if table?() do
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, key) do
        [{^key, {:ok, _} = result, stored_at}] ->
          watched? = :ets.update_element(@table, {:watcher, key}, {3, now})

          if watched? or now - stored_at < @snapshot_ttl_ms,
            do: {:hit, result},
            else: :miss

        [{^key, {:error, _} = result, stored_at}] when now - stored_at < @failure_ttl_ms ->
          {:hit, result}

        _ ->
          :miss
      end
    else
      :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(key, result) do
    if table?(), do: :ets.insert(@table, {key, result, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # A refresh response carries no rate-limit blocks; keep the cached ones.
  defp store_refreshed(key, entry) do
    with true <- table?(),
         [{^key, {:ok, snapshot}, stored_at}] <- :ets.lookup(@table, key) do
      existing = Enum.find(snapshot.entries, &(&1.id == entry.id))
      entry = %{entry | blocks: if(existing, do: existing.blocks, else: [])}
      others = Enum.reject(snapshot.entries, &(&1.id == entry.id))
      updated = %{snapshot | entries: Enum.sort_by([entry | others], & &1.id)}

      :ets.insert(@table, {key, {:ok, updated}, stored_at})
      entry
    else
      _ -> entry
    end
  rescue
    ArgumentError -> entry
  end

  # Applies a block the broker just accepted to the cached entry, so the next
  # `credentials/3` sorts it last without another snapshot fetch.
  defp store_block(key, id, provider_key, blocked_until_ms) do
    with true <- table?(),
         [{^key, {:ok, snapshot}, stored_at}] <- :ets.lookup(@table, key) do
      entries =
        Enum.map(snapshot.entries, fn
          %{id: ^id} = entry ->
            %{entry | blocks: merge_block(entry.blocks, provider_key, blocked_until_ms)}

          entry ->
            entry
        end)

      :ets.insert(@table, {key, {:ok, %{snapshot | entries: entries}}, stored_at})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Replaces the catch-all block for `provider_key`, keeping the later expiry.
  defp merge_block(blocks, provider_key, blocked_until_ms) do
    {same, others} =
      Enum.split_with(blocks, &(&1.provider_key == provider_key and &1.scope == ""))

    until = Enum.max([blocked_until_ms | Enum.map(same, & &1.blocked_until_ms)])
    [%{provider_key: provider_key, scope: "", blocked_until_ms: until} | others]
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp cache_key(endpoint),
    do: {endpoint.url, :crypto.hash(:sha256, endpoint.token)}

  defp single_flight(key, fun) do
    :global.trans({{__MODULE__, key}, self()}, fun, [node()])
  end

  # ---------------------------------------------------------------------------
  # Snapshot watcher
  #
  # One process per cache key, owned (linked) by the cache owner, so a
  # restarted owner never leaves watchers behind. ETS row
  # `{{:watcher, key}, pid, last_read_monotonic_ms}` marks a healthy watcher.
  # ---------------------------------------------------------------------------

  defp ensure_watcher(endpoint, key, opts) do
    if watch_enabled?(opts) and table?() and :ets.lookup(@table, {:watcher, key}) == [] do
      ctx = %{
        endpoint: endpoint,
        req_options: Keyword.get(opts, :req_options, []),
        wait_ms: positive(opts[:watch_wait_ms], @watch_wait_ms),
        idle_ms: positive(opts[:watch_idle_ms], @watch_idle_ms),
        callers: [self() | Process.get(:"$callers") || []]
      }

      GenServer.call(__MODULE__, {:ensure_watcher, key, ctx})
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp watch_enabled?(opts) do
    case Keyword.get(opts, :watch) do
      value when is_boolean(value) -> value
      _ -> Application.get_env(:lemon_ai, :omp_broker_watch, true)
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp watch_loop(key, ctx) do
    with {:ok, generation} <- watch_generation(key),
         :ok <- watch_active(key, ctx.idle_ms) do
      started = System.monotonic_time(:millisecond)

      case watch_apply(key, watch_poll(ctx, generation), generation) do
        :changed ->
          watch_loop(key, ctx)

        :unchanged ->
          pace(started, ctx.wait_ms)
          watch_loop(key, ctx)

        :stop ->
          watch_stop(key)
      end
    else
      _ -> watch_stop(key)
    end
  end

  defp watch_poll(ctx, generation) do
    request(
      :get,
      ctx.endpoint.url,
      ctx.endpoint.token,
      "/v1/snapshot?wait=#{ctx.wait_ms}",
      [req_options: ctx.req_options, timeout_ms: ctx.wait_ms + @watch_slack_ms],
      headers: [{"if-none-match", ~s("#{generation}")}]
    )
  end

  # 304 (or an older broker answering immediately with the same generation):
  # the cached snapshot is still current.
  defp watch_apply(key, {:ok, :not_modified}, _generation), do: watch_touch(key)

  defp watch_apply(key, {:ok, body}, generation) when is_map(body) do
    case parse_snapshot(body) do
      {:ok, %{generation: ^generation}} -> watch_touch(key)
      {:ok, snapshot} -> watch_replace(key, snapshot)
      {:error, _} -> :stop
    end
  end

  defp watch_apply(_key, {:error, _}, _generation), do: :stop

  defp watch_generation(key) do
    case :ets.lookup(@table, key) do
      [{^key, {:ok, %{generation: generation}}, _}] -> {:ok, generation}
      _ -> :no_snapshot
    end
  end

  defp watch_active(key, idle_ms) do
    case :ets.lookup(@table, {:watcher, key}) do
      [{_, _, last_read}] ->
        if System.monotonic_time(:millisecond) - last_read <= idle_ms, do: :ok, else: :idle

      [] ->
        :unregistered
    end
  end

  defp watch_touch(key) do
    if :ets.update_element(@table, key, {3, System.monotonic_time(:millisecond)}),
      do: :unchanged,
      else: :stop
  end

  # A long-poll 200 is authoritative and newer: it replaces the cache wholesale.
  defp watch_replace(key, snapshot) do
    case :ets.lookup(@table, key) do
      [{^key, {:ok, _}, _}] ->
        :ets.insert(@table, {key, {:ok, snapshot}, System.monotonic_time(:millisecond)})
        :changed

      _ ->
        :stop
    end
  end

  # Guards against a hot loop when the broker ignores `wait`.
  defp pace(started, wait_ms) do
    floor = min(wait_ms, 1_000)
    elapsed = System.monotonic_time(:millisecond) - started
    if elapsed < floor, do: Process.sleep(floor - elapsed)
  end

  defp watch_stop(key) do
    :ets.match_delete(@table, {{:watcher, key}, self(), :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Selection and expiry
  # ---------------------------------------------------------------------------

  defp ensure_fresh(endpoint, snapshot, %{credential: %{type: :oauth}} = entry, opts) do
    now = server_now(snapshot)

    if entry.credential.expires > now + @expiry_skew_ms do
      {:ok, entry}
    else
      case refresh(endpoint, entry.id, Keyword.delete(opts, :reason)) do
        {:ok, refreshed} ->
          {:ok, refreshed}

        # A refresh failure does not discard a token that still works.
        {:error, _} when entry.credential.expires > now ->
          {:ok, entry}

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_fresh(_endpoint, _snapshot, entry, _opts), do: {:ok, entry}

  defp server_now(%{server_now_ms: server_now, fetched_at: fetched_at}),
    do: server_now + (System.monotonic_time(:millisecond) - fetched_at)

  defp type_rank(%{type: :oauth}), do: 0
  defp type_rank(%{type: :api_key, source: "login"}), do: 1
  defp type_rank(_), do: 2

  defp blocked?(%{blocks: blocks}, now),
    do: Enum.any?(blocks, &(&1.blocked_until_ms > now))

  # ---------------------------------------------------------------------------
  # Wire parsing
  # ---------------------------------------------------------------------------

  defp parse_snapshot(%{"credentials" => credentials} = body) when is_list(credentials) do
    {:ok,
     %{
       generation: integer(body["generation"]) || 0,
       server_now_ms: integer(body["serverNowMs"]) || System.system_time(:millisecond),
       fetched_at: System.monotonic_time(:millisecond),
       entries: credentials |> Enum.flat_map(&parse_entry/1) |> Enum.sort_by(& &1.id)
     }}
  end

  defp parse_snapshot(_), do: {:error, :invalid_broker_response}

  defp parse_entry(%{"id" => id, "provider" => provider, "credential" => raw} = entry)
       when is_integer(id) and is_binary(provider) and provider != "" do
    case parse_credential(raw) do
      nil ->
        []

      credential ->
        [
          %{
            id: id,
            provider: provider,
            identity_key: string(entry["identityKey"]),
            credential: credential,
            blocks: parse_blocks(entry["blocks"])
          }
        ]
    end
  end

  defp parse_entry(_), do: []

  # Only the fields Lemon uses are kept; the redacted refresh sentinel and
  # account metadata are dropped.
  defp parse_credential(%{"type" => "oauth", "access" => access} = raw) do
    with access when is_binary(access) <- string(access),
         expires when is_integer(expires) <- integer(raw["expires"]) do
      %{
        type: :oauth,
        access: access,
        expires: expires,
        project_id: string(raw["projectId"]),
        enterprise_url: string(raw["enterpriseUrl"])
      }
    else
      _ -> nil
    end
  end

  defp parse_credential(%{"type" => "api_key", "key" => key} = raw) do
    case string(key) do
      nil -> nil
      key -> %{type: :api_key, key: key, source: string(raw["source"])}
    end
  end

  defp parse_credential(_), do: nil

  defp parse_blocks(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn
      %{"providerKey" => provider_key, "blockScope" => scope, "blockedUntilMs" => until}
      when is_binary(provider_key) and is_binary(scope) and is_number(until) ->
        [%{provider_key: provider_key, scope: scope, blocked_until_ms: trunc(until)}]

      _ ->
        []
    end)
  end

  defp parse_blocks(_), do: []

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_), do: nil

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp normalize_endpoint(%{url: url, token: token}) do
    with {:ok, url} <- normalize_url(url) do
      case token do
        token when is_binary(token) and token != "" -> {:ok, %{url: url, token: token}}
        _ -> {:error, :missing_broker_token}
      end
    end
  end

  defp normalize_endpoint(_), do: {:error, :invalid_broker_url}

  defp normalize_url(url) when is_binary(url) do
    trimmed = url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, trimmed}

      _ ->
        {:error, :invalid_broker_url}
    end
  end

  defp normalize_url(_), do: {:error, :invalid_broker_url}

  # `extra` carries per-call extras: `:json` (request body) and `:headers`.
  defp request(method, url, token, path, opts, extra \\ []) do
    timeout =
      case Keyword.get(opts, :timeout_ms) do
        value when is_integer(value) and value > 0 -> value
        _ -> @timeout_ms
      end

    headers =
      [{"accept", "application/json"}, {"omp-auth-broker-capabilities", @capabilities}] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: []) ++
        Keyword.get(extra, :headers, [])

    request_opts =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        method: method,
        url: url <> path,
        headers: headers,
        connect_options: [timeout: timeout],
        receive_timeout: timeout,
        retry: false,
        redirect: false
      )
      |> Keyword.merge(Keyword.take(extra, [:json]))

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode(body)

      # Only a conditional long-poll (`If-None-Match`) can produce this.
      {:ok, %Req.Response{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :broker_unauthorized}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :broker_not_found}

      {:ok, %Req.Response{}} ->
        {:error, :broker_http_error}

      {:error, _reason} ->
        {:error, :broker_unreachable}
    end
  rescue
    _ -> {:error, :broker_unreachable}
  catch
    :exit, _ -> {:error, :broker_unreachable}
  end

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_broker_response}
    end
  end

  defp decode(_), do: {:error, :invalid_broker_response}
end
