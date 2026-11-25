defmodule LemonAi.Providers.KimiCodeRanking do
  @moduledoc """
  Orders several Kimi Code subscription logins by quota headroom, as omp ranks
  its Kimi accounts for new sessions.

  `rank/2` takes credential entries (maps with an `:api_key`) in configured
  order. With fewer than two subscription logins (JWTs) it returns them
  unchanged. Otherwise it reads each login's quota
  (`LemonAi.Providers.KimiCodeUsage`, cached per account and endpoint for five
  minutes, failures for one minute; fetched concurrently and bounded by
  `:timeout_ms`) and sorts:

    1. logins with an exhausted window last, earliest reset first;
    2. logins whose 5h window is at least 85% used after the others;
    3. measured logins before unmeasured ones (API keys, failed fetches);
    4. the long window (`7d`, else `month`): the most headroom that must be
       spent per remaining hour before it resets first, then the least used;
    5. the same for the 5h window;
    6. configured order.

  Options: `:base_url`, `:timeout_ms` (default 5000), `:now_ms`, `:fetch`
  (a `KimiCodeUsage.fetch/2`-compatible function, for tests).
  """

  alias LemonAi.Auth.{Cache, KimiCodeOAuth, OAuthFlow}
  alias LemonAi.Providers.KimiCodeUsage

  @hot_fraction 0.85
  @ok_ttl_ms 300_000
  @error_ttl_ms 60_000
  @timeout_ms 5_000
  @hour_ms 3_600_000
  @primary_ms 5 * @hour_ms
  @secondary_ms %{"7d" => 7 * 24 * @hour_ms, "month" => 30 * 24 * @hour_ms}

  @spec rank([%{required(:api_key) => term()}], keyword()) :: [map()]
  def rank(entries, opts \\ []) when is_list(entries) do
    if Enum.count(entries, &KimiCodeOAuth.oauth_token?(&1.api_key)) < 2 do
      entries
    else
      now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

      entries
      |> usages(opts)
      |> Enum.with_index()
      |> Enum.map(fn {{entry, windows}, position} -> score(entry, windows, position, now_ms) end)
      |> Enum.sort_by(& &1.key)
      |> Enum.map(& &1.entry)
    end
  end

  defp usages(entries, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    entries
    |> Task.async_stream(&{&1, windows(&1.api_key, opts)},
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(entries)
    |> Enum.map(fn
      {{:ok, result}, _entry} -> result
      {{:exit, _}, entry} -> {entry, nil}
    end)
  end

  defp windows(token, opts) do
    if KimiCodeOAuth.oauth_token?(token) do
      base_url = Keyword.get(opts, :base_url)
      key = {__MODULE__, base_url, account(token)}
      now = System.monotonic_time(:millisecond)

      case Cache.get(key) do
        {expires, result} when expires > now ->
          result

        _ ->
          fetch = Keyword.get(opts, :fetch, &KimiCodeUsage.fetch/2)

          result =
            case fetch.(token,
                   base_url: base_url,
                   timeout_ms: Keyword.get(opts, :timeout_ms, @timeout_ms)
                 ) do
              {:ok, windows} -> windows
              _ -> nil
            end

          Cache.put(key, {now + if(result, do: @ok_ttl_ms, else: @error_ttl_ms), result})
          result
      end
    end
  end

  defp account(token) do
    case token |> OAuthFlow.jwt_claims() |> OAuthFlow.claim(["user_id", "sub"]) do
      id when is_binary(id) -> {:account, id}
      _ -> {:token, :crypto.hash(:sha256, token)}
    end
  end

  defp score(entry, nil, position, _now_ms),
    do: %{entry: entry, key: {0, false, 1, 0, 0, 0, 0, position}}

  defp score(entry, windows, position, now_ms) do
    by_id = Map.new(windows, &{&1.id, &1})
    primary = by_id["5h"]
    {secondary, secondary_ms} = secondary(by_id)
    exhausted = Enum.filter(windows, &(&1.used_fraction >= 1.0))

    blocked =
      case exhausted do
        [] -> 0
        _ -> {1, exhausted |> Enum.map(&reset_ms/1) |> Enum.max() || :never}
      end

    primary_used = used(primary)
    secondary_used = used(secondary)

    key =
      {blocked, primary_used >= @hot_fraction, if(primary || secondary, do: 0, else: 1),
       -drain(secondary, secondary_used, secondary_ms, now_ms), secondary_used,
       -drain(primary, primary_used, @primary_ms, now_ms), primary_used, position}

    %{entry: entry, key: key}
  end

  defp secondary(%{"7d" => window}), do: {window, @secondary_ms["7d"]}
  defp secondary(%{"month" => window}), do: {window, @secondary_ms["month"]}
  defp secondary(_), do: {nil, @secondary_ms["7d"]}

  defp used(nil), do: 0.5
  defp used(window), do: window.used_fraction

  # Headroom that must be spent per remaining hour before the window resets.
  # Without a reset clock the full window is assumed to remain; the remaining
  # time is floored at one minute so a stale report cannot dominate.
  defp drain(window, used, duration_ms, now_ms) do
    headroom = 1.0 - used

    remaining_ms =
      case reset_ms(window) do
        nil -> duration_ms
        reset -> min(reset - now_ms, duration_ms)
      end

    if headroom <= 0, do: 0.0, else: headroom / (max(remaining_ms, 60_000) / @hour_ms)
  end

  defp reset_ms(%{resets_at: %DateTime{} = at}), do: DateTime.to_unix(at, :millisecond)
  defp reset_ms(_window), do: nil
end
