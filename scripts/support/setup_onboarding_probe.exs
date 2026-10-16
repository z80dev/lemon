defmodule LemonScripts.SetupOnboardingProbe do
  @moduledoc false

  alias LemonCli.Setup.{Provider, Verification, Wizard}

  # Exercise real public setup provider and wizard callers with deterministic
  # API-key onboarding, local config, and actual Httpc rather than a verifier.
  def run(root, entry, live? \\ true, opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    owner = self()
    server = spawn(fn -> serve(listener, owner) end)
    path = Path.join(root, "onboarding_#{entry}.toml")
    url = "http://127.0.0.1:#{port}/v1"
    provider = Keyword.get(opts, :provider, "openai")
    model = Keyword.get(opts, :model, "gpt-5")

    previous =
      Map.new(
        ~w(OPENAI_BASE_URL OPENAI_API_KEY QWEN_BASE_URL QWEN_API_KEY LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL),
        &{&1, System.get_env(&1)}
      )

    System.put_env("OPENAI_BASE_URL", url)
    System.put_env("QWEN_BASE_URL", url)

    Enum.each(
      ~w(OPENAI_API_KEY QWEN_API_KEY LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL),
      &System.delete_env/1
    )

    if override = opts[:effective_model], do: System.put_env("LEMON_DEFAULT_MODEL", override)

    declaration =
      if native_model = opts[:native_model],
        do: "\n[[providers.#{provider}.models]]\nid = \"#{native_model}\"\n",
        else: ""

    File.write!(
      path,
      """
      [providers.#{provider}]
      base_url = "#{url}"
      [providers.#{provider}.headers]
      X-Verification-Scope = "fixture-provider-scope"
      """ <> declaration
    )

    io = %{
      info: fn msg -> send(owner, {:setup_event, msg}) end,
      error: fn msg -> send(owner, {:setup_event, msg}) end,
      prompt: fn _ -> "" end,
      secret: fn _ -> "" end
    }

    try do
      result =
        case entry do
          :provider ->
            Provider.run(
              [
                "--provider",
                provider,
                "--token",
                "fixture-onboarded-access",
                "--secret-name",
                "setup_onboarded_#{entry}",
                "--config-path",
                path,
                "--set-default",
                "--model",
                model,
                "--non-interactive"
              ],
              io,
              live_verify: live?
            )

          :wizard ->
            Wizard.run_full([], io,
              config_path: path,
              provider: provider,
              token: "fixture-onboarded-access",
              model: model,
              non_interactive: true,
              skip_verify: not live?
            )
        end

      bound =
        Verification.verification_options(
          config_path: path,
          skip_verify: not live?
        )

      expected_id = opts[:expected_model] || opts[:effective_model] || model
      records = drain([])
      wire = for {:onboarding_wire, bytes} <- records, do: bytes
      events = for {:setup_event, msg} <- records, do: msg

      %{
        requests: length(wire),
        success: result == :ok,
        verification_failed: result == {:error, :verification_failed},
        exact_model_id: match?(%{id: ^expected_id}, bound[:verification_model]),
        correct_access:
          wire != [] and
            Enum.all?(
              wire,
              &String.contains?(&1, "authorization: Bearer fixture-onboarded-access\r\n")
            ),
        correct_scope_header:
          wire != [] and
            Enum.all?(
              wire,
              &(String.downcase(&1) =~ "x-verification-scope: fixture-provider-scope\r\n")
            ),
        models_get:
          wire != [] and Enum.all?(wire, &String.starts_with?(&1, "GET /v1/models HTTP/")),
        event_credential_leak:
          Enum.any?(events, &String.contains?(&1, ["fixture-onboarded-access", "refresh_token"]))
      }
    after
      :gen_tcp.close(listener)
      Process.exit(server, :kill)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp serve(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        bytes = headers(socket, "")
        send(owner, {:onboarding_wire, bytes})
        body = ~s({"data":[{"id":"gpt-5"}]})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
        serve(listener, owner)

      {:error, _} ->
        :ok
    end
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

  defp drain(acc) do
    receive do
      {:onboarding_wire, _} = msg -> drain([msg | acc])
      {:setup_event, _} = msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
