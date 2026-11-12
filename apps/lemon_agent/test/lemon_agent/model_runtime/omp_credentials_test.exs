defmodule LemonAgent.ModelRuntime.OmpCredentialsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, ProviderStatus, StreamOptions}
  alias LemonAi.EventStream
  alias LemonAi.Types.{Context, Model, UserMessage}

  setup do
    dir = Path.join(System.tmp_dir!(), "omp_credentials_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".lemon"))
    env = Map.new(["KIMI_API_KEY", "MOONSHOT_API_KEY"], &{&1, System.get_env(&1)})
    System.put_env("KIMI_API_KEY", "ignored-env-key")
    System.put_env("MOONSHOT_API_KEY", "ignored-moonshot-key")

    on_exit(fn ->
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(dir)
    end)

    %{dir: dir, path: Path.join(dir, "omp")}
  end

  test "omp is authoritative over env and inline credentials, and readiness uses its JWT", %{
    path: path
  } do
    token = jwt("original")

    script(path, """
    test -z "${KIMI_API_KEY+x}" && test -z "${MOONSHOT_API_KEY+x}"
    printf '%s' '#{token}'
    """)

    providers = config(path)
    assert Credentials.resolve_provider_api_key(:kimi_coding, providers) == token
    assert Credentials.provider_has_credentials?(:kimi_coding, providers)

    assert [%{ref: "default", api_key: ^token}] =
             Credentials.list_provider_api_keys(providers, :kimi_coding)
  end

  test "failed omp resolution refuses before the Anthropic request boundary", %{
    path: path,
    dir: dir
  } do
    script(path, "printf 'private diagnostic' >&2; exit 2")
    providers = config(path)
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, :http_attempt)

      Plug.Conn.send_resp(
        conn,
        401,
        Jason.encode!(%{"error" => %{"message" => "Unexpected HTTP request."}})
      )
    end)

    model = %Model{
      id: "kimi-for-coding",
      provider: :kimi_coding,
      api: :anthropic_messages,
      base_url: "http://127.0.0.1"
    }

    options =
      StreamOptions.build_stream_options(model, providers, %{api_key: "stale-caller-key"}, dir)

    context = %Context{messages: [%UserMessage{content: "Fixture request."}]}

    private_values = [
      "private diagnostic",
      "ignored-env-key",
      "ignored-moonshot-key",
      "ignored-inline-key",
      "stale-caller-key",
      path
    ]

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        # Apply the per-request callback result just as Loop.Streaming does.
        resolved_key = Credentials.build_get_api_key(providers).(model.provider)
        assert resolved_key == ""
        options = %{options | api_key: resolved_key}

        assert {:ok, stream} = LemonAi.stream(model, context, options)

        try do
          assert {:error, error} = EventStream.result(stream, 1_000)
          assert error.stop_reason == :error
          assert error.error_message =~ "A resolved credential is required"

          Enum.each(private_values, fn value ->
            refute inspect(error) =~ value
          end)
        after
          EventStream.cancel(stream, :test_complete)
        end

        refute_received :http_attempt
      end)

    assert logs =~ "/login kimi-code"
    Enum.each(private_values, fn value -> refute logs =~ value end)
  end

  test "401 refresh callback forces omp refresh and subsequent resolution uses new token", %{
    path: path
  } do
    original = jwt("original")
    fresh = jwt("fresh")
    script(path, "printf '%s' '#{original}'")
    providers = config(path)
    assert Credentials.resolve_provider_api_key(:kimi_coding, providers) == original
    script(path, "test \"$3\" = --force-refresh; printf '%s' '#{fresh}'")

    assert {:ok, ^fresh} =
             Credentials.refresh_provider_api_key(providers, :kimi_coding, "default", original)

    assert Credentials.resolve_provider_api_key(:kimi_coding, providers) == fresh
  end

  test "provider status reports omp readiness without exposing token or executable path", %{
    path: path,
    dir: dir
  } do
    token = jwt("status")
    script(path, "printf '%s' '#{token}'")

    File.write!(Path.join(dir, ".lemon/config.toml"), """
    [providers.kimi_coding]
    auth_source = "omp"
    omp_path = #{Jason.encode!(path)}
    """)

    snapshot = ProviderStatus.snapshot(%{"projectDir" => dir, "provider" => "kimi_coding"})
    status = Enum.find(snapshot["providers"], &(&1["provider"] == "kimi_coding"))
    assert status["credentialReady"]
    assert status["config"]["authSource"] == "omp"
    refute inspect(snapshot) =~ token
    refute inspect(snapshot) =~ path
  end

  defp config(path) do
    %{"kimi_coding" => %{auth_source: "omp", omp_path: path, api_key: "ignored-inline-key"}}
  end

  defp jwt(sub) do
    claims = Jason.encode!(%{"exp" => System.system_time(:second) + 3600, "sub" => sub})
    "eyJhbGciOiJIUzI1NiJ9." <> Base.url_encode64(claims, padding: false) <> ".signature"
  end

  defp script(path, body) do
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body <> "\n")
    File.chmod!(path, 0o700)
  end
end
