defmodule LemonScripts.SetupVerificationProbe do
  @moduledoc false
  alias LemonCore.Secrets
  alias LemonCli.Setup.Verification

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

  defp endpoint(scope) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    owner = self()
    server = spawn(fn -> serve(listener, scope, owner) end)
    {listener, "http://127.0.0.1:#{port}/v1", server}
  end

  defp serve(listener, scope, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        bytes = receive_headers(socket, "")
        send(owner, {:verification_wire, scope, bytes})
        body = ~s({"data":[{"id":"fixture-model"}]})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
        serve(listener, scope, owner)

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
