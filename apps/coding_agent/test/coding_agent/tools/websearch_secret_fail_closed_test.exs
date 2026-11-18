defmodule CodingAgent.Tools.WebSearchSecretFailClosedTest do
  @moduledoc """
  An unreadable configured credential secret must stop the websearch
  credential chain: no ambient env key, alias, or other provider is used in
  its place.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.WebSearch
  alias LemonCore.{Secrets, Store}

  @env_vars ~w(LEMON_SECRETS_MASTER_KEY LEMON_WEB_CACHE_PATH BRAVE_API_KEY EXA_API_KEY
               PERPLEXITY_API_KEY OPENROUTER_API_KEY)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)
    clear_secrets_table()

    cache_dir =
      Path.join(System.tmp_dir!(), "websearch_failclosed_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)
    System.put_env("LEMON_WEB_CACHE_PATH", cache_dir)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    on_exit(fn ->
      clear_secrets_table()

      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      File.rm_rf!(cache_dir)
    end)

    WebSearch.reset_rate_limit()
    WebSearch.reset_cache(%{"path" => cache_dir})

    %{secret: "LEMON_T07C_WS_SECRET_#{System.unique_integer([:positive])}"}
  end

  test "brave: unreadable api_key_secret never falls back to BRAVE_API_KEY", %{secret: secret} do
    corrupt(secret)
    System.put_env("BRAVE_API_KEY", "ambient-brave")

    payload =
      run(%{provider: "brave", api_key_secret: secret, failover: %{enabled: false}})

    assert payload["error"] == "secret_unavailable"
    refute inspect(payload) =~ "ambient-brave"
    refute_received {:http, _, _, _}
  end

  test "brave: unreadable secret does not fail over to another provider", %{secret: secret} do
    corrupt(secret)
    System.put_env("PERPLEXITY_API_KEY", "pplx-ambient")

    payload =
      run(%{
        provider: "brave",
        api_key_secret: secret,
        failover: %{enabled: true, provider: "perplexity"}
      })

    assert payload["error"] == "secret_unavailable"
    refute_received {:http, _, _, _}
  end

  test "exa: unreadable api_key_secret never falls back to EXA_API_KEY", %{secret: secret} do
    corrupt(secret)
    System.put_env("EXA_API_KEY", "ambient-exa")

    payload = run(%{provider: "exa", providers: %{exa: %{api_key_secret: secret}}})

    assert payload["error"] == "secret_unavailable"
    refute_received {:http, _, _, _}
  end

  test "perplexity: unreadable api_key_secret never uses ambient env keys", %{secret: secret} do
    corrupt(secret)
    System.put_env("PERPLEXITY_API_KEY", "pplx-ambient")
    System.put_env("OPENROUTER_API_KEY", "sk-or-ambient")

    payload = run(%{provider: "perplexity", perplexity: %{api_key_secret: secret}})

    assert payload["error"] == "secret_unavailable"
    refute_received {:http, _, _, _}
  end

  test "perplexity: unreadable PERPLEXITY_API_KEY record never selects OpenRouter" do
    corrupt("PERPLEXITY_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "sk-or-ambient")

    payload = run(%{provider: "perplexity", perplexity: %{}})

    assert payload["error"] == "secret_unavailable"
    refute_received {:http, _, _, _}
  end

  test "a missing configured secret still falls back to the env key", %{secret: secret} do
    System.put_env("BRAVE_API_KEY", "ambient-brave")

    run(%{provider: "brave", api_key_secret: secret, failover: %{enabled: false}})

    assert_received {:http, :get, _url, opts}
    assert inspect(opts) =~ "ambient-brave"
  end

  defp run(search_cfg) do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http, :get, url, opts})
      {:ok, %Req.Response{status: 200, body: %{"web" => %{"results" => []}}}}
    end

    http_post = fn url, opts ->
      send(parent, {:http, :post, url, opts})
      {:ok, %Req.Response{status: 200, body: %{}}}
    end

    tool =
      WebSearch.tool("/tmp",
        http_get: http_get,
        http_post: http_post,
        settings_manager: %{tools: %{web: %{search: search_cfg}}}
      )

    result = tool.execute.("id", %{"query" => "q #{System.unique_integer()}"}, nil, nil)

    case result do
      %{content: [content]} -> Jason.decode!(content.text)
      other -> %{"raw" => other}
    end
  end

  defp corrupt(name), do: Store.put(Secrets.table(), {"default", name}, "corrupt")

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end
