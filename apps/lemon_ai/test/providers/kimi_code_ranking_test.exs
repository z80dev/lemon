defmodule LemonAi.Providers.KimiCodeRankingTest do
  use ExUnit.Case, async: false

  alias LemonAi.Providers.KimiCodeRanking
  @now 1_800_000_000_000

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    :ok
  end

  defp jwt(account) do
    claims = %{
      "user_id" => "#{account}-#{System.unique_integer([:positive])}",
      "exp" => 4_000_000_000
    }

    "eyJhbGciOiJub25lIn0.#{claims |> Jason.encode!() |> Base.url_encode64(padding: false)}.sig"
  end

  defp window(id, used, reset_in_ms \\ nil) do
    %{
      id: id,
      label: id,
      used_fraction: used,
      resets_at: reset_in_ms && DateTime.from_unix!(@now + reset_in_ms, :millisecond)
    }
  end

  defp rank(entries, usage) do
    test_pid = self()

    fetch = fn token, opts ->
      send(test_pid, {:fetched, token, opts[:base_url]})
      Map.fetch!(usage, token)
    end

    entries
    |> KimiCodeRanking.rank(now_ms: @now, fetch: fetch, base_url: "https://api.kimi.test/coding")
    |> Enum.map(& &1.ref)
  end

  test "new selections prefer the login with more 5h and long-window headroom" do
    loaded = jwt("loaded")
    fresh = jwt("fresh")

    usage = %{
      loaded => {:ok, [window("5h", 0.92), window("month", 0.8)]},
      fresh => {:ok, [window("5h", 0.01), window("month", 0.02)]}
    }

    entries = [%{ref: "loaded", api_key: loaded}, %{ref: "fresh", api_key: fresh}]
    assert rank(entries, usage) == ["fresh", "loaded"]
    assert_received {:fetched, ^loaded, "https://api.kimi.test/coding"}

    # Cached per account: a second ranking does not fetch again.
    assert rank(entries, usage) == ["fresh", "loaded"]
    refute_received {:fetched, ^loaded, _}
  end

  test "exhausted logins rank last by earliest reset; unmeasured after measured" do
    [a, b, c, d] = Enum.map(~w(a b c d), &jwt/1)

    usage = %{
      a => {:ok, [window("5h", 1.0, 3_600_000), window("month", 0.1)]},
      b => {:ok, [window("5h", 1.0, 600_000)]},
      c => {:error, {:http_error, 500}},
      d => {:ok, [window("5h", 0.5), window("7d", 0.5, 3_600_000)]}
    }

    entries = for {ref, key} <- [a: a, b: b, c: c, d: d], do: %{ref: ref, api_key: key}
    assert rank(entries, usage) == [:d, :c, :b, :a]
  end

  test "the long window that resets sooner with unused headroom wins" do
    [soon, later] = Enum.map(~w(soon later), &jwt/1)

    usage = %{
      soon => {:ok, [window("5h", 0.2), window("7d", 0.4, 3_600_000)]},
      later => {:ok, [window("5h", 0.2), window("7d", 0.4, 6 * 24 * 3_600_000)]}
    }

    entries = [%{ref: "later", api_key: later}, %{ref: "soon", api_key: soon}]
    assert rank(entries, usage) == ["soon", "later"]
  end

  test "fewer than two subscription logins keep configured order without fetching" do
    entries = [%{ref: "key", api_key: "sk-kimi"}, %{ref: "login", api_key: jwt("one")}]
    assert rank(entries, %{}) == ["key", "login"]
    refute_received {:fetched, _, _}
  end
end
