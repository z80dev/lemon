defmodule LemonScripts.CustomPoolDiscoveryProbe do
  alias LemonAgent.ModelRuntime.{CustomProviders, ModelCatalog, ProviderNames}

  @pool_env "LEMON_CUSTOM_DISCOVERY_POOL_A"
  @other_env "LEMON_CUSTOM_DISCOVERY_POOL_B"
  @key_a "synthetic-discovery-principal-a"
  @key_b "synthetic-discovery-principal-b"
  @key_c "synthetic-discovery-principal-c"

  defmodule Endpoint do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      principal =
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer synthetic-discovery-principal-a"] -> :a
          ["Bearer synthetic-discovery-principal-b"] -> :b
          ["Bearer synthetic-discovery-principal-c"] -> :c
          [] -> :missing
          _ -> :unrelated
        end

      Agent.update(opts[:requests], &[{conn.method, conn.request_path, principal} | &1])

      if conn.method == "GET" and String.ends_with?(conn.request_path, "/models") and
           principal in [:a, :b, :c] do
        context = %{a: 32_768, b: 65_536, c: 98_304}[principal]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{"id" => "shared", "context_length" => context},
              %{"id" => "principal-#{principal}"}
            ]
          })
        )
      else
        Plug.Conn.send_resp(conn, 401, "credential unavailable")
      end
    end
  end

  # Shared by the retained regression and the no-ExUnit standalone consumer.
  # The caller supplies an isolated temporary home; built-in credential scopes
  # are explicitly unavailable so the probe never discovers hosted presets.
  def run!(home) do
    provider = "discovery-pool-#{System.unique_integer([:positive])}"
    saved_env = Map.new(env_names(), &{&1, System.get_env(&1)})
    saved_req = Req.default_options()
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
      System.put_env(@pool_env, @key_a)
      System.put_env(@other_env, @key_b)
      System.put_env("OPENAI_API_KEY", "synthetic-unrelated-ambient-key")
      Req.default_options(Keyword.drop(saved_req, [:plug, :adapter, :base_url]))
      {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

      provider_cfg = %{
        api: "openai_completions",
        base_url: "http://127.0.0.1:#{port}/v1",
        discovery: "openai",
        api_key: @key_b,
        headers: %{"X-Team" => "pool-consumer"}
      }

      routing = %{
        default_pool: "other",
        default_profile: "selected",
        profiles: %{
          "selected" => %{credential_pool: "selected"},
          "other" => %{credential_pool: "other"}
        },
        credential_pools: %{
          "selected" => %{credentials: %{provider => [%{source: :env, name: @pool_env}]}},
          "other" => %{credentials: %{provider => [%{source: :env, name: @other_env}]}}
        }
      }

      unavailable_secret = "unconfigured-#{provider}"

      providers =
        ProviderNames.all_canonical_names()
        |> Enum.reject(&ProviderNames.keyless?/1)
        |> Map.new(fn id ->
          {id,
           %{
             auth_source: "oauth",
             api_key_secret: unavailable_secret,
             oauth_secret: unavailable_secret
           }}
        end)
        |> Map.put(provider, provider_cfg)

      cfg = %{providers: providers, agent: %{provider_routing: routing}}
      selected_a = catalog(cfg, provider)
      check_models!(selected_a, :a, 32_768)
      check_requests!(requests, [{"GET", "/v1/models", :a}])

      # Settings carry routing at the top level. Selection and cache lookup must
      # preserve it, including native provider:id and provider/id consumers.
      settings =
        struct!(CodingAgent.SettingsManager,
          providers: cfg.providers,
          provider_routing: routing,
          default_model: %{provider: provider, model_id: "shared"}
        )

      check_models!(catalog(settings, provider), :a, 32_768)
      check_native!(settings, provider, 32_768)
      check_requests!(requests, [{"GET", "/v1/models", :a}])

      pool_only_provider =
        provider_cfg
        |> Map.delete(:api_key)
        |> Map.put(:base_url, "http://127.0.0.1:#{port}/pool-only/v1")

      pool_only_cfg = %{cfg | providers: Map.put(cfg.providers, provider, pool_only_provider)}

      check_models!(catalog(pool_only_cfg, provider), :a, 32_768)

      check!(
        CustomProviders.lookup(pool_only_cfg, provider, "shared").context_window == 32_768,
        "pool-only cache metadata was lost"
      )

      selected_b_cfg = put_in(cfg.agent.provider_routing.default_profile, "other")
      selected_b = catalog(selected_b_cfg, provider)
      check_models!(selected_b, :b, 65_536)
      check_models!(catalog(cfg, provider), :a, 32_768)

      check_native!(
        %{settings | provider_routing: selected_b_cfg.agent.provider_routing},
        provider,
        65_536
      )

      check_requests!(requests, [
        {"GET", "/v1/models", :a},
        {"GET", "/pool-only/v1/models", :a},
        {"GET", "/v1/models", :b}
      ])

      System.put_env(@pool_env, @key_c)

      check!(
        CustomProviders.lookup(cfg, provider, "shared").context_window == 128_000,
        "rotated principal reused another principal's metadata"
      )

      check_models!(catalog(cfg, provider), :c, 98_304)
      check_native!(settings, provider, 98_304)

      # The explicit default candidate remains part of shared request semantics.
      # An absent A may select configured B; it must not walk an unrelated pool.
      System.delete_env(@pool_env)
      check_models!(catalog(cfg, provider), :b, 65_536)
      check_native!(settings, provider, 65_536)

      missing_cfg = %{
        cfg
        | providers: Map.put(cfg.providers, provider, Map.delete(provider_cfg, :api_key))
      }

      check!(catalog(missing_cfg, provider) == [], "missing selected scope exposed other models")

      check!(
        CustomProviders.lookup(missing_cfg, provider, "shared").context_window == 128_000,
        "missing selected scope reused another principal's metadata"
      )

      expected_requests = [
        {"GET", "/v1/models", :a},
        {"GET", "/pool-only/v1/models", :a},
        {"GET", "/v1/models", :b},
        {"GET", "/v1/models", :c},
        {"GET", "/v1/models", :missing}
      ]

      check_requests!(requests, expected_requests)

      keys = cache_keys(provider)
      cache_records = Enum.map(keys, &{&1, LemonAi.ModelCache.read(&1)})
      public_and_cache = :erlang.term_to_binary({selected_a, selected_b, cache_records})

      for key <- [@key_a, @key_b, @key_c, "synthetic-unrelated-ambient-key"] do
        check!(
          :binary.match(public_and_cache, key) == :nomatch,
          "resolved credential leaked into model/cache metadata"
        )
      end

      %{
        checks: [
          :selected_pool_over_default,
          :settings_routing_and_native_resolution,
          :pool_only_discovery,
          :principal_cache_isolation,
          :credential_rotation,
          :explicit_default_candidate,
          :missing_scope_excludes_other_pool_and_ambient_key,
          :credential_redaction
        ],
        loopback_requests: length(expected_requests),
        principals: [:a, :b, :c, :missing]
      }
    after
      Supervisor.stop(server)
      Agent.stop(requests)
      Enum.each(cache_keys(provider), &LemonAi.ModelCache.invalidate/1)
      Req.default_options(saved_req)

      Enum.each(saved_env, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end
  end

  defp catalog(cfg, provider) do
    ModelCatalog.available_models(config: cfg)
    |> Enum.filter(&(&1.provider == provider))
  end

  defp check_models!(models, principal, context) do
    check!(
      Enum.sort(Enum.map(models, & &1.id)) == ["principal-#{principal}", "shared"],
      "catalog returned models for the wrong principal"
    )

    check!(
      Enum.find(models, &(&1.id == "shared")).context_window == context,
      "catalog returned metadata for the wrong principal"
    )
  end

  defp check_native!(settings, provider, context) do
    for selector <- [nil, "#{provider}:shared", "#{provider}/shared"] do
      model = CodingAgent.Session.ModelResolver.resolve_session_model(selector, settings)

      check!(
        model.provider == provider and model.context_window == context,
        "native resolution lost the selected discovery scope"
      )
    end
  end

  defp check_requests!(requests, expected) do
    check!(
      Agent.get(requests, &Enum.reverse/1) == expected,
      "loopback requests violated credential selection or cache isolation"
    )
  end

  defp check!(true, _message), do: :ok
  defp check!(false, message), do: raise(message)

  defp cache_keys(provider) do
    Enum.filter(LemonAi.ModelCache.stats().providers, fn
      {_kind, ^provider, _url, _api, _digest} -> true
      _ -> false
    end)
  end

  defp env_names do
    provider_env = Enum.flat_map(ProviderNames.all_canonical_names(), &ProviderNames.env_vars/1)
    preset_env = Enum.flat_map(LemonAi.Models.Presets.all(), & &1.base_url_env)

    Enum.uniq(
      provider_env ++
        preset_env ++
        [
          @pool_env,
          @other_env,
          "HOME",
          "GOOGLE_APPLICATION_CREDENTIALS",
          "AWS_PROFILE",
          "AWS_ACCESS_KEY_ID",
          "AWS_SECRET_ACCESS_KEY"
        ]
    )
  end
end
