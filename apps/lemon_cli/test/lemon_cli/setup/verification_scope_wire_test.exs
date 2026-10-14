defmodule LemonCli.Setup.VerificationScopeWireTest do
  use ExUnit.Case, async: false

  alias LemonCli.Setup.Verification
  alias LemonCore.Secrets

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "setup_verification_scope_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_key = System.get_env("XAI_API_KEY")
    original_secrets = Application.fetch_env(:lemon_core, Secrets)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env("XAI_API_KEY", "fixture-ambient-wrong-principal")
    Application.put_env(:lemon_core, Secrets, key_providers: [:env])
    clear_secrets()

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    owner = self()

    server =
      spawn(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, socket} ->
            send(owner, {:scope_wire, headers(socket, "")})
            body = ~s({"data":[]})

            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
                body
            )

            :gen_tcp.close(socket)

          {:error, _} ->
            :ok
        end
      end)

    # Even a regression to registry URLs remains on the local proxy trap.
    :ok = LemonCore.Httpc.ensure_started()
    {:ok, previous_proxy} = :httpc.get_options([:https_proxy])
    :ok = :httpc.set_options(https_proxy: {{~c"127.0.0.1", port}, []})
    model_id = hd(LemonAi.Models.get_models(:xai)).id
    path = Path.join(root, "config.toml")
    url = "http://127.0.0.1:#{port}/v1"

    File.write!(
      path,
      "[defaults]\nprovider = \"xai\"\nmodel = \"xai:#{model_id}\"\n[providers.xai]\nauth_source = \"oauth\"\noauth_secret = \"scope_selected\"\napi_key = \"fixture-static-wrong-principal\"\nbase_url = \"#{url}\"\n"
    )

    on_exit(fn ->
      :httpc.set_options(previous_proxy)
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
      clear_secrets()
      restore_system("LEMON_SECRETS_MASTER_KEY", original_master_key)
      restore_system("XAI_API_KEY", original_key)

      case original_secrets do
        {:ok, value} -> Application.put_env(:lemon_core, Secrets, value)
        :error -> Application.delete_env(:lemon_core, Secrets)
      end

      File.rm_rf!(root)
    end)

    config = %{
      providers: %{
        "xai" => %{
          auth_source: "oauth",
          oauth_secret: "scope_selected",
          api_key: "fixture-static-wrong-principal",
          base_url: url,
          headers: %{"X-Scope" => "provider", "X-Provider" => "retained"},
          models: [%{id: model_id, api: "openai_responses", headers: %{"x-sCOPE" => "model"}}]
        }
      },
      provider_routing: %{}
    }

    %{config: config, path: path}
  end

  test "healthy selected pool access precedes unavailable default login and preserves model headers",
       %{config: config, path: path} do
    set_oauth("scope_pool", "fixture-pool-access")
    set_failed_oauth("scope_selected")
    config = with_pool(config, "secret:scope_pool")

    assert {:ok, %{live: :ok}} = Verification.verify_provider(config_path: path, config: config)
    assert_receive {:scope_wire, wire}
    observed = observe_wire(wire, "fixture-pool-access")
    assert observed.models_get
    assert observed.correct_access
    assert observed.model_scope
    assert observed.provider_header
    refute observed.provider_scope
    refute observed.wrong_principal
    refute observed.credential_leak
  end

  test "unavailable pool entry retains separately configured usable selected default", %{
    config: config,
    path: path
  } do
    set_oauth("scope_selected", "fixture-default-access")
    set_failed_oauth("scope_pool")
    config = with_pool(config, "secret:scope_pool")

    assert {:ok, %{live: :ok}} = Verification.verify_provider(config_path: path, config: config)
    assert_receive {:scope_wire, wire}
    observed = observe_wire(wire, "fixture-default-access")
    assert observed.correct_access
    refute observed.wrong_principal
    refute observed.credential_leak
  end

  defp observe_wire(wire, access) do
    downcase = String.downcase(wire)

    %{
      models_get: String.starts_with?(wire, "GET /v1/models HTTP/"),
      correct_access: String.contains?(wire, "authorization: Bearer #{access}\r\n"),
      model_scope: String.contains?(downcase, "x-scope: model\r\n"),
      provider_scope: String.contains?(downcase, "x-scope: provider\r\n"),
      provider_header: String.contains?(downcase, "x-provider: retained\r\n"),
      wrong_principal: String.contains?(wire, "wrong-principal"),
      credential_leak: String.contains?(wire, ["refresh_token", "fixture-private-refresh"])
    }
  end

  defp with_pool(config, ref) do
    %{
      config
      | provider_routing: %{
          default_pool: "scope_pool",
          credential_pools: %{
            "scope_pool" => %{credentials: %{"xai" => [ref]}}
          }
        }
    }
  end

  defp set_oauth(name, access) do
    {:ok, _} =
      Secrets.set(
        name,
        Jason.encode!(%{
          "type" => "xai_oauth",
          "access_token" => access,
          "refresh_token" => "fixture-private-refresh",
          "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
        })
      )
  end

  defp set_failed_oauth(name) do
    {:ok, _} = Secrets.set(name, Jason.encode!(%{"type" => "xai_oauth", "refresh_token" => ""}))
  end

  defp headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, bytes} -> headers(socket, acc <> bytes)
        {:error, _} -> acc
      end
    end
  end

  defp restore_system(name, nil), do: System.delete_env(name)
  defp restore_system(name, value), do: System.put_env(name, value)

  defp clear_secrets do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
