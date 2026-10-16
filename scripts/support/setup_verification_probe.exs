defmodule LemonScripts.SetupVerificationProbe do
  @moduledoc false
  alias LemonCli.Setup.Verification
  alias LemonCore.Secrets

  def log(event, %{config: %{owner: owner}}), do: send(owner, {:verification_log, event})

  # Both endpoints are real local HTTP servers. The registry preset uses A;
  # the configured provider uses B. No verifier or HTTP transport is replaced.
  def run(root, scenario, provider \\ :litellm, config_source \\ :effective) do
    provider_name = Atom.to_string(provider)
    env_name = if provider == :xai, do: "XAI_API_KEY", else: "LITELLM_API_KEY"
    default_secret = "llm_#{provider_name}_api_key"
    selected = "setup_selected_#{provider}_#{scenario}"
    payload = payload(scenario)
    if payload, do: set_secret(selected, Jason.encode!(payload))

    if scenario == :keyless do
      Secrets.delete(default_secret)
      System.delete_env(env_name)
    else
      set_secret(default_secret, "fixture-default-wrong-principal")
      System.put_env(env_name, "fixture-env-wrong-principal")
    end

    System.put_env(selected, "fixture-legacy-wrong-principal")
    {a, a_url, a_server} = endpoint(:registry)
    {b, b_url, b_server} = endpoint(:configured)
    previous_url = System.get_env("LITELLM_BASE_URL")
    System.put_env("LITELLM_BASE_URL", a_url)
    # A regression must never reach the fixed xAI registry URL. A local HTTPS
    # proxy trap receives CONNECT but never opens an upstream connection.
    proxy_options =
      if provider == :xai do
        :ok = LemonCore.Httpc.ensure_started()
        {:ok, previous} = :httpc.get_options([:https_proxy])
        :ok = :httpc.set_options(https_proxy: {{~c"127.0.0.1", URI.parse(a_url).port}, []})
        previous
      end

    static =
      if scenario in [:raw_success, :encoded], do: "", else: "fixture-static-wrong-principal"

    keyless? = scenario == :keyless

    provider_cfg =
      if keyless?,
        do: %{auth: "none", base_url: b_url},
        else: %{
          auth_source: "oauth",
          oauth_secret: selected,
          api_key: static,
          base_url: b_url,
          headers: %{"X-Verification-Scope" => "fixture-provider-scope"}
        }

    config = %{providers: %{provider_name => provider_cfg}, provider_routing: %{}}
    path = Path.join(root, "setup_#{provider}_#{scenario}.toml")

    model_id =
      if provider == :xai,
        do: hd(LemonAi.Models.get_models(:xai)).id,
        else: "fixture-model"

    credential_toml =
      if keyless?,
        do: "auth = \"none\"\n",
        else: "auth_source = \"oauth\"\noauth_secret = \"#{selected}\"\napi_key = \"#{static}\"\n"

    File.write!(
      path,
      "[defaults]\nprovider = \"#{provider_name}\"\nmodel = \"#{provider_name}:#{model_id}\"\n[providers.#{provider_name}]\nbase_url = \"#{b_url}\"\n#{credential_toml}[providers.#{provider_name}.headers]\nX-Verification-Scope = \"fixture-provider-scope\"\n"
    )

    handler = :setup_verification_probe
    :ok = :logger.add_handler(handler, __MODULE__, %{level: :all, config: %{owner: self()}})

    try do
      opts = [config_path: path, skip_verify: scenario == :skip]
      opts = if config_source == :file, do: opts, else: Keyword.put(opts, :config, config)
      result = Verification.verify_provider(opts)
      # The response cannot complete before the server has reported the wire.
      :logger.remove_handler(handler)
      records = drain([])
      wire = for {:verification_wire, scope, bytes} <- records, do: {scope, bytes}
      logs = for {:verification_log, event} <- records, do: inspect(event)
      bytes = Enum.map(wire, &elem(&1, 1))

      private = ["fixture-private-refresh", "fixture-expired-access"]

      %{
        requests: length(wire),
        registry_requests: Enum.count(wire, &(elem(&1, 0) == :registry)),
        configured_requests: Enum.count(wire, &(elem(&1, 0) == :configured)),
        correct_access:
          wire != [] and
            Enum.all?(
              bytes,
              &String.contains?(&1, "authorization: Bearer fixture-selected-access\r\n")
            ),
        correct_scope_header:
          wire != [] and
            Enum.all?(
              bytes,
              &(String.downcase(&1) =~ "x-verification-scope: fixture-provider-scope\r\n")
            ),
        models_get:
          wire != [] and Enum.all?(bytes, &String.starts_with?(&1, "GET /v1/models HTTP/")),
        keyless_wire:
          wire != [] and Enum.all?(bytes, &(not (String.downcase(&1) =~ "authorization:"))),
        wrong_principal: Enum.any?(bytes, &String.contains?(&1, "wrong-principal")),
        wire_credential_leak: Enum.any?(bytes, &String.contains?(&1, private)),
        log_credential_leak:
          Enum.any?(
            logs,
            &String.contains?(&1, private ++ ["fixture-selected-access", "wrong-principal"])
          ),
        event_credential_leak:
          String.contains?(
            inspect(result),
            private ++ ["fixture-selected-access", "wrong-principal"]
          ),
        success: match?({:ok, _}, result),
        live_ok: match?({:ok, %{live: :ok}}, result),
        disabled: match?({:ok, %{live: :disabled}}, result),
        refused: match?({:error, _}, result)
      }
    after
      if proxy_options, do: :httpc.set_options(proxy_options)
      :logger.remove_handler(handler)
      :gen_tcp.close(a)
      :gen_tcp.close(b)
      Process.exit(a_server, :kill)
      Process.exit(b_server, :kill)

      if previous_url,
        do: System.put_env("LITELLM_BASE_URL", previous_url),
        else: System.delete_env("LITELLM_BASE_URL")

      System.delete_env(selected)
    end
  end

  # Colon identity coverage uses actual public verification and local HTTP.
  # The bound model is observed too: GET /models alone cannot prove its id.
  def run_identity(root, scenario) do
    scoped? = scenario in [:scoped_native, :scoped_skip, :ambient_foreign]
    {listener, url, server} = endpoint(:configured, ["lm_studio:shared"])
    {ambient_listener, ambient_url, ambient_server} = endpoint(:ambient, ["lm_studio:shared"])

    previous =
      Map.new(
        ~w(LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL LITELLM_BASE_URL LITELLM_API_KEY),
        &{&1, System.get_env(&1)}
      )

    Enum.each(Map.keys(previous), &System.delete_env/1)
    System.put_env("LITELLM_BASE_URL", ambient_url)

    model_id =
      cond do
        scoped? -> "lm_studio:shared"
        scenario == :multiple -> "qwen3:32b:instruct"
        true -> "qwen3:32b"
      end

    provider =
      cond do
        scoped? -> "litellm"
        scenario in [:custom, :custom_qualified] -> "local-gateway"
        true -> "ollama"
      end

    model =
      case scenario do
        s when s in [:qualified, :env, :effective] -> "ollama:#{model_id}"
        :custom_qualified -> "LOCAL_GATEWAY:#{model_id}"
        :foreign -> "openai:gpt-4"
        :foreign_alias -> "codex:gpt-5"
        :foreign_custom -> "foreign_gateway:#{model_id}"
        :declared -> "openai:private:32b"
        _ -> model_id
      end

    cfg = %{
      api: "openai_completions",
      api_key: "fixture-identity-access",
      base_url: url,
      headers: %{"X-Verification-Scope" => "fixture-provider-scope"}
    }

    cfg = if scenario == :declared, do: Map.put(cfg, :models, [%{id: model}]), else: cfg
    providers = %{provider => cfg}

    providers =
      if scenario == :foreign_custom,
        do: Map.put(providers, "foreign-gateway", cfg),
        else: providers

    path = Path.join(root, "identity_#{scenario}.toml")

    declaration =
      if scenario == :declared,
        do: "\n[[providers.#{provider}.models]]\nid = \"#{model}\"\n",
        else: ""

    File.write!(
      path,
      """
      [defaults]
      provider = "#{provider}"
      model = "#{model}"
      [providers.#{provider}]
      api = "openai_completions"
      api_key = "fixture-identity-access"
      base_url = "#{url}"
      [providers.#{provider}.headers]
      X-Verification-Scope = "fixture-provider-scope"
      """ <> declaration
    )

    try do
      if scoped? do
        discovery_opts =
          if scenario in [:scoped_native, :scoped_skip],
            do: [base_url: url, api_key: cfg.api_key, headers: cfg.headers],
            else: [base_url: ambient_url, api_key: nil, headers: %{}]

        {:ok, discovered} =
          LemonAi.Models.discover_preset(
            :litellm,
            Keyword.put(discovery_opts, :force_refresh, true)
          )

        unless Enum.any?(discovered, &(&1.id == model_id)),
          do: raise("Scoped identity discovery fixture did not prime its real local cache")

        # Discovery requests are fixture preparation, not verification requests.
        drain([])
      end

      if scenario == :env, do: System.put_env("LEMON_DEFAULT_MODEL", model_id)
      opts = [config_path: path, skip_verify: scenario == :scoped_skip]

      opts =
        if scenario == :env do
          opts
        else
          effective_id = if scenario == :effective, do: model_id, else: model

          Keyword.put(opts, :config, %{
            providers: providers,
            agent: %{default_provider: provider, default_model: effective_id}
          })
        end

      bound = Verification.verification_options(opts)
      result = Verification.verify_provider(bound)
      records = drain([])
      wire = for {:verification_wire, :configured, bytes} <- records, do: bytes
      expected_id = if scenario == :declared, do: model, else: model_id

      %{
        live_ok: match?({:ok, %{live: :ok}}, result),
        disabled: match?({:ok, %{live: :disabled}}, result),
        retained_model: match?({:ok, %{model: ^model}}, result),
        mismatch: match?({:error, %{reason: :model_provider_mismatch}}, result),
        readiness_complete: Verification.setup_state(config_path: path).provider.complete,
        exact_model_id: match?(%{id: ^expected_id}, bound[:verification_model]),
        requests: Enum.count(records, &match?({:verification_wire, _, _}, &1)),
        models_get:
          wire != [] and Enum.all?(wire, &String.starts_with?(&1, "GET /v1/models HTTP/")),
        correct_access:
          wire != [] and
            Enum.all?(
              wire,
              &String.contains?(&1, "authorization: Bearer fixture-identity-access\r\n")
            ),
        correct_scope_header:
          wire != [] and
            Enum.all?(
              wire,
              &(String.downcase(&1) =~ "x-verification-scope: fixture-provider-scope\r\n")
            ),
        event_credential_leak: String.contains?(inspect(result), "fixture-identity-access")
      }
    after
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
      :gen_tcp.close(ambient_listener)
      Process.exit(ambient_server, :kill)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp payload(scenario) when scenario in [:success, :raw_success, :skip],
    do: %{
      "type" => "xai_oauth",
      "access_token" => "fixture-selected-access",
      "refresh_token" => "fixture-private-refresh",
      "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
    }

  # No refresh token: canonical resolution refuses without vendor network.
  defp payload(:expired),
    do: %{"type" => "xai_oauth", "access_token" => "fixture-expired-access", "expires_at_ms" => 1}

  defp payload(:encoded),
    do: %{
      "type" => "xai_oauth",
      "refresh_token" => "",
      "private_marker" => "fixture-private-refresh"
    }

  defp payload(_), do: nil

  defp set_secret(name, value) do
    {:ok, _} = Secrets.set(name, value)
  end

  defp endpoint(scope, ids \\ ["fixture-model"]) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    owner = self()
    server = spawn(fn -> serve(listener, scope, owner, ids) end)
    {listener, "http://127.0.0.1:#{port}/v1", server}
  end

  defp serve(listener, scope, owner, ids) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        bytes = receive_headers(socket, "")
        send(owner, {:verification_wire, scope, bytes})
        body = Jason.encode!(%{data: Enum.map(ids, &%{id: &1})})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
        serve(listener, scope, owner, ids)

      {:error, _} ->
        :ok
    end
  end

  defp receive_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, bytes} -> receive_headers(socket, acc <> bytes)
        {:error, _} -> acc
      end
    end
  end

  defp drain(acc) do
    receive do
      {:verification_wire, _, _} = entry -> drain([entry | acc])
      {:verification_log, _} = entry -> drain([entry | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
