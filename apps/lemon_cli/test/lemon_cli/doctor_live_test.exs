defmodule LemonCli.DoctorLiveTest do
  use ExUnit.Case, async: true

  alias LemonCli.Doctor.Providers
  alias LemonCli.ProviderLiveCheck
  alias LemonCli.Setup.Verification
  alias LemonCore.Doctor.{LiveChecks, Report}

  for {api, base, expected, auth} <- [
        {:openai_completions, "https://example.invalid/v1", "/v1/models", "authorization"},
        {:openai_responses, "https://example.invalid/v1/", "/v1/models", "authorization"},
        {:anthropic_messages, "https://example.invalid", "/v1/models", "x-api-key"},
        {:anthropic_messages, "https://example.invalid/v1", "/v1/models", "x-api-key"},
        {:google_generative_ai, "https://example.invalid/v1beta", "/v1beta/models",
         "x-goog-api-key"}
      ] do
    test "#{api} #{base} uses only an authenticated models GET" do
      input = %{api: unquote(api), base_url: unquote(base), api_key: "fake-key", headers: %{}}

      assert {:ok, %{http_status: 200}} =
               ProviderLiveCheck.check(input,
                 extended: true,
                 http_get: fn :get, {url, headers}, _, _ ->
                   assert to_string(url) == "https://example.invalid" <> unquote(expected)
                   assert List.keyfind(headers, to_charlist(unquote(auth)), 0)
                   {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{\"data\":[]}"}}
                 end
               )
    end
  end

  test "setup retains its OpenAI-only live policy" do
    input = %{
      api: :anthropic_messages,
      base_url: "https://example.invalid",
      api_key: "key",
      headers: %{}
    }

    assert {:skip, {:unsupported_api, :anthropic_messages}} =
             ProviderLiveCheck.check(input, http_get: fn _, _, _, _ -> flunk("no HTTP") end)
  end

  test "keyless local models request has no Authorization header" do
    input = %{
      api: :openai_completions,
      base_url: "http://127.0.0.1:11434/v1",
      api_key: nil,
      headers: %{}
    }

    assert {:ok, _} =
             ProviderLiveCheck.check(input,
               extended: true,
               http_get: fn :get, {_, headers}, _, _ ->
                 assert headers == []
                 {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{}"}}
               end
             )
  end

  test "unsupported OAuth APIs are skipped without HTTP" do
    input = %{
      api: :openai_codex_responses,
      base_url: "https://example.invalid",
      api_key: "oauth",
      headers: %{}
    }

    assert {:skip, {:unsupported_api, _}} =
             ProviderLiveCheck.check(input,
               extended: true,
               http_get: fn _, _, _, _ -> flunk("no HTTP") end
             )

    config = %{
      agent: %{default_provider: "openai-codex", default_model: "test"},
      providers: %{"openai-codex" => %{auth_source: "oauth"}}
    }

    model = %{
      id: "test",
      provider: :openai_codex,
      api: :openai_codex_responses,
      base_url: "https://example.invalid"
    }

    assert {:skip, {:unsupported_api, _}} =
             Verification.live_input(
               config: config,
               verification_model: model,
               non_generating: true
             )
  end

  for {result, status, text} <- [
        {{:ok, %{}}, :pass, "non-generating"},
        {{:error, :unauthorized}, :fail, "rejected"},
        {{:error, :timeout}, :fail, "timed out"},
        {{:error, :unreachable}, :fail, "Could not reach"},
        {{:skip, {:unsupported_api, :oauth}}, :skip, "no non-generating endpoint"}
      ] do
    test "provider doctor maps #{inspect(result)}" do
      result = unquote(Macro.escape(result))

      opts = [
        config: %{},
        provider_live_input: fn _ -> {:ok, %{}} end,
        provider_live_check: fn _ -> result end
      ]

      [check] = opts |> Providers.live_checks() |> LiveChecks.run()
      assert check.status == unquote(status)
      assert check.message =~ unquote(text)
    end
  end

  test "fake tokens and secret URLs in error bodies never reach JSON" do
    input = %{
      api: :openai_responses,
      base_url: "https://example.invalid/v1?token=fake-token",
      api_key: "fake-token",
      headers: %{}
    }

    opts = [
      config: %{},
      provider_live_input: fn _ -> {:ok, input} end,
      http_get: fn :get, _, _, _ ->
        {:ok,
         {{~c"HTTP/1.1", 401, ~c"No"}, [],
          "api_key=sk-fake_token_12345678 https://secret.invalid/?token=fake-token"}}
      end
    ]

    json =
      opts
      |> Providers.live_checks()
      |> LiveChecks.run()
      |> Report.from_checks()
      |> Report.to_json()

    refute json =~ "fake-token"
    refute json =~ "sk-fake"
    refute json =~ "secret.invalid"
    assert json =~ "rejected"
  end

  test "setup keeps its original timeout classification while doctor reports timeout" do
    input = %{
      api: :openai_completions,
      base_url: "https://example.invalid/v1",
      api_key: "key",
      headers: %{}
    }

    opts = [http_get: fn :get, _, _, _ -> {:error, :timeout} end]
    assert {:error, :unreachable} = ProviderLiveCheck.check(input, opts)
    assert {:error, :timeout} = ProviderLiveCheck.check(input, Keyword.put(opts, :extended, true))
  end

  test "default local provider resolution uses the configured endpoint and no credential" do
    config = %{
      agent: %{default_provider: "ollama", default_model: "test-model"},
      providers: %{"ollama" => %{base_url: "http://127.0.0.1:11435/v1"}}
    }

    assert {:ok, input} = Verification.live_input(config: config, non_generating: true)
    assert input.base_url == "http://127.0.0.1:11435/v1"
    assert input.api_key == nil
  end

  test "missing default configuration is skipped without HTTP" do
    opts = [
      config: %{agent: %{}, providers: %{}},
      http_get: fn _, _, _, _ -> flunk("no HTTP") end
    ]

    [check] = opts |> Providers.live_checks() |> LiveChecks.run()
    assert check.status == :skip
  end
end
