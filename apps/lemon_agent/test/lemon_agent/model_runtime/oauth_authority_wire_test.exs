Code.require_file(
  Path.expand("../../../../../scripts/support/oauth_authority_probe.exs", __DIR__)
)

defmodule LemonAgent.ModelRuntime.OAuthAuthorityWireTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, StreamOptions}
  alias LemonAi.Types.{Context, Model, UserMessage}
  alias LemonCore.Secrets
  alias LemonScripts.OAuthAuthorityProbe

  @providers [:xai, :github_copilot, :kimi_coding, :anthropic]
  @scenarios [:missing, :env_only, :expired, :encoded, :success]
  @env ~w(HOME LEMON_SECRETS_MASTER_KEY XAI_API_KEY GITHUB_COPILOT_API_KEY KIMI_API_KEY MOONSHOT_API_KEY ANTHROPIC_API_KEY) ++
         for(
           provider <- @providers,
           scenario <- @scenarios,
           do: "selected_#{provider}_#{scenario}"
         )

  setup do
    root =
      Path.join(System.tmp_dir!(), "oauth_authority_wire_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    paths = Application.fetch_env(:lemon_core, :paths)
    System.put_env("HOME", root)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, :paths, home_dir: root)
    clear_secrets()

    on_exit(fn ->
      clear_secrets()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case paths do
        {:ok, value} -> Application.put_env(:lemon_core, :paths, value)
        :error -> Application.delete_env(:lemon_core, :paths)
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  for provider <- @providers, scenario <- @scenarios do
    @provider provider
    @scenario scenario
    test "#{provider} #{scenario} retains selected credential authority on the real runtime wire",
         %{root: root} do
      result = OAuthAuthorityProbe.run(root, @provider, @scenario)
      refute result.credential_leak
      refute result.wrong_principal

      if @scenario == :success do
        assert result.requests == 1
        assert result.selected_authority
        assert result.answered
        refute result.refused
      else
        assert result.requests == 0
        assert result.refused
        refute result.answered
      end
    end
  end

  for api <- [:openai_completions, :openai_responses, :anthropic_messages, :google_generative_ai],
      key <- [nil, ""],
      keyless <- [false, true] do
    @api api
    @key key
    @keyless keyless
    test "#{api} authoritative #{inspect(key)} refuses before HTTP with keyless=#{keyless}", %{
      root: root
    } do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
      url = "http://127.0.0.1:#{port}/v1"
      System.put_env("XAI_API_KEY", "fixture-wrong-principal")
      System.put_env("ANTHROPIC_API_KEY", "fixture-wrong-principal")

      provider_config = %{
        "xai" => %{
          auth_source: "oauth",
          oauth_secret: "missing_login",
          api_key: "fixture-static",
          base_url: url
        }
      }

      model = %Model{
        id: "authority-fixture",
        provider: :xai,
        api: @api,
        base_url: url,
        compat: %{allow_missing_api_key: @keyless}
      }

      options =
        StreamOptions.build_stream_options(
          model,
          provider_config,
          %{api_key: "fixture-stale"},
          root
        )

      # Exercise map normalization as well as the final public protocol boundary.
      options = options |> Map.from_struct() |> Map.put(:api_key, @key)
      context = %Context{messages: [%UserMessage{content: "Fixture request."}]}
      assert {:error, error} = LemonAi.complete(model, context, options)
      assert LemonAi.Error.classify(error) == :auth
      assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
      refute inspect(error) =~ "fixture-"
    end
  end

  test "failed credential callback overrides a stale selected token before public runtime dispatch",
       %{root: root} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    model = %Model{
      id: "authority-fixture",
      provider: :xai,
      api: :openai_completions,
      base_url: "http://127.0.0.1:#{port}/v1"
    }

    providers = %{"xai" => %{auth_source: "oauth", oauth_secret: "missing_login"}}
    options = StreamOptions.build_stream_options(model, providers, nil, root)
    options = %{options | api_key: "fixture-stale-selected-token"}

    config = %LemonAgent.Types.AgentLoopConfig{
      model: model,
      convert_to_llm: &Function.identity/1,
      get_api_key: Credentials.build_get_api_key(providers),
      stream_options: options,
      max_retries: 0
    }

    events =
      LemonAgent.agent_loop(
        [%UserMessage{content: "Fixture request."}],
        %LemonAgent.Types.AgentContext{},
        config
      )
      |> Enum.to_list()

    assert Enum.any?(
             events,
             &match?({:message_end, %{role: :assistant, stop_reason: :error}}, &1)
           )

    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
    refute inspect(events) =~ "fixture-stale-selected-token"
  end

  test "credential-aware resolver output cannot send a failed encoded login as Bearer JSON", %{
    root: root
  } do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    url = "http://127.0.0.1:#{port}/v1"

    {:ok, _} =
      Secrets.set(
        "failed_payload",
        Jason.encode!(%{
          "type" => "xai_oauth",
          "refresh_token" => "",
          "private_marker" => "fixture-private"
        })
      )

    System.put_env("XAI_API_KEY", "fixture-wrong-principal")

    resolved =
      LemonAgent.ProviderConfigResolver.resolve_for_provider(:xai, %{
        cwd: root,
        provider_config: %{
          auth_source: "oauth",
          api_key_secret: "failed_payload",
          api_key: "fixture-static",
          base_url: url
        }
      })

    model = %Model{
      id: "authority-fixture",
      provider: :xai,
      api: :openai_completions,
      base_url: url
    }

    assert {:error, error} =
             LemonAi.complete(
               model,
               %Context{messages: [%UserMessage{content: "Fixture request."}]},
               resolved
             )

    assert LemonAi.Error.classify(error) == :auth
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
    refute inspect(error) =~ "fixture-private"
  end

  test "unavailable selected pool A still dispatches the explicitly configured default B", %{
    root: root
  } do
    System.delete_env("XAI_API_KEY")

    {:ok, _} =
      Secrets.set(
        "failed_pool_login",
        Jason.encode!(%{"type" => "xai_oauth", "refresh_token" => ""})
      )

    {listener, url} = endpoint(:openai_completions)

    model = %Model{
      id: "authority-fixture",
      provider: :xai,
      api: :openai_completions,
      base_url: url
    }

    config = %{
      providers: %{"xai" => %{auth_source: "api_key", api_key: "fixture-defaultB", base_url: url}},
      provider_routing: %{
        default_pool: "poolA",
        credential_pools: %{"poolA" => %{credentials: %{"xai" => ["secret:failed_pool_login"]}}}
      }
    }

    options = StreamOptions.build_stream_options(model, config.providers, nil, root)
    options = %{options | api_key: Credentials.build_get_api_key(config).(:xai)}

    assert {:ok, _} =
             LemonAi.complete(
               model,
               %Context{messages: [%UserMessage{content: "Fixture request."}]},
               options
             )

    assert_receive {:wire, wire}
    assert wire =~ "Bearer fixture-defaultB"
    refute wire =~ "refresh_token"
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
  end

  for provider <- [:anthropic, :kimi_coding], key <- [nil, ""] do
    @provider provider
    @key key
    test "direct #{@provider} #{@key |> inspect()} retains exact-target environment resolution" do
      env = if @provider == :anthropic, do: "ANTHROPIC_API_KEY", else: "KIMI_API_KEY"
      System.put_env("ANTHROPIC_API_KEY", "fixture-other-principal")
      System.put_env(env, "fixture-exact-target")
      {_listener, url} = endpoint(:anthropic_messages)

      model = %Model{
        id: "authority-fixture",
        provider: @provider,
        api: :anthropic_messages,
        base_url: url
      }

      assert {:ok, _} =
               LemonAi.complete(
                 model,
                 %Context{messages: [%UserMessage{content: "Fixture request."}]},
                 %{api_key: @key}
               )

      assert_receive {:wire, wire}
      assert String.downcase(wire) =~ "x-api-key: fixture-exact-target"
      refute wire =~ "fixture-other-principal"
    end
  end

  test "ordinary keyless direct requests remain keyless with an explicit empty key" do
    System.put_env("ANTHROPIC_API_KEY", "fixture-other-principal")
    {_listener, url} = endpoint(:anthropic_messages)

    model = %Model{
      id: "authority-fixture",
      provider: "local-keyless",
      api: :anthropic_messages,
      base_url: url,
      compat: %{allow_missing_api_key: true}
    }

    assert {:ok, _} =
             LemonAi.complete(
               model,
               %Context{messages: [%UserMessage{content: "Fixture request."}]},
               %{api_key: ""}
             )

    assert_receive {:wire, wire}
    refute String.downcase(wire) =~ "authorization:"
    refute String.downcase(wire) =~ "x-api-key:"
    refute wire =~ "fixture-other-principal"
  end

  for destination <- [:ordinary, :keyless], input <- [:struct, :map] do
    @destination destination
    @input input
    test "public live provider switch leaves selected OAuth for #{@destination} using #{@input} options",
         %{root: root} do
      {:ok, old_listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(old_listener) end)
      {:ok, {{127, 0, 0, 1}, old_port}} = :inet.sockname(old_listener)
      {_listener, destination_url} = endpoint(:anthropic_messages)
      System.put_env("ANTHROPIC_API_KEY", "fixture-destination-key")
      destination_provider = if @destination == :ordinary, do: :anthropic, else: "local-keyless"

      destination_config = %{
        base_url: destination_url,
        headers: %{"x-destination" => "fixture-target"}
      }

      destination_config =
        if @destination == :ordinary,
          do: Map.put(destination_config, :auth_source, "api_key"),
          else: Map.put(destination_config, :auth, "none")

      providers = %{
        "xai" => %{auth_source: "oauth", oauth_secret: "missing_login"},
        to_string(destination_provider) => destination_config
      }

      previous = %Model{
        id: "previous-fixture",
        provider: :xai,
        api: :openai_completions,
        base_url: "http://127.0.0.1:#{old_port}/v1"
      }

      destination_model = %Model{
        id: "destination-fixture",
        provider: destination_provider,
        api: :anthropic_messages,
        base_url: destination_url,
        headers: %{"x-destination" => "fixture-target"},
        compat: %{allow_missing_api_key: @destination == :keyless}
      }

      previous_options = StreamOptions.build_stream_options(previous, providers, nil, root)

      previous_options = %{
        previous_options
        | api_key: "fixture-old-selected-token",
          headers: %{"authorization" => "Bearer fixture-old-selected-token"}
      }

      input = @input

      rebuild = fn next, _previous, options ->
        options = if input == :map, do: Map.from_struct(options), else: options
        options = StreamOptions.sanitize_for_provider_switch(options)
        StreamOptions.build_stream_options(next, providers, options, root)
      end

      config = %LemonAgent.Types.AgentLoopConfig{
        model: previous,
        get_model: fn -> destination_model end,
        resolve_stream_options: rebuild,
        convert_to_llm: &Function.identity/1,
        get_api_key: Credentials.build_get_api_key(providers),
        stream_options: previous_options,
        max_retries: 0
      }

      events =
        LemonAgent.agent_loop(
          [%UserMessage{content: "Fixture request."}],
          %LemonAgent.Types.AgentContext{},
          config
        )
        |> Enum.to_list()

      assert Enum.any?(events, fn
               {:message_end,
                %{
                  role: :assistant,
                  stop_reason: :stop,
                  content: [%LemonAi.Types.TextContent{text: "Fixture answer."}]
                }} ->
                 true

               _ ->
                 false
             end)

      assert_receive {:wire, wire}
      assert String.downcase(wire) =~ "x-destination: fixture-target"
      refute wire =~ "fixture-old-selected-token"

      if @destination == :ordinary do
        assert String.downcase(wire) =~ "x-api-key: fixture-destination-key"
      else
        refute String.downcase(wire) =~ "authorization:"
        refute String.downcase(wire) =~ "x-api-key:"
      end

      assert {:error, :timeout} = :gen_tcp.accept(old_listener, 50)
    end
  end

  for provider <- [:kimi, :kimi_coding] do
    @provider provider
    test "direct #{@provider} refuses a foreign-only Anthropic environment before real HTTP" do
      System.delete_env("KIMI_API_KEY")
      System.delete_env("MOONSHOT_API_KEY")
      System.put_env("ANTHROPIC_API_KEY", "fixture-foreign-principal")
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

      model = %Model{
        id: "authority-fixture",
        provider: @provider,
        api: :anthropic_messages,
        base_url: "http://127.0.0.1:#{port}/v1"
      }

      assert {:error, _} =
               LemonAi.complete(
                 model,
                 %Context{messages: [%UserMessage{content: "Fixture request."}]},
                 %{}
               )

      assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
    end
  end

  defp endpoint(api) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    owner = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        wire = receive_request(socket, "")
        send(owner, {:wire, wire})

        body =
          if api == :anthropic_messages do
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{}}}\n\n" <>
              "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" <>
              "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fixture answer.\"}}\n\n" <>
              "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" <>
              "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{}}\n\n" <>
              "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
          else
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Fixture answer.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
          end

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    {listener, "http://127.0.0.1:#{port}/v1"}
  end

  defp receive_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] ->
        [_, length] = Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length) do
          buffer
        else
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
          receive_request(socket, buffer <> bytes)
        end

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
        receive_request(socket, buffer <> bytes)
    end
  end

  defp clear_secrets do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
