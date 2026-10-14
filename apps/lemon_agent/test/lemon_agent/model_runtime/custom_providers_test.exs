defmodule LemonAgent.ModelRuntime.CustomProvidersTest do
  use ExUnit.Case, async: false

  alias LemonAi.Types.{Model, ModelCost, StreamOptions}
  alias LemonAgent.ModelRuntime.{Credentials, CustomProviders, ModelCatalog}
  alias LemonCore.Secrets

  @env_keys ~w(MY_GATEWAY_KEY OTHER_GATEWAY_KEY OPENAI_API_KEY ANTHROPIC_API_KEY)

  setup do
    clear_secrets_table()

    tmp_dir =
      Path.join(System.tmp_dir!(), "custom_providers_test_#{System.unique_integer([:positive])}")

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)

    saved = Map.new(@env_keys ++ ["HOME", "LEMON_SECRETS_MASTER_KEY"], &{&1, System.get_env(&1)})
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    System.put_env("HOME", home_dir)
    Enum.each(@env_keys, &System.delete_env/1)

    on_exit(fn ->
      clear_secrets_table()

      Enum.each(saved, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)

      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  defp gateway(overrides \\ %{}) do
    Map.merge(
      %{
        api: "openai_completions",
        base_url: "https://llm.internal/v1",
        api_key_env: "MY_GATEWAY_KEY",
        headers: %{"X-Team" => "platform"},
        models: [
          %{
            id: "qwen3-coder",
            name: "Qwen3 Coder",
            context_window: 131_072,
            max_tokens: 8192,
            reasoning: true,
            input: ["text", "image"],
            cost: %{input: 0.5, output: 1},
            headers: %{"X-Model" => "qwen"}
          },
          %{id: "tiny"}
        ]
      },
      overrides
    )
  end

  describe "model synthesis" do
    test "listed models carry the config identity, wire api, base_url and headers" do
      providers = %{"my-gateway" => gateway()}

      assert %Model{} = model = CustomProviders.lookup(providers, "my-gateway", "qwen3-coder")
      assert model.provider == "my-gateway"
      assert model.api == :openai_completions
      assert model.base_url == "https://llm.internal/v1"
      assert model.name == "Qwen3 Coder"
      assert model.reasoning
      assert model.input == [:text, :image]
      assert model.context_window == 131_072
      assert model.max_tokens == 8192
      assert model.cost == %ModelCost{input: 0.5, output: 1.0, cache_read: 0.0, cache_write: 0.0}
      assert model.headers == %{"x-team" => "platform", "x-model" => "qwen"}
      assert model.compat == nil
    end

    test "provider defaults are below case-insensitive model overrides" do
      for provider <- ["gateway", "anthropic"] do
        providers = %{
          provider =>
            gateway(%{
              headers: %{"X-Tenant" => "providerA", "X-Route" => "provider-route"},
              models: [
                %{id: "override", headers: %{"x-TENANT" => "modelB", "x-route" => "model-route"}}
              ]
            })
        }

        model = CustomProviders.lookup(providers, provider, "override")
        assert model.headers["x-tenant"] == "modelB"
        assert model.headers["x-route"] == "model-route"

        opts =
          LemonAgent.ModelRuntime.StreamOptions.build_stream_options(
            model,
            providers,
            %{headers: %{"X-TENANT" => "callerC"}},
            nil
          )

        assert (opts.headers["x-tenant"] || opts.headers["X-TENANT"]) == "callerC"
        refute "providerA" in Map.values(opts.headers)
      end
    end

    test "an explicit models list is closed; discovery or no list accepts any id" do
      assert CustomProviders.lookup(%{"gw" => gateway()}, "gw", "unlisted") == nil

      # Spec spelling variants resolve the configured id.
      for provider <- ["my-gw", "my_gw", "MY-GW"] do
        assert %Model{provider: "my-gw", id: "tiny"} =
                 CustomProviders.lookup(%{"my-gw" => gateway()}, provider, "tiny")
      end

      open = CustomProviders.lookup(%{"gw" => gateway(%{discovery: "openai"})}, "gw", "unlisted")
      assert %Model{id: "unlisted", provider: "gw", api: :openai_completions} = open

      bare = Map.delete(gateway(), :models)
      assert %Model{id: "anything"} = CustomProviders.lookup(%{"gw" => bare}, "gw", "anything")
    end

    test "auth = none marks models keyless; per-model api overrides the provider api" do
      providers = %{
        "local" =>
          gateway(%{
            auth: "none",
            api: "openai_responses",
            models: [%{id: "claude-proxy", api: "anthropic_messages"}, %{id: "plain"}]
          })
      }

      assert %Model{api: :anthropic_messages, compat: %{allow_missing_api_key: true}} =
               CustomProviders.lookup(providers, "local", "claude-proxy")

      assert %Model{api: :openai_responses} = CustomProviders.lookup(providers, "local", "plain")
    end

    test "built-in providers are never custom; their models entries add or replace catalog models" do
      providers = %{
        "anthropic" => %{
          headers: %{"X-Org" => "lemon"},
          models: [%{id: "claude-internal", name: "Claude Internal", context_window: 50_000}]
        }
      }

      assert CustomProviders.custom_provider(providers, "anthropic") == nil
      assert CustomProviders.custom_providers(providers) == []

      model = CustomProviders.lookup(providers, :anthropic, "claude-internal")
      assert model.provider == :anthropic
      assert model.api == :anthropic_messages
      assert model.name == "Claude Internal"
      assert model.context_window == 50_000
      assert model.headers["x-org"] == "lemon"
      assert CustomProviders.lookup(providers, :anthropic, "claude-sonnet-5") == nil

      assert [%Model{id: "claude-internal", provider: :anthropic}] =
               CustomProviders.models(providers)
    end

    test "custom provider ids never become atoms" do
      id = "atomless-#{System.unique_integer([:positive])}"
      model = CustomProviders.lookup(%{id => gateway()}, id, "tiny")

      assert model.provider == id
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(String.replace(id, "-", "_")) end
    end
  end

  describe "credentials" do
    test "custom providers resolve api_key_env, then api_key, then api_key_secret" do
      assert {:ok, _} = Secrets.set("my_gateway_secret", "from-secret")
      System.put_env("MY_GATEWAY_KEY", "from-env")

      providers = %{
        "my-gateway" => gateway(%{api_key: "from-inline", api_key_secret: "my_gateway_secret"})
      }

      get_api_key = Credentials.build_get_api_key(providers)
      assert get_api_key.("my-gateway") == "from-env"

      System.delete_env("MY_GATEWAY_KEY")
      assert get_api_key.("my-gateway") == "from-inline"

      providers = %{"my-gateway" => gateway(%{api_key_secret: "my_gateway_secret"})}
      assert Credentials.resolve_provider_api_key("my-gateway", providers) == "from-secret"
      assert Credentials.provider_has_credentials?("my-gateway", providers)
    end

    test "custom providers never receive another provider's key" do
      System.put_env("OPENAI_API_KEY", "sk-openai")
      System.put_env("ANTHROPIC_API_KEY", "sk-anthropic")
      System.put_env("OTHER_GATEWAY_KEY", "other-gateway")

      providers = %{
        "my-gateway" => gateway(),
        "other" => gateway(%{api_key_env: "OTHER_GATEWAY_KEY"}),
        "openai" => %{api_key: "sk-openai-config"}
      }

      assert Credentials.resolve_provider_api_key("my-gateway", providers) == nil
      refute Credentials.provider_has_credentials?("my-gateway", providers)
      assert Credentials.resolve_provider_api_key("other", providers) == "other-gateway"
      assert Credentials.build_get_api_key(providers).("my-gateway") == nil
    end
  end

  describe "stream options" do
    test "custom providers pass their own key and base_url, keeping headers caller-only" do
      System.put_env("MY_GATEWAY_KEY", "gw-key")
      System.put_env("OPENAI_API_KEY", "sk-openai")
      providers = %{"my-gateway" => gateway()}
      model = CustomProviders.lookup(providers, "my-gateway", "qwen3-coder")

      opts =
        LemonAgent.ModelRuntime.StreamOptions.build_stream_options(
          model,
          providers,
          %{headers: %{"X-Request" => "1", "X-Team" => "override"}},
          "/tmp"
        )

      assert %StreamOptions{api_key: "gw-key"} = opts
      assert opts.headers == %{"X-Team" => "override", "X-Request" => "1"}

      assert opts.provider_options["my-gateway"] == %{
               api_key: "gw-key",
               base_url: "https://llm.internal/v1"
             }
    end

    test "custom provider defaults are not promoted to explicit caller headers" do
      providers = %{"my-gateway" => gateway()}
      model = CustomProviders.lookup(providers, "my-gateway", "qwen3-coder")

      opts =
        LemonAgent.ModelRuntime.StreamOptions.build_stream_options(model, providers, nil, nil)

      assert opts.headers == %{}
      assert model.headers == %{"x-team" => "platform", "x-model" => "qwen"}
    end

    test "keyless custom providers send no key" do
      System.put_env("OPENAI_API_KEY", "sk-openai")
      providers = %{"local" => gateway(%{auth: "none", api_key_env: nil})}
      model = CustomProviders.lookup(providers, "local", "tiny")

      opts =
        LemonAgent.ModelRuntime.StreamOptions.build_stream_options(model, providers, nil, nil)

      assert opts.api_key == nil
      assert opts.provider_options["local"] == %{base_url: "https://llm.internal/v1"}
    end

    test "built-in provider headers are a baseline under caller headers" do
      providers = %{"anthropic" => %{api_key: "sk-ant", headers: %{"X-Org" => "lemon"}}}
      model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-5")

      opts =
        LemonAgent.ModelRuntime.StreamOptions.build_stream_options(
          model,
          providers,
          %{headers: %{"X-Call" => "1"}},
          nil
        )

      assert opts.headers == %{"x-org" => "lemon", "x-call" => "1"}
    end
  end

  describe "picker listing" do
    test "lists credentialed custom models and built-in additions, skipping keyless-less ones" do
      System.put_env("MY_GATEWAY_KEY", "gw-key")

      config = %{
        providers: %{
          "my-gateway" => gateway(),
          "no-key" => gateway(%{api_key_env: "OTHER_GATEWAY_KEY"}),
          "local" => gateway(%{auth: "none", models: [%{id: "local-model"}]}),
          "anthropic" => %{api_key: "sk-ant", models: [%{id: "claude-internal"}]}
        }
      }

      models = ModelCatalog.available_models(config: config, discover_custom: false)
      ids = models |> Enum.map(&{to_string(&1.provider), &1.id}) |> MapSet.new()

      assert {"my-gateway", "qwen3-coder"} in ids
      assert {"my-gateway", "tiny"} in ids
      assert {"local", "local-model"} in ids
      assert {"anthropic", "claude-internal"} in ids
      refute Enum.any?(ids, fn {provider, _} -> provider == "no-key" end)

      assert Enum.count(models, &(&1.provider == "my-gateway" and &1.id == "tiny")) == 1
    end
  end

  describe "discovery" do
    setup do
      LemonAi.ModelCache.invalidate_all()
      on_exit(&LemonAi.ModelCache.invalidate_all/0)
      :ok
    end

    test "picker lists discovered models with the config identity; listed entries win" do
      System.put_env("MY_GATEWAY_KEY", "gw-key")
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(
          test_pid,
          {:discovery, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "x-team")}
        )

        Req.Test.json(conn, %{
          "data" => [%{"id" => "qwen3-coder"}, %{"id" => "llama-4", "context_length" => 65_536}]
        })
      end)

      config = %{providers: %{"my-gateway" => gateway(%{discovery: "openai"})}}

      models =
        ModelCatalog.available_models(config: config, custom_discovery_opts: discovery_opts())
        |> Enum.filter(&(&1.provider == "my-gateway"))

      assert_received {:discovery, "/v1/models", ["Bearer gw-key"], ["platform"]}
      assert models |> Enum.map(& &1.id) |> Enum.sort() == ["llama-4", "qwen3-coder", "tiny"]

      listed = Enum.find(models, &(&1.id == "qwen3-coder"))
      assert listed.name == "Qwen3 Coder"

      discovered = Enum.find(models, &(&1.id == "llama-4"))
      assert discovered.context_window == 65_536
      assert discovered.headers == %{"x-team" => "platform"}
      assert discovered.api == :openai_completions

      # Resolution reuses the cached listing without another request.
      assert %Model{context_window: 65_536, provider: "my-gateway"} =
               CustomProviders.lookup(config.providers, "my-gateway", "llama-4")

      refute_received {:discovery, _, _, _}
    end

    test "the same custom id cannot reuse another endpoint, account, protocol or headers" do
      System.put_env("MY_GATEWAY_KEY", "first-account-key")
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.host, conn.req_headers})
        Req.Test.json(conn, %{"data" => [%{"id" => "discovered", "context_length" => 32_768}]})
      end)

      original = gateway(%{models: [], discovery: "openai"})
      original_providers = %{"gw" => original}

      assert [first] =
               CustomProviders.models(original_providers,
                 discover: true,
                 discovery_opts: discovery_opts()
               )

      assert_receive {:request, "llm.internal", _}
      assert CustomProviders.lookup(original_providers, "gw", "discovered") == first

      for changed <- [
            %{original | base_url: "https://other.internal/v1"},
            Map.merge(original, %{api_key_env: nil, api_key: "second-account-key"}),
            %{original | api: "openai_responses"},
            %{original | headers: %{"X-Team" => "other-team", "Authorization" => "Bearer own"}}
          ] do
        providers = %{"gw" => changed}
        uncached = CustomProviders.lookup(providers, "gw", "discovered")
        assert uncached.context_window == 128_000
        assert uncached.base_url == changed.base_url
        assert uncached.api == CustomProviders.api_atom(changed.api)

        assert [current] =
                 CustomProviders.models(providers,
                   discover: true,
                   discovery_opts: discovery_opts()
                 )

        assert_receive {:request, host, headers}
        assert host == URI.parse(changed.base_url).host
        assert current.context_window == 32_768
        assert current.base_url == changed.base_url
        assert current.api == CustomProviders.api_atom(changed.api)
        assert CustomProviders.lookup(providers, "gw", "discovered") == current

        expected_auth =
          Map.get(changed.headers, "Authorization") ||
            "Bearer " <> (Map.get(changed, :api_key) || "first-account-key")

        assert {"authorization", expected_auth} in headers
      end

      assert CustomProviders.lookup(original_providers, "gw", "discovered") == first
      refute_received {:request, _, _}
    end

    test "discovery options cannot replace configured credentials or model identity" do
      System.put_env("MY_GATEWAY_KEY", "configured-key")

      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer configured-key"]
        assert Plug.Conn.get_req_header(conn, "x-team") == ["platform"]
        Req.Test.json(conn, %{"data" => [%{"id" => "discovered"}]})
      end)

      providers = %{"gw" => gateway(%{models: [], discovery: "openai"})}

      assert [model] =
               CustomProviders.models(providers,
                 discover: true,
                 discovery_opts:
                   discovery_opts() ++
                     [
                       provider: "different",
                       api: :openai_responses,
                       api_key: "wrong-key",
                       headers: %{"X-Team" => "wrong"},
                       model_defaults: %{headers: %{"Authorization" => "Bearer wrong"}}
                     ]
               )

      assert model.provider == "gw"
      assert model.api == :openai_completions
      assert model.headers == %{"x-team" => "platform"}
      assert CustomProviders.lookup(providers, "gw", "discovered") == model
    end

    test "ollama discovery providers use the /v1 wire base URL and stay keyless" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/tags" -> Req.Test.json(conn, %{"models" => [%{"name" => "qwen3:8b"}]})
          "/api/show" -> Req.Test.json(conn, %{"capabilities" => ["completion"]})
        end
      end)

      cfg = %{
        api: "openai_completions",
        base_url: "http://127.0.0.1:11434",
        auth: "none",
        discovery: "ollama"
      }

      assert [model] =
               CustomProviders.models(%{"ollama-box" => cfg},
                 discover: true,
                 discovery_opts: discovery_opts()
               )

      assert %Model{id: "qwen3:8b", provider: "ollama-box"} = model
      assert model.base_url == "http://127.0.0.1:11434/v1"
      assert model.compat == %{allow_missing_api_key: true}

      assert CustomProviders.lookup(%{"ollama-box" => cfg}, "ollama-box", "other").base_url ==
               "http://127.0.0.1:11434/v1"
    end

    test "a failed listing keeps configured models" do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 500, "boom"))

      assert [%Model{id: "only"}] =
               CustomProviders.models(
                 %{
                   "gw" => gateway(%{auth: "none", discovery: "openai", models: [%{id: "only"}]})
                 },
                 discover: true,
                 discovery_opts: discovery_opts()
               )
    end
  end

  defp discovery_opts, do: [req_options: [plug: {Req.Test, __MODULE__}]]

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
