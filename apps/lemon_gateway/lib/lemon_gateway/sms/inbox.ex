defmodule LemonGateway.Sms.Inbox do
  @moduledoc """
  GenServer that stores and queries inbound SMS messages.

  Ingests Twilio SMS webhook payloads, extracts verification codes (4-8 digit
  sequences), and supports filtering, claiming, and waiting for incoming codes.
  Expired messages are periodically cleaned up based on a configurable TTL.
  Custom code patterns compile once per waiter and use a bounded match budget.
  Exhaustion replies `{:error, :regex_match_limit}` without claiming the message
  or silently substituting the default code matcher.

  ## Session reservations

  The inbox number is shared, so agent sessions take an exclusive, server-side
  lease on it before using it. Every session call (`reserve/1`,
  `list_session_messages/2`, `wait_for_code/2`, `claim_message/2`) takes the
  lease, or reuses it if the caller already holds it; while another session is
  bound to the number the call returns `{:error, :inbox_reserved}` with no
  content. The lease is persisted and does not expire: the number stays bound
  to its holder, across runs and restarts, until one of:

    * the holder calls `release/1` (`sms_release_inbox`); the number then stays
      bound to it for a further handoff grace period (`[gateway.sms]
      handoff_grace_ms`, default ten minutes, never zero) so its late texts are
      not handed on, and the holder may re-reserve at any time; or
    * an operator clears it with `preview_clear/0` then `confirm_clear/2`
      (control-plane `sms.inbox.clear`), bound to the exact holder and lease.
      The number is free at once; a text for the previous holder arriving after
      another session reserves goes to that session. This is the accepted cost
      of a forced clear.

  A shared number gives ownership only through explicit release. It cannot
  prove which flow a text belongs to; session-specific numbers are needed for
  stronger isolation.

  A message is bound to the session the number is bound to when it arrives,
  recorded server-side as `reserved_for`. Only that session can ever list, wait
  for or claim it; a message arriving while the number is unbound (or when the
  lease cannot be read) is visible to no session. Stored lookups and live
  waiters apply the same ownership and `:since_ms` predicate. Ingestion is an
  atomic insert-if-absent keyed by MessageSid: a replayed delivery never
  overwrites the stored record or its claim and is never offered again; a store
  failure is reported as `{:error, :store_unavailable}`. Lease reads are strict,
  so a store failure refuses the lease rather than granting it.
  `list_messages/1` is the unscoped operator view.
  """

  use GenServer

  require Logger

  alias LemonGateway.Sms.{Config, InboxStore}

  @cleanup_interval_ms 10 * 60 * 1000
  @max_wait_ms 10 * 60 * 1000
  @default_wait_ms 60_000
  @clear_token_ttl_ms 5 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The longest a single `wait_for_code/2` may block."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @spec ingest_twilio_sms(map()) :: {:ok, :stored | :duplicate} | {:error, term()}
  def ingest_twilio_sms(params) when is_map(params) do
    GenServer.call(__MODULE__, {:ingest_twilio_sms, params})
  end

  @doc "Unscoped operator view of the inbox. Agent tools use `list_session_messages/2`."
  @spec list_messages(keyword()) :: [map()]
  def list_messages(opts \\ []) when is_list(opts) do
    GenServer.call(__MODULE__, {:list_messages, opts})
  end

  @doc "Takes the exclusive inbox lease for `session_key`, or reuses its own."
  @spec reserve(binary()) :: :ok | {:error, term()}
  def reserve(session_key) when is_binary(session_key) and session_key != "",
    do: GenServer.call(__MODULE__, {:reserve, session_key})

  def reserve(_session_key), do: {:error, :missing_session_key}

  @doc """
  Releases the lease if `session_key` holds it. The number stays bound to the
  releasing session for the handoff grace period.
  """
  @spec release(binary()) :: :ok | {:error, term()}
  def release(session_key) when is_binary(session_key) and session_key != "",
    do: GenServer.call(__MODULE__, {:release, session_key})

  def release(_session_key), do: {:error, :missing_session_key}

  @doc """
  Operator preview of a forced clear. Returns the current holder and a
  single-use, server-side token bound to that holder and lease (by its random id).
  """
  @spec preview_clear() ::
          {:ok, %{holder: binary() | nil, released: boolean(), confirm_token: binary() | nil}}
          | {:error, term()}
  def preview_clear, do: GenServer.call(__MODULE__, :preview_clear)

  @doc """
  Clears the lease previewed with `confirm_token`, only if `holder` and the lease
  are unchanged since the preview. The number is free immediately.
  """
  @spec confirm_clear(binary(), binary()) :: :ok | {:error, term()}
  def confirm_clear(holder, confirm_token) when is_binary(holder) and is_binary(confirm_token),
    do: GenServer.call(__MODULE__, {:confirm_clear, holder, confirm_token})

  def confirm_clear(_holder, _confirm_token), do: {:error, :confirmation_required}

  @doc """
  Lists messages bound to `session_key` (claimed or not). Takes or renews the
  lease; another session's lease gives `{:error, :inbox_reserved}`.
  """
  @spec list_session_messages(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_session_messages(session_key, opts \\ [])

  def list_session_messages(session_key, opts)
      when is_binary(session_key) and session_key != "" and is_list(opts) do
    GenServer.call(__MODULE__, {:list_session_messages, session_key, opts})
  end

  def list_session_messages(_session_key, _opts), do: {:error, :missing_session_key}

  @doc """
  Waits for an unclaimed code bound to `session_key`, newest first, at or after
  `:since_ms` when given. Takes the lease; `:timeout_ms` is capped at `max_wait_ms/0`.
  """
  @spec wait_for_code(binary(), keyword()) ::
          {:ok, %{code: binary(), message: map()}} | {:error, :timeout} | {:error, term()}
  def wait_for_code(session_key, opts \\ [])

  def wait_for_code(session_key, opts)
      when is_binary(session_key) and session_key != "" and is_list(opts) do
    timeout_ms = wait_timeout(Keyword.get(opts, :timeout_ms))
    opts = Keyword.put(opts, :timeout_ms, timeout_ms)

    # Call timeout must exceed tool wait timeout slightly so we can reply cleanly.
    GenServer.call(__MODULE__, {:wait_for_code, session_key, opts}, timeout_ms + 1_500)
  end

  def wait_for_code(_session_key, _opts), do: {:error, :missing_session_key}

  @doc """
  Claims a message bound to `session_key`. Messages bound to no session or to
  another session report `:not_found`.
  """
  @spec claim_message(binary(), binary()) :: :ok | {:error, term()}
  def claim_message(session_key, message_sid)
      when is_binary(session_key) and session_key != "" and is_binary(message_sid) do
    GenServer.call(__MODULE__, {:claim_message, session_key, message_sid})
  end

  def claim_message(_session_key, _message_sid), do: {:error, :missing_session_key}

  def inbox_number do
    Config.inbox_number()
  end

  @doc """
  Whether agent SMS tools can work: SMS config is usable (webhook enabled, auth
  token present) and both this inbox and the webhook listener are running.
  """
  @spec available?() :: boolean()
  def available? do
    is_pid(Process.whereis(__MODULE__)) and
      is_pid(Process.whereis(LemonGateway.Sms.WebhookServer)) and Config.usable?()
  end

  @doc "Model-facing text for a session-call error; never names the lease holder."
  @spec error_text(term()) :: String.t()
  def error_text(:inbox_reserved),
    do: "The SMS inbox is reserved by another session. Try again later."

  def error_text(:missing_session_key), do: "SMS tools require a session key (internal)."
  def error_text(:not_found), do: "Message not found."
  def error_text(:timeout), do: "Timed out waiting for an SMS code."
  def error_text(reason), do: "SMS inbox request failed: #{inspect(reason)}"

  @impl true
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{waiters: %{}, clear_tokens: %{}}}
  end

  @impl true
  def handle_call({:ingest_twilio_sms, params}, _from, state) do
    case normalize_twilio_sms(params) do
      {:ok, msg} ->
        # A failed lease read leaves the text unattributed (visible to no session).
        holder =
          case bound_holder(now_ms()) do
            {:ok, holder} -> holder
            {:error, _} -> nil
          end

        msg = Map.put(msg, "reserved_for", holder)

        # Atomic insert-if-absent: a replayed MessageSid never overwrites the
        # stored record or its claim, and is never offered to waiters again.
        case InboxStore.put_new(msg["message_sid"], msg) do
          :ok ->
            {:reply, {:ok, :stored}, fulfill_waiters(msg, state)}

          {:error, :exists} ->
            {:reply, {:ok, :duplicate}, state}

          {:error, _reason} ->
            {:reply, {:error, :store_unavailable}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    e -> {:reply, {:error, {:exception, Exception.message(e)}}, state}
  end

  def handle_call({:list_messages, opts}, _from, state) do
    {:reply, filter_messages(read_all_messages(), opts, nil), state}
  rescue
    e ->
      Logger.warning("Sms.Inbox list_messages failed: #{Exception.message(e)}")
      {:reply, [], state}
  end

  def handle_call({:reserve, session_key}, _from, state) do
    {:reply, take_lease(session_key), state}
  end

  # Release marks the lease released; the number stays bound to the releasing
  # session for the handoff grace period, so its late texts are never handed on.
  def handle_call({:release, session_key}, _from, state) do
    now = now_ms()

    with {:ok, lease} <- InboxStore.fetch_reservation() do
      case lease do
        %{"session_key" => ^session_key, "released_at_ms" => nil} ->
          :ok = InboxStore.put_reservation(%{lease | "released_at_ms" => now})
          {:reply, :ok, state}

        _ ->
          if lease_owner(lease, now) in [nil, session_key],
            do: {:reply, :ok, state},
            else: {:reply, {:error, :inbox_reserved}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:preview_clear, _from, state) do
    now = now_ms()
    state = prune_clear_tokens(state, now)

    with {:ok, lease} <- InboxStore.fetch_reservation() do
      case lease do
        %{"session_key" => holder} when is_binary(holder) ->
          token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

          entry = %{
            holder: holder,
            lease_id: lease["lease_id"],
            expires_at_ms: now + @clear_token_ttl_ms
          }

          {:reply,
           {:ok,
            %{
              holder: holder,
              released: is_integer(lease["released_at_ms"]),
              confirm_token: token
            }}, %{state | clear_tokens: Map.put(state.clear_tokens, token, entry)}}

        _ ->
          {:reply, {:ok, %{holder: nil, released: false, confirm_token: nil}}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:confirm_clear, holder, token}, _from, state) do
    now = now_ms()
    state = prune_clear_tokens(state, now)
    {entry, tokens} = Map.pop(state.clear_tokens, token)
    state = %{state | clear_tokens: tokens}

    with %{holder: ^holder, lease_id: lease_id} <- entry,
         {:ok, %{"session_key" => ^holder} = lease} <- InboxStore.fetch_reservation(),
         true <- lease["lease_id"] == lease_id do
      :ok = InboxStore.delete_reservation()
      Logger.warning("SMS inbox reservation cleared by operator")
      {:reply, :ok, state}
    else
      nil -> {:reply, {:error, :confirmation_required}, state}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :confirmation_mismatch}, state}
    end
  end

  def handle_call({:list_session_messages, session_key, opts}, _from, state) do
    with :ok <- take_lease(session_key) do
      opts = Keyword.put(opts, :include_claimed, true)
      {:reply, {:ok, filter_messages(read_all_messages(), opts, session_key)}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:claim_message, session_key, message_sid}, _from, state) do
    with :ok <- take_lease(session_key) do
      case InboxStore.fetch(message_sid) do
        {:error, _} = error ->
          {:reply, error, state}

        {:ok, %{"reserved_for" => ^session_key} = msg} ->
          if msg["claimed_by"] != session_key do
            :ok = InboxStore.put(message_sid, mark_claimed(msg, session_key))
          end

          {:reply, :ok, state}

        {:ok, _} ->
          {:reply, {:error, :not_found}, state}
      end
    else
      error -> {:reply, error, state}
    end
  rescue
    _ -> {:reply, {:error, :claim_failed}, state}
  end

  def handle_call({:wait_for_code, session_key, opts}, from, state) do
    opts = normalize_wait_opts(opts)

    with :ok <- take_lease(session_key) do
      opts = Keyword.put(opts, :regex, compile_code_regex(opts[:regex]))

      case find_matching_code_message(session_key, opts) do
        {:ok, %{code: code, message: msg}} ->
          msg = maybe_claim_and_persist(msg, session_key, opts)
          {:reply, {:ok, %{code: code, message: msg}}, state}

        {:error, _} = error ->
          {:reply, error, state}

        :miss ->
          {:noreply, add_waiter(state, from, session_key, opts)}
      end
    else
      error -> {:reply, error, state}
    end
  rescue
    Regex.CompileError -> {:reply, {:error, :invalid_regex}, state}
    e -> {:reply, {:error, {:exception, Exception.message(e)}}, state}
  end

  @impl true
  def handle_info({:wait_timeout, waiter_id}, state) do
    case Map.pop(state.waiters, waiter_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {%{from: from, mon_ref: mon_ref} = waiter, waiters} ->
        _ = Process.demonitor(mon_ref, [:flush])
        _ = cancel_timer(waiter[:timer_ref])
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    # Caller went away; drop any waiter entry that references this monitor.
    waiters =
      state.waiters
      |> Enum.reject(fn {_id, w} -> w.mon_ref == mon_ref end)
      |> Map.new()

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(:cleanup, state) do
    _ = cleanup_expired_messages()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Reservations -----------------------------------------------------------

  # Bound until explicitly released (then for the handoff grace period) or
  # cleared by an operator. Expiry never hands the number to another session.
  defp bound_holder(now) do
    with {:ok, lease} <- InboxStore.fetch_reservation(), do: {:ok, lease_owner(lease, now)}
  end

  defp lease_owner(%{"session_key" => holder, "released_at_ms" => nil}, _now)
       when is_binary(holder),
       do: holder

  defp lease_owner(%{"session_key" => holder, "released_at_ms" => released}, now)
       when is_binary(holder) and is_integer(released) do
    if now < released + Config.handoff_grace_ms(), do: holder, else: nil
  end

  # Unknown lease shapes stay bound to their holder rather than freeing the number.
  defp lease_owner(%{"session_key" => holder}, _now) when is_binary(holder), do: holder
  defp lease_owner(_lease, _now), do: nil

  # Takes a free lease or reuses the caller's own (re-reserving within its own
  # grace period). A store read failure refuses the lease.
  defp take_lease(session_key) do
    with {:ok, lease} <- InboxStore.fetch_reservation() do
      case {lease_owner(lease, now_ms()), lease} do
        {^session_key, %{"released_at_ms" => nil}} ->
          :ok

        {owner, _lease} when owner in [nil, session_key] ->
          # A fresh random id per acquisition: a stale clear preview can never
          # match a later lease, even for the same holder.
          InboxStore.put_reservation(%{
            "session_key" => session_key,
            "released_at_ms" => nil,
            "lease_id" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
          })

        _other ->
          {:error, :inbox_reserved}
      end
    end
  end

  defp prune_clear_tokens(state, now) do
    tokens =
      for {t, %{expires_at_ms: e} = entry} <- state.clear_tokens,
          e > now,
          into: %{},
          do: {t, entry}

    %{state | clear_tokens: tokens}
  end

  # -- Matching ---------------------------------------------------------------

  defp normalize_twilio_sms(params) when is_map(params) do
    sid =
      params["MessageSid"] || params["SmsMessageSid"] || params[:MessageSid] ||
        params[:SmsMessageSid]

    body = params["Body"] || params[:Body] || ""
    to = params["To"] || params[:To]
    from = params["From"] || params[:From]
    account_sid = params["AccountSid"] || params[:AccountSid]

    if not is_binary(sid) or String.trim(sid) == "" do
      {:error, :missing_message_sid}
    else
      body = body |> to_string() |> String.trim()

      {:ok,
       %{
         "message_sid" => String.trim(sid),
         "account_sid" => account_sid && to_string(account_sid),
         "to" => to && to_string(to),
         "from" => from && to_string(from),
         "body" => body,
         "codes" => extract_default_codes(body),
         "received_at_ms" => now_ms(),
         "claimed_by" => nil,
         "claimed_at_ms" => nil,
         "raw" => LemonCore.MapHelpers.stringify_keys(params)
       }}
    end
  end

  defp extract_default_codes(body) when is_binary(body) do
    Regex.scan(~r/\b\d{4,8}\b/, body)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp extract_default_codes(_), do: []

  defp read_all_messages do
    InboxStore.list()
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.filter(&is_map/1)
  end

  # `owner` nil is the operator view; otherwise only messages bound to `owner`.
  defp filter_messages(messages, opts, owner) do
    include_claimed = Keyword.get(opts, :include_claimed, false)
    limit = Keyword.get(opts, :limit, 20)

    messages
    |> Enum.sort_by(&(&1["received_at_ms"] || 0), :desc)
    |> Enum.filter(fn msg ->
      (owner == nil or owned_by?(msg, owner)) and (include_claimed or not claimed?(msg)) and
        matches_filters?(msg, opts)
    end)
    |> Enum.take(max(limit, 0))
  end

  defp owned_by?(msg, session_key), do: msg["reserved_for"] == session_key

  defp claimed?(msg), do: is_binary(msg["claimed_by"]) and msg["claimed_by"] != ""

  defp matches_filters?(msg, opts) do
    since_ms = opts[:since_ms]
    to = opts[:to]
    from_contains = opts[:from_contains]
    body_contains = opts[:body_contains]

    cond do
      is_integer(since_ms) and (msg["received_at_ms"] || 0) < since_ms ->
        false

      is_binary(to) and to != "" and msg["to"] != to ->
        false

      is_binary(from_contains) and from_contains != "" and
          not contains_ci?(msg["from"] || "", from_contains) ->
        false

      is_binary(body_contains) and body_contains != "" and
          not String.contains?(msg["body"] || "", body_contains) ->
        false

      true ->
        true
    end
  end

  defp wait_timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_wait_ms)
  defp wait_timeout(_ms), do: @default_wait_ms

  defp normalize_wait_opts(opts) do
    [
      timeout_ms: wait_timeout(Keyword.get(opts, :timeout_ms)),
      since_ms: Keyword.get(opts, :since_ms),
      to: Keyword.get(opts, :to) || Config.inbox_number(),
      from_contains: Keyword.get(opts, :from_contains),
      body_contains: Keyword.get(opts, :body_contains),
      regex: Keyword.get(opts, :regex),
      claim: Keyword.get(opts, :claim, true)
    ]
  end

  defp find_matching_code_message(session_key, opts) do
    read_all_messages()
    |> Enum.sort_by(&(&1["received_at_ms"] || 0), :desc)
    |> Enum.find_value(:miss, &match_code(&1, session_key, opts))
    |> case do
      %{code: _c, message: _m} = hit -> {:ok, hit}
      {:error, _} = error -> error
      _ -> :miss
    end
  end

  # One predicate for stored lookups and live waiters: bound to this session,
  # unclaimed, inside `:since_ms` and the caller's filters, carrying a code.
  defp match_code(msg, session_key, opts) when is_map(msg) do
    if owned_by?(msg, session_key) and not claimed?(msg) and matches_filters?(msg, opts) do
      case extract_code(msg["body"] || "", opts[:regex]) do
        {:error, _} = error -> error
        code when is_binary(code) and code != "" -> %{code: code, message: msg}
        _ -> false
      end
    else
      false
    end
  end

  defp compile_code_regex(regex) when is_binary(regex), do: Regex.compile!(regex)
  defp compile_code_regex(_), do: nil

  defp extract_code(body, nil) do
    List.first(extract_default_codes(body))
  end

  defp extract_code(body, %Regex{} = regex) do
    case :re.run(body, Regex.re_pattern(regex), [
           {:capture, :first, :binary},
           {:match_limit, 50_000},
           {:match_limit_recursion, 5_000},
           :report_errors
         ]) do
      {:match, [match | _]} -> match
      :nomatch -> nil
      {:error, _} -> {:error, :regex_match_limit}
    end
  rescue
    SystemLimitError -> {:error, :regex_match_limit}
  end

  defp mark_claimed(msg, session_key) do
    msg
    |> Map.put("claimed_by", session_key)
    |> Map.put("claimed_at_ms", now_ms())
  end

  defp maybe_claim_and_persist(%{} = msg, session_key, opts) do
    if opts[:claim] == true do
      updated = mark_claimed(msg, session_key)
      :ok = InboxStore.put(updated["message_sid"], updated)
      updated
    else
      msg
    end
  end

  defp add_waiter(state, from, session_key, opts) do
    waiter_id = LemonCore.Id.run_id()
    caller_pid = elem(from, 0)

    waiter = %{
      id: waiter_id,
      from: from,
      caller_pid: caller_pid,
      mon_ref: Process.monitor(caller_pid),
      timer_ref: Process.send_after(self(), {:wait_timeout, waiter_id}, opts[:timeout_ms]),
      session_key: session_key,
      opts: opts
    }

    %{state | waiters: Map.put(state.waiters, waiter_id, waiter)}
  end

  defp fulfill_waiters(msg, state) do
    # Failed patterns are retired and cannot prevent another waiter receiving this SMS.
    Enum.reduce_while(Map.values(state.waiters), state, fn waiter, state ->
      case match_code(msg, waiter.session_key, waiter.opts) do
        false ->
          {:cont, state}

        {:error, _} = error ->
          GenServer.reply(waiter.from, error)
          {:cont, remove_waiter(state, waiter)}

        %{code: code} ->
          claimed = maybe_claim_and_persist(msg, waiter.session_key, waiter.opts)
          GenServer.reply(waiter.from, {:ok, %{code: code, message: claimed}})
          {:halt, remove_waiter(state, waiter)}
      end
    end)
  rescue
    _ -> state
  end

  defp remove_waiter(state, waiter) do
    _ = cancel_timer(waiter.timer_ref)
    _ = Process.demonitor(waiter.mon_ref, [:flush])
    %{state | waiters: Map.delete(state.waiters, waiter.id)}
  end

  defp cleanup_expired_messages do
    cutoff = now_ms() - Config.inbox_ttl_ms()

    read_all_messages()
    |> Enum.reduce(0, fn msg, acc ->
      sid = msg["message_sid"]

      if is_binary(sid) and (msg["received_at_ms"] || 0) < cutoff do
        _ = InboxStore.delete(sid)
        acc + 1
      else
        acc
      end
    end)
  rescue
    _ -> 0
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  rescue
    _ -> :ok
  end

  defp contains_ci?(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    String.contains?(String.downcase(haystack), String.downcase(needle))
  end

  defp contains_ci?(_, _), do: false

  defp now_ms do
    System.system_time(:millisecond)
  end
end
