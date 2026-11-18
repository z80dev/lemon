defmodule CodingAgent.Tools.WebFetchSecretFailClosedTest do
  @moduledoc """
  An unreadable configured Firecrawl/Exa credential secret must not be
  replaced by the ambient env key.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.WebFetch
  alias LemonCore.{Secrets, Store}

  @env_vars ~w(LEMON_SECRETS_MASTER_KEY FIRECRAWL_API_KEY EXA_API_KEY)

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)
    clear_secrets_table()
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    WebFetch.reset_cache(persistent: false)

    on_exit(fn ->
      clear_secrets_table()

      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    %{secret: "LEMON_T07C_WF_SECRET_#{System.unique_integer([:positive])}"}
  end

  test "firecrawl: unreadable api_key_secret never uses FIRECRAWL_API_KEY", %{secret: secret} do
    corrupt(secret)
    System.put_env("FIRECRAWL_API_KEY", "ambient-firecrawl")

    run(
      %{firecrawl: %{enabled: true, api_key_secret: secret}},
      %{"url" => "https://8.8.8.8/fail"}
    )

    refute_received {:http_post, _, _}
  end

  test "exa: unreadable api_key_secret never uses EXA_API_KEY", %{secret: secret} do
    corrupt(secret)
    System.put_env("EXA_API_KEY", "ambient-exa")

    run(
      %{providers: %{exa: %{api_key_secret: secret}}},
      %{"url" => "https://8.8.8.8/exa", "provider" => "exa"}
    )

    refute_received {:http_post, _, _}
  end

  test "firecrawl: a missing configured secret still uses FIRECRAWL_API_KEY", %{secret: secret} do
    System.put_env("FIRECRAWL_API_KEY", "ambient-firecrawl")

    run(
      %{firecrawl: %{enabled: true, api_key_secret: secret}},
      %{"url" => "https://8.8.8.8/fail"}
    )

    assert_received {:http_post, _url, opts}
    assert inspect(opts) =~ "ambient-firecrawl"
  end

  defp run(fetch_cfg, params) do
    parent = self()

    http_post = fn url, opts ->
      send(parent, {:http_post, url, opts})
      {:ok, %Req.Response{status: 500, body: %{}}}
    end

    tool =
      WebFetch.tool("/tmp",
        cache_opts: [persistent: false],
        fetch_send: fn _request -> {:error, :nxdomain} end,
        http_post: http_post,
        settings_manager: %{tools: %{web: %{fetch: Map.put(fetch_cfg, :timeout_seconds, 5)}}}
      )

    tool.execute.("id", params, nil, nil)
  end

  defp corrupt(name), do: Store.put(Secrets.table(), {"default", name}, "corrupt")

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end
