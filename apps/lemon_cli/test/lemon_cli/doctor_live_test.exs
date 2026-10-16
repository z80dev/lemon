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

  describe "provider selection" do
    alias LemonCore.Doctor.Check

    defp selection_config(extra \\ %{}) do
      %{
        agent: %{default_provider: "anthropic", default_model: "claude-test"},
        providers:
          Map.merge(
            %{
              "openai" => %{api_key: "fake-openai-key"},
              "my-gateway" => %{
                api: "openai_completions",
                base_url: "https://gateway.invalid/v1",
                auth: "none"
              }
            },
            extra
          )
      }
    end

    # Records every resolver call; results are keyed by provider so a test can
    # make individual providers pass, fail or skip without any HTTP.
    defp selection_opts(config, results, extra \\ []) do
      parent = self()

      [
        config: config,
        provider_live_input: fn input_opts ->
          send(parent, {:input, Keyword.get(input_opts, :provider)})
          {:ok, %{provider: Keyword.get(input_opts, :provider)}}
        end,
        provider_live_check: fn input ->
          Map.get(results, input.provider, {:ok, %{}})
        end
      ]
      |> then(&(extra ++ &1))
    end

    defp run_live(opts), do: opts |> Providers.live_checks() |> LiveChecks.run()

    test "without a selection only the default provider is checked" do
      opts = selection_opts(selection_config(), %{})
      assert [{"providers.live", _}] = Providers.live_checks(opts)

      assert [%Check{name: "providers.live", status: :pass, message: message}] = run_live(opts)
      assert message =~ "Default provider"
      assert_received {:input, nil}
      refute_received {:input, _}
    end

    test "all checks the default first, then each configured provider with its own result" do
      results = %{
        "openai" => {:error, :unauthorized},
        "my-gateway" => {:skip, {:unsupported_api, :custom}}
      }

      opts = selection_opts(selection_config(), results, live_provider: "all")

      assert ["providers.live.anthropic", "providers.live.my-gateway", "providers.live.openai"] =
               opts |> Providers.live_checks() |> Enum.map(&elem(&1, 0))

      checks = Map.new(run_live(opts), &{&1.name, &1})

      assert checks["providers.live.anthropic"].status == :pass
      assert checks["providers.live.my-gateway"].status == :skip
      assert checks["providers.live.openai"].status == :fail
      assert checks["providers.live.openai"].message =~ "openai: "
      assert checks["providers.live.openai"].message =~ "rejected"

      for provider <- ["anthropic", "my-gateway", "openai"],
          do: assert_received({:input, ^provider})
    end

    test "a default provider that is also configured is checked once" do
      config = selection_config(%{"anthropic" => %{api_key: "fake-anthropic-key"}})
      opts = selection_opts(config, %{}, live_provider: "all")

      assert ["providers.live.anthropic", "providers.live.my-gateway", "providers.live.openai"] =
               opts |> Providers.live_checks() |> Enum.map(&elem(&1, 0))
    end

    test "a named provider is matched by normalized id and is the only one probed" do
      opts = selection_opts(selection_config(), %{}, live_provider: "My_Gateway")

      assert [%Check{name: "providers.live.my-gateway", status: :pass}] = run_live(opts)
      assert_received {:input, "my-gateway"}
      refute_received {:input, _}
    end

    test "a built-in provider that is not configured can still be named" do
      opts = selection_opts(selection_config(), %{}, live_provider: "groq")

      assert [%Check{name: "providers.live.groq", status: :pass}] = run_live(opts)
      assert_received {:input, "groq"}
    end

    test "an unknown name fails without probing or echoing the name" do
      opts = selection_opts(selection_config(), %{}, live_provider: "nope-sk-fake_secret_1234567")

      assert [%Check{name: "providers.live", status: :fail} = check] = run_live(opts)
      assert check.message =~ "not configured or recognized"
      refute inspect(check) =~ "nope"
      refute_received {:input, _}
    end

    test "all is capped and the surplus is reported as one skip" do
      providers = Map.new(1..11, &{"gw-#{String.pad_leading("#{&1}", 2, "0")}", %{}})
      config = %{agent: %{}, providers: providers}
      opts = selection_opts(config, %{}, live_provider: "all")

      jobs = Providers.live_checks(opts)
      assert length(jobs) == 9

      checks = run_live(opts)

      assert [%Check{name: "providers.live.more", status: :skip, message: message}] =
               Enum.filter(checks, &(&1.name == "providers.live.more"))

      assert message =~ "3 more provider(s)"
      assert length(Enum.filter(checks, &(&1.status == :pass))) == 8
    end

    test "provider ids are sanitized in result names" do
      config = %{agent: %{}, providers: %{"bad name/with" => %{}}}
      opts = selection_opts(config, %{}, live_provider: "all")

      assert [{"providers.live.bad_name_with", _}] = Providers.live_checks(opts)
    end

    for key <- [
          "gateway?token=private-value",
          "gateway?session=public&token=private-value"
        ] do
      test "secrets in #{key} never reach names, messages, inspect output, or JSON" do
        key = unquote(key)

        for selection <- ["all", key] do
          opts = real_opts(%{key => custom("secret")}, live_provider: selection)

          assert [{name, _}] = Providers.live_checks(opts)
          refute name =~ "private-value"

          checks = run_live(opts)
          assert [%Check{status: :pass} = check] = checks
          assert_received {:probed, "https://secret.invalid/v1/models"}
          refute check.name =~ "private-value"
          refute check.message =~ "private-value"
          refute inspect(checks) =~ "private-value"
          refute checks |> Report.from_checks() |> Report.to_json() =~ "private-value"
        end
      end
    end

    # Real resolver, injected HTTP: every custom provider has its own endpoint, so
    # the requested URL shows which configured provider was actually probed.
    defp custom(host),
      do: %{api: "openai_completions", base_url: "https://#{host}.invalid/v1", auth: "none"}

    defp real_opts(providers, extra) do
      parent = self()

      [
        config: %{agent: %{}, providers: providers},
        http_get: fn :get, {url, _headers}, _, _ ->
          send(parent, {:probed, List.to_string(url)})
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{}"}}
        end
      ]
      |> then(&(extra ++ &1))
    end

    test "a custom key containing a slash is probed under its original key" do
      opts = real_opts(%{"team/gateway" => custom("slash")}, live_provider: "all")

      assert [{"providers.live.team_gateway", _}] = Providers.live_checks(opts)
      assert [%Check{name: "providers.live.team_gateway", status: :pass}] = run_live(opts)
      assert_received {:probed, "https://slash.invalid/v1/models"}

      named = real_opts(%{"team/gateway" => custom("slash")}, live_provider: "team/gateway")
      assert [%Check{name: "providers.live.team_gateway", status: :pass}] = run_live(named)
      assert_received {:probed, "https://slash.invalid/v1/models"}
    end

    test "exact configured keys take precedence over normalized provider matches" do
      providers = %{
        "my_gateway" => custom("underscore"),
        "my-gateway" => custom("hyphen")
      }

      for {key, host} <- [{"my_gateway", "underscore"}, {"my-gateway", "hyphen"}] do
        opts = real_opts(providers, live_provider: key)
        assert [%Check{status: :pass}] = run_live(opts)
        expected_url = "https://#{host}.invalid/v1/models"
        assert_received {:probed, ^expected_url}
        refute_received {:probed, _}
      end
    end

    test "all probes normalized collisions once each when the underscore key is default" do
      providers = %{
        "my_gateway" => custom("underscore"),
        "my-gateway" => custom("hyphen")
      }

      opts =
        providers
        |> real_opts(live_provider: "all")
        |> Keyword.put(:config, %{
          agent: %{default_provider: "my_gateway", default_model: "test-model"},
          providers: providers
        })

      assert [{"providers.live.my_gateway", _}, {"providers.live.my-gateway", _}] =
               Providers.live_checks(opts)

      assert [%Check{status: :pass}, %Check{status: :pass}] = run_live(opts)
      assert_received {:probed, "https://underscore.invalid/v1/models"}
      assert_received {:probed, "https://hyphen.invalid/v1/models"}
      refute_received {:probed, _}
    end

    test "a key longer than the name bound is probed under its original key" do
      key = String.duplicate("a", 60)
      opts = real_opts(%{key => custom("long")}, live_provider: "all")

      assert [{name, _}] = Providers.live_checks(opts)
      assert name == "providers.live." <> String.duplicate("a", 48)
      assert [%Check{status: :pass}] = run_live(opts)
      assert_received {:probed, "https://long.invalid/v1/models"}

      named = real_opts(%{key => custom("long")}, live_provider: key)
      assert [%Check{status: :pass}] = run_live(named)
      assert_received {:probed, "https://long.invalid/v1/models"}
    end

    test "keys with colliding display ids stay distinct providers" do
      providers = %{
        "team/gateway" => custom("slash"),
        "team_gateway" => custom("underscore"),
        "team?gateway" => custom("question")
      }

      opts = real_opts(providers, live_provider: "all")
      names = opts |> Providers.live_checks() |> Enum.map(&elem(&1, 0))

      assert length(Enum.uniq(names)) == 3
      assert Enum.all?(names, &String.starts_with?(&1, "providers.live.team_gateway"))

      checks = run_live(opts)
      assert Enum.all?(checks, &(&1.status == :pass))
      assert length(Enum.uniq(Enum.map(checks, & &1.name))) == 3

      urls =
        for _ <- 1..3,
            do:
              (
                assert_received({:probed, url})
                url
              )

      assert Enum.sort(urls) == [
               "https://question.invalid/v1/models",
               "https://slash.invalid/v1/models",
               "https://underscore.invalid/v1/models"
             ]

      named = real_opts(providers, live_provider: "team/gateway")
      assert [%Check{status: :pass}] = run_live(named)
      assert_received {:probed, "https://slash.invalid/v1/models"}
      refute_received {:probed, _}
    end

    test "failures stay redacted for a named provider" do
      input = %{
        provider: "my-gateway",
        api: :openai_completions,
        base_url: "https://secret.invalid/v1?token=fake-token",
        api_key: "fake-token",
        headers: %{}
      }

      opts = [
        config: selection_config(),
        live_provider: "my-gateway",
        provider_live_input: fn _ -> {:ok, input} end,
        http_get: fn :get, {url, _headers}, _, _ ->
          assert List.to_string(url) =~ "/models"

          {:ok,
           {{~c"HTTP/1.1", 500, ~c"No"}, [],
            "api_key=sk-fake_token_12345678 https://secret.invalid/?token=fake-token"}}
        end
      ]

      json = opts |> run_live() |> Report.from_checks() |> Report.to_json()

      refute json =~ "fake-token"
      refute json =~ "sk-fake"
      refute json =~ "secret.invalid"
      assert json =~ "HTTP 500"
      assert json =~ "providers.live.my-gateway"
    end

    test "a resolver crash is a redacted failure for that provider only" do
      opts =
        selection_opts(selection_config(), %{},
          live_provider: "all",
          provider_live_input: fn input_opts ->
            if input_opts[:provider] == "openai", do: raise("boom sk-fake_secret_12345678")
            {:ok, %{provider: input_opts[:provider]}}
          end
        )

      checks = Map.new(run_live(opts), &{&1.name, &1})
      assert checks["providers.live.openai"].status == :fail
      refute inspect(checks) =~ "boom"
      assert checks["providers.live.anthropic"].status == :pass
    end

    test "Verification.live_input resolves a custom provider's endpoint without a credential" do
      assert {:ok, input} =
               Verification.live_input(
                 config: selection_config(),
                 provider: "my-gateway",
                 non_generating: true
               )

      assert input.provider == "my-gateway"
      assert input.api == :openai_completions
      assert input.base_url == "https://gateway.invalid/v1"
      assert input.api_key == nil
    end

    test "Verification.live_input resolves a non-default built-in provider's catalog endpoint" do
      assert {:ok, input} =
               Verification.live_input(
                 config: selection_config(),
                 provider: "openai",
                 non_generating: true
               )

      assert input.provider == "openai"
      assert input.api_key == "fake-openai-key"
      assert input.base_url =~ "openai"
    end

    test "Verification.live_input keeps the default provider when none is named" do
      config = %{
        agent: %{default_provider: "ollama", default_model: "test-model"},
        providers: %{"ollama" => %{base_url: "http://127.0.0.1:11435/v1"}}
      }

      assert {:ok, named} = Verification.live_input(config: config, provider: "ollama")
      assert {:ok, default} = Verification.live_input(config: config)
      assert named == default
    end

    test "Verification.live_input skips an unresolvable provider" do
      assert {:skip, :unknown_model} =
               Verification.live_input(
                 config: selection_config(),
                 provider: "not-a-provider",
                 non_generating: true
               )
    end
  end
end

defmodule LemonCli.DoctorLiveProviderCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  defmodule SelectionProbe do
    alias LemonCore.Doctor.Check

    def run(_opts), do: []

    def live_checks(opts) do
      send(self(), {:live_provider, Keyword.get(opts, :live_provider)})
      [{"providers.live", fn -> Check.pass("providers.live", "probe") end}]
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:lemon_core, :doctor_checks)
    Application.put_env(:lemon_core, :doctor_checks, [SelectionProbe])
    original_home = System.get_env("HOME")
    System.put_env("HOME", tmp_dir)

    on_exit(fn ->
      Application.put_env(:lemon_core, :doctor_checks, previous)
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
    end)

    :ok
  end

  defp doctor(args, tmp_dir) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            send(parent, {:exit, CLI.run(["doctor" | args] ++ ["--project-dir", tmp_dir])})
          end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:exit, code}
    assert_received {:stdout, stdout}
    {code, stdout, stderr}
  end

  test "--live --provider forwards the selection to live checks", %{tmp_dir: tmp_dir} do
    assert {code, _, _} = doctor(["--live", "--provider", "all", "--json"], tmp_dir)
    assert code in [0, 1]
    assert_received {:live_provider, "all"}

    assert {code, _, _} = doctor(["--live", "--provider", "openai", "--json"], tmp_dir)
    assert code in [0, 1]
    assert_received {:live_provider, "openai"}
  end

  test "--live alone leaves the selection unset", %{tmp_dir: tmp_dir} do
    assert {code, _, _} = doctor(["--live", "--json"], tmp_dir)
    assert code in [0, 1]
    assert_received {:live_provider, nil}
  end

  test "--provider without --live is a usage error and runs nothing", %{tmp_dir: tmp_dir} do
    assert {2, _, stderr} = doctor(["--provider", "all"], tmp_dir)
    assert stderr =~ "--provider requires --live"
    refute_received {:live_provider, _}
  end

  test "--provider needs a name", %{tmp_dir: tmp_dir} do
    assert {2, _, stderr} = doctor(["--live", "--provider", ""], tmp_dir)
    assert stderr =~ "--provider requires --live"
    refute_received {:live_provider, _}
  end

  test "offline doctor never requests live checks", %{tmp_dir: tmp_dir} do
    doctor(["--json"], tmp_dir)
    refute_received {:live_provider, _}
  end
end
