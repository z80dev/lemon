defmodule LemonScripts.PresetNativeScopeProbe do
  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager
  alias LemonAgent.ModelRuntime.{ModelCatalog, ProviderNames}

  @pool_env "LEMON_PRESET_NATIVE_SCOPE_POOL"
  @key_a "synthetic-preset-principal-a"
  @key_b "synthetic-preset-principal-b"
  @key_c "synthetic-preset-principal-c"

  defmodule Endpoint do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      principal =
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer synthetic-preset-principal-a"] -> :a
          ["Bearer synthetic-preset-principal-b"] -> :b
          ["Bearer synthetic-preset-principal-c"] -> :c
          [] -> :missing
          _ -> :unrelated
        end

      team = Plug.Conn.get_req_header(conn, "x-team")
      Agent.update(opts[:requests], &[{conn.method, conn.request_path, principal, team} | &1])

      scope =
        case {String.split(conn.request_path, "/", trim: true), principal, team} do
          {["a" | _], :a, []} -> :a
          {["b" | _], :b, ["project-b"]} -> :b
          {["b" | _], :c, ["project-b"]} -> :c
          _ -> nil
        end

      body =
        case {scope, conn.method, Path.basename(conn.request_path)} do
          {scope, "GET", "tags"} when scope in [:a, :b, :c] ->
            ids =
              if scope == :a,
                do: ["shared", "qwen:small", "a-only"],
                else: ["shared", "qwen:small", "lm_studio:shared"]

            %{"models" => Enum.map(ids, &%{"name" => &1})}

          {scope, "POST", "show"} when scope in [:a, :b, :c] ->
            context = %{a: 262_144, b: 4_096, c: 8_192}[scope]

            capabilities =
              if scope == :a, do: ["completion", "thinking", "vision"], else: ["completion"]

            %{
              "model_info" => %{"fixture.context_length" => context},
              "capabilities" => capabilities
            }

          _ ->
            nil
        end

      if body do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      else
        Plug.Conn.send_resp(conn, 401, "unavailable fixture scope")
      end
    end
  end

  # Shared by deterministic consumer regressions and the standalone no-ExUnit
  # smoke. All discovery uses real HTTP and the public catalog/native boundary.
  def run!(home) do
    saved_env = Map.new(env_names(), &{&1, System.get_env(&1)})
    saved_req = Req.default_options()
    before_keys = MapSet.new(LemonAi.ModelCache.stats().providers)
    {:ok, requests} = Agent.start_link(fn -> [] end)

    {:ok, server} =
      Bandit.start_link(
        plug: {Endpoint, requests: requests},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    try do
      Enum.each(env_names(), &System.delete_env/1)
      System.put_env("HOME", home)
      System.put_env(@pool_env, @key_b)
      System.put_env("OLLAMA_API_KEY", @key_a)
      Req.default_options(Keyword.drop(saved_req, [:plug, :adapter, :base_url]))
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
      base_a = "http://127.0.0.1:#{port}/a/v1"
      base_b = "http://127.0.0.1:#{port}/b/v1"
      System.put_env("OLLAMA_BASE_URL", base_a)
      missing_secret = "preset-native-scope-#{System.unique_integer([:positive])}"

      providers =
        ProviderNames.all_canonical_names()
        |> Enum.reject(&ProviderNames.keyless?/1)
        |> Map.new(fn id ->
          {id,
           %{auth_source: "oauth", api_key_secret: missing_secret, oauth_secret: missing_secret}}
        end)
        |> Map.put("ollama", %{})

      # Prime the registry's intentional default/environment A cache through the
      # real public catalog, not by writing a synthetic model into ETS.
      cfg_a = %{providers: providers, agent: %{}}
      model_a = shared!(catalog(cfg_a))

      check!(
        model_a.context_window == 262_144 and model_a.reasoning and
          model_a.input == [:text, :image],
        "A discovery fixture did not expose distinct metadata"
      )

      check!(
        LemonAi.Models.get_model(:ollama, "shared") == model_a,
        "registry-only API did not retain its default/environment scope"
      )

      routing = %{
        default_pool: "unrelated",
        default_profile: "selected",
        profiles: %{"selected" => %{credential_pool: "selected"}},
        credential_pools: %{
          "selected" => %{credentials: %{"ollama" => [%{source: :env, name: @pool_env}]}},
          "unrelated" => %{
            credentials: %{"ollama" => [%{source: :env, name: "LEMON_PRESET_UNRELATED_MISSING"}]}
          }
        }
      }

      # No explicit models list: this is a dynamic built-in preset, not a
      # custom provider and not the configured-addition path.
      provider_b = %{base_url: base_b, api_key: @key_c, headers: %{"X-Team" => "project-b"}}

      settings =
        struct!(SettingsManager,
          providers: Map.put(providers, "ollama", provider_b),
          provider_routing: routing,
          default_model: %{provider: :ollama, model_id: "shared"}
        )

      check!(
        ModelResolver.build_get_api_key(settings).(:ollama) == @key_b,
        "native credential selection did not select B"
      )

      models_b = catalog(settings)
      model_b = shared!(models_b)

      check!(
        model_b.base_url == base_b and model_b.context_window == 4_096 and not model_b.reasoning and
          model_b.input == [:text],
        "public catalog did not discover B metadata"
      )

      check!(
        Enum.sort(Enum.map(models_b, & &1.id)) == ["lm_studio:shared", "qwen:small", "shared"],
        "catalog exposed A-only models"
      )

      selectors = [
        nil,
        "ollama:shared",
        "ollama/shared",
        "shared",
        %{provider: "ollama", model_id: "shared"},
        "ollama:qwen:small"
      ]

      failures = Enum.flat_map(selectors, &native_failure(&1, settings, base_b, 4_096))

      defaults = [
        %{provider: :ollama, model_id: "qwen:small"},
        %{provider: :openai, model_id: "ollama:shared"},
        %{provider: :openai, model_id: "ollama/shared"},
        %{provider: :ollama, model_id: "lm_studio:shared"}
      ]

      failures =
        failures ++
          Enum.flat_map(defaults, fn default ->
            native_failure(nil, %{settings | default_model: default}, base_b, 4_096)
          end)

      # The per-default URL is also part of the lookup scope when the provider
      # does not supply a URL; patching the returned model afterward is too late.
      default_url_settings = %{
        settings
        | providers: Map.put(settings.providers, "ollama", Map.delete(provider_b, :base_url)),
          default_model: %{provider: :ollama, model_id: "shared", base_url: base_b}
      }

      failures = failures ++ native_failure(nil, default_url_settings, base_b, 4_096)

      # Rotation with no new listing must synthesize conservative defaults, not
      # reuse A or B. The resolver is cache-only and must issue no HTTP requests.
      System.put_env(@pool_env, "synthetic-preset-uncached-principal")
      uncached = ModelResolver.resolve_session_model("ollama:shared", settings)

      failures =
        if uncached.base_url == base_b and uncached.context_window == 128_000 and
             not uncached.reasoning and uncached.input == [:text],
           do: failures,
           else: failures ++ [%{case: "uncached principal", observed: metadata(uncached)}]

      # Shared Credentials semantics explicitly permit the configured default C
      # when the selected pool source is absent; do not invent fail-closed policy.
      System.delete_env(@pool_env)
      System.delete_env("OLLAMA_API_KEY")

      check!(
        ModelResolver.build_get_api_key(settings).(:ollama) == @key_c,
        "explicit default credential fallback was changed"
      )

      check!(
        shared!(catalog(settings)).context_window == 8_192,
        "catalog did not discover explicit default C"
      )

      failures = failures ++ native_failure("ollama:shared", settings, base_b, 8_192)
      System.put_env("OLLAMA_API_KEY", @key_a)

      check!(
        LemonAi.Models.get_model(:ollama, "shared") == model_a,
        "native lookup changed registry-only A scope"
      )

      recorded = Agent.get(requests, &Enum.reverse/1)

      expected_counts = %{
        {:a, "/a/api/tags"} => 1,
        {:a, "/a/api/show"} => 3,
        {:b, "/b/api/tags"} => 1,
        {:b, "/b/api/show"} => 3,
        {:c, "/b/api/tags"} => 1,
        {:c, "/b/api/show"} => 3
      }

      counts =
        Enum.frequencies_by(recorded, fn {_method, path, principal, _team} ->
          {principal, path}
        end)

      check!(
        counts == expected_counts,
        "native cache-only lookups or discovery crossed HTTP scopes"
      )

      report = %{
        checks: [
          :public_catalog,
          :native_qualified_default_map_bare_and_colon,
          :selected_pool,
          :uncached_principal,
          :explicit_default_fallback,
          :registry_scope_unchanged
        ],
        loopback_requests: length(recorded),
        failures: failures
      }

      if failures != [], do: raise("native preset scope mismatch: " <> Jason.encode!(report))
      report
    after
      Supervisor.stop(server)
      Agent.stop(requests)

      Enum.each(LemonAi.ModelCache.stats().providers, fn key ->
        if not MapSet.member?(before_keys, key), do: LemonAi.ModelCache.invalidate(key)
      end)

      Req.default_options(saved_req)

      Enum.each(saved_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end
  end

  defp catalog(cfg) do
    ModelCatalog.available_models(config: cfg)
    |> Enum.filter(&(&1.provider == :ollama))
  end

  defp shared!(models),
    do: Enum.find(models, &(&1.id == "shared")) || raise("shared fixture model missing")

  defp native_failure(selector, settings, base, context) do
    model = ModelResolver.resolve_session_model(selector, settings)

    expected_id =
      if selector == "ollama:qwen:small", do: "qwen:small", else: expected_id(selector, settings)

    if model.provider == :ollama and model.id == expected_id and model.base_url == base and
         model.context_window == context and model.max_tokens <= context and not model.reasoning and
         model.input == [:text] and model.headers == %{"x-team" => "project-b"} do
      []
    else
      [
        %{
          case: inspect(selector || settings.default_model),
          expected_id: expected_id,
          expected_context: context,
          observed: metadata(model)
        }
      ]
    end
  rescue
    error in ArgumentError ->
      [%{case: inspect(selector || settings.default_model), error: Exception.message(error)}]
  end

  defp expected_id(nil, %{default_model: %{model_id: id}}) do
    case id do
      "ollama:shared" -> "shared"
      "ollama/shared" -> "shared"
      other -> other
    end
  end

  defp expected_id(_, _), do: "shared"

  defp metadata(model),
    do:
      Map.take(model, [
        :id,
        :provider,
        :base_url,
        :context_window,
        :max_tokens,
        :reasoning,
        :input,
        :headers
      ])

  defp check!(true, _message), do: :ok
  defp check!(false, message), do: raise(message)

  defp env_names do
    provider_env = Enum.flat_map(ProviderNames.all_canonical_names(), &ProviderNames.env_vars/1)
    preset_env = Enum.flat_map(LemonAi.Models.Presets.all(), & &1.base_url_env)

    Enum.uniq(
      provider_env ++
        preset_env ++
        [
          @pool_env,
          "LEMON_PRESET_UNRELATED_MISSING",
          "HOME",
          "GOOGLE_APPLICATION_CREDENTIALS",
          "AWS_PROFILE",
          "AWS_ACCESS_KEY_ID",
          "AWS_SECRET_ACCESS_KEY"
        ]
    )
  end
end
