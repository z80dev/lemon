defmodule LemonAi.Models.OpenAICodexDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonAi.{ModelCache, Models}
  alias LemonAi.Models.OpenAICodexDiscovery, as: Discovery

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    ModelCache.invalidate_all()
    on_exit(&ModelCache.invalidate_all/0)
    :ok
  end

  test "account discovery filters unsupported models and caches without retaining identity or tokens" do
    test_pid = self()
    token = token("synthetic-account")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :requested)
      assert conn.request_path == "/backend-api/codex/models"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> token]
      assert Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["synthetic-account"]
      assert Plug.Conn.fetch_query_params(conn).params["client_version"] == "0.159.0"

      Req.Test.json(conn, %{
        "models" => [
          %{"slug" => "gpt-6.1-sol", "visibility" => "hide", "supported_in_api" => true},
          %{"slug" => "gpt-6-luna", "supported_in_api" => false},
          %{"slug" => "unknown-unpriced-model"},
          %{"slug" => 42},
          %{},
          "invalid"
        ]
      })
    end)

    opts = options(token)
    assert {:ok, [model]} = Discovery.discover(opts)
    assert model.id == "gpt-6.1-sol"
    assert model.cost == Models.get_model(:"openai-codex", "gpt-6.1-sol").cost
    assert_receive :requested
    assert {:ok, [^model]} = Discovery.discover(options(token("synthetic-account", "renewed")))
    refute_receive :requested, 20
    encoded_keys = inspect(ModelCache.stats().providers)
    refute encoded_keys =~ "synthetic-account"
    refute encoded_keys =~ token
    refute encoded_keys =~ "example.invalid"
  end

  test "direct API catalog additions do not become ChatGPT OAuth models" do
    assert %LemonAi.Types.Model{} = Models.get_model(:openai, "gpt-6.1-terra")
    assert is_nil(Models.get_model(:"openai-codex", "gpt-6.1-terra"))

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "models" => [
          %{"slug" => "gpt-6.1-terra", "supported_in_api" => true},
          %{"slug" => "gpt-6.1-sol", "supported_in_api" => true}
        ]
      })
    end)

    opts = options(token("api-catalog-account"))
    assert {:ok, [%{id: "gpt-6.1-sol"}]} = Discovery.discover(opts)

    unadvertised = Models.get_model(:"openai-codex", "gpt-6-astra")
    assert {:error, message} = Discovery.ensure_available(unadvertised, opts)
    assert message =~ "not available for this ChatGPT account"
  end

  test "different accounts and endpoints never share availability" do
    Req.Test.stub(__MODULE__, fn conn ->
      id =
        if Plug.Conn.get_req_header(conn, "chatgpt-account-id") == ["account-one"],
          do: "gpt-6.1-sol",
          else: "gpt-6-sol"

      Req.Test.json(conn, %{"models" => [%{"slug" => id}]})
    end)

    assert {:ok, [%{id: "gpt-6.1-sol"}]} = Discovery.discover(options(token("account-one")))
    assert {:ok, [%{id: "gpt-6-sol"}]} = Discovery.discover(options(token("account-two")))
    assert ModelCache.stats().entries == 2

    assert {:ok, _} =
             Discovery.discover(
               Keyword.put(
                 options(token("account-one")),
                 :base_url,
                 "https://different.invalid/backend-api"
               )
             )

    assert ModelCache.stats().entries == 3
  end

  test "empty successful account list stays authoritative and unsupported roles get actionable errors" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :requested)
      Req.Test.json(conn, %{"models" => []})
    end)

    opts = options(token("empty-account"))
    assert {:ok, []} = Discovery.discover(opts)
    assert_receive :requested
    assert {:ok, []} = Discovery.discover(opts)
    refute_receive :requested, 20
    model = Models.get_model(:"openai-codex", "gpt-6-luna")
    assert {:error, message} = Discovery.ensure_available(model, opts)
    assert message =~ "not available for this ChatGPT account"
    assert message =~ "[model_roles]"
    assert message =~ "none advertised"
  end

  test "authentication rejection does not probe another route or advertise a static fallback" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, conn.request_path)
      Plug.Conn.send_resp(conn, 401, "{}")
    end)

    token = token("rejected-account")
    assert {:error, {:authentication_rejected, 401}} = Discovery.discover(options(token))
    assert_receive "/backend-api/codex/models"
    refute_receive "/backend-api/models", 20

    models =
      Models.list_models(
        discover_codex: true,
        codex_access_token: token,
        codex_base_url: "https://example.invalid/backend-api",
        codex_req_options: [plug: {Req.Test, __MODULE__}]
      )

    refute Enum.any?(models, &(&1.provider == :"openai-codex"))
    assert Enum.any?(models, &(&1.provider == :anthropic))
  end

  test "force refresh and expiry replace availability instead of keeping unsupported stale IDs" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      n = Agent.get_and_update(calls, &{&1, &1 + 1})
      id = if n == 0, do: "gpt-6-sol", else: "gpt-6.1-sol"
      Req.Test.json(conn, %{"data" => [%{"id" => id}]})
    end)

    opts = options(token("changing-account"))
    assert {:ok, [%{id: "gpt-6-sol"}]} = Discovery.discover(opts)

    assert {:ok, [%{id: "gpt-6.1-sol"}]} =
             Discovery.discover(Keyword.put(opts, :force_refresh, true))

    assert {:ok, [%{id: "gpt-6.1-sol"}]} = Discovery.discover(Keyword.put(opts, :ttl_ms, 0))
    assert Agent.get(calls, & &1) == 3
  end

  test "malformed first route can use compatible alternate route and invalid credentials perform no HTTP" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/backend-api/codex/models" -> Req.Test.json(conn, %{"unexpected" => []})
        "/backend-api/models" -> Req.Test.json(conn, %{"data" => [%{"id" => "gpt-6.1-sol"}]})
      end
    end)

    assert {:ok, [%{id: "gpt-6.1-sol"}]} = Discovery.discover(options(token("alternate-account")))
    Req.Test.stub(__MODULE__, fn _ -> flunk("invalid token must not make a request") end)
    assert {:error, :invalid_chatgpt_access_token} = Discovery.discover(options("not-a-jwt"))
    assert {:error, :missing_chatgpt_credentials} = Discovery.discover()
  end

  defp options(token),
    do: [
      access_token: token,
      base_url: "https://example.invalid/backend-api",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

  defp token(account, signature \\ "signature") do
    "header." <>
      Base.url_encode64(
        Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account}}),
        padding: false
      ) <> "." <> signature
  end
end
