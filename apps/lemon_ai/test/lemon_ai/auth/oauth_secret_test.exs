defmodule LemonAi.Auth.OAuthSecretTest do
  use ExUnit.Case, async: true

  alias LemonAi.Auth.OAuthSecret

  defmodule Resolver do
    defdelegate encode_secret(secret), to: OAuthSecret, as: :encode
    def decode_secret(value), do: OAuthSecret.decode(value, ["test_oauth"])
  end

  test "the shared codec preserves accepted types and ignores other payloads" do
    for type <- ["test_oauth", "legacy_oauth"] do
      secret = %{"type" => type, "access_token" => "token"}
      encoded = OAuthSecret.encode(secret)
      assert {:ok, ^secret} = OAuthSecret.decode(encoded, ["test_oauth", "legacy_oauth"])
    end

    for value <- [nil, 1, "not json", "[]", "{}", "null", ~s({"type":"other"})] do
      assert :not_oauth = Resolver.decode_secret(value)
    end
  end

  test "resolution retains invalid input and non-OAuth results" do
    spec = %{refresh: fn _ -> flunk("must not refresh") end, skew_ms: 0}

    assert {:error, :invalid_secret_value} = OAuthSecret.resolve(Resolver, nil, "key", [], spec)
    assert {:error, :invalid_secret_value} = OAuthSecret.resolve(Resolver, "name", nil, [], spec)
    assert :ignore = OAuthSecret.resolve(Resolver, "name", "api-key", [], spec)
  end

  test "project keys use trimmed tokens and preserve provider-specific errors" do
    assert {:ok, encoded} = OAuthSecret.project_key(%{"access_token" => " token "}, "project", :bad)
    assert Jason.decode!(encoded) == %{"token" => "token", "projectId" => "project"}
    assert {:error, :bad} = OAuthSecret.project_key(%{}, "project", :bad)
    assert {:error, :bad} = OAuthSecret.project_key(%{"access_token" => "token"}, nil, :bad)
  end

  test "legacy token parsing preserves error details and stored expiry skew" do
    data = %{"access_token" => " token ", "expires_in" => "3600"}
    before = System.system_time(:millisecond)
    assert {:ok, token} = OAuthSecret.parse_token_response(Jason.encode!(data), 300_000, true)
    after_parse = System.system_time(:millisecond)
    assert token.access_token == "token"
    assert token.refresh_token == nil
    assert token.expires_at_ms >= before + 3_300_000
    assert token.expires_at_ms <= after_parse + 3_300_000

    assert {:error, :invalid_token_response} = OAuthSecret.parse_token_response(%{})
    assert {:error, {:invalid_token_response, %{}}} =
             OAuthSecret.parse_token_response(%{}, 300_000, true)

    invalid_expiry = %{"access_token" => "token", "expires_in" => 0}
    assert {:error, {:invalid_expiry, ^invalid_expiry}} =
             OAuthSecret.parse_token_response(invalid_expiry, 300_000, true)
  end

  test "project enrichment without refresh persists against the reloaded revision" do
    secret = secret("token", 3_600_000)
    test_pid = self()

    opts = [
      reload_secret: fn "project-login" -> {:ok, OAuthSecret.encode(secret), :revision} end,
      persist_secret: fn "project-login", encoded, :revision ->
        send(test_pid, {:persisted, Jason.decode!(encoded)})
        :ok
      end
    ]

    spec = %{
      refresh: fn _ -> flunk("must not refresh a fresh token") end,
      skew_ms: 300_000,
      always_reload: true,
      usable: &OAuthSecret.usable/1,
      prepare: fn latest -> {:ok, Map.put(latest, "project_id", "project"), true} end,
      resolve: &OAuthSecret.project_key(&1, &1["project_id"], :missing_project)
    }

    assert {:ok, encoded} =
             OAuthSecret.resolve(Resolver, "project-login", OAuthSecret.encode(secret), opts, spec)

    assert Jason.decode!(encoded) == %{"token" => "token", "projectId" => "project"}
    assert_received {:persisted, %{"project_id" => "project"}}
  end

  test "a transient fallback reloads the owning login without enrichment or persistence" do
    stale = secret("stale", 60_000)
    latest = secret("replacement", 3_600_000)
    Process.put(:reload_count, 0)

    opts = [
      reload_secret: fn _ ->
        count = Process.get(:reload_count)
        Process.put(:reload_count, count + 1)
        {:ok, OAuthSecret.encode(if(count == 0, do: stale, else: latest)), count}
      end,
      persist_secret: fn _, _, _ -> flunk("must not persist a fallback") end
    ]

    spec = %{
      refresh: fn _ -> {:error, :transient} end,
      skew_ms: 300_000,
      always_reload: true,
      usable: &OAuthSecret.usable/1,
      prepare: fn _ -> flunk("must not enrich a fallback") end
    }

    assert {:ok, "replacement"} =
             OAuthSecret.resolve(Resolver, "fallback-login", OAuthSecret.encode(stale), opts, spec)

    assert Process.get(:reload_count) == 2
  end

  test "a replacement token retains each provider's refresh policy" do
    stale = secret("rejected", 60_000)
    latest = secret("replacement", 60_000)
    test_pid = self()
    opts = [force_refresh: true, reload_secret: fn _ -> {:ok, OAuthSecret.encode(latest)} end]

    spec = %{
      refresh: fn secret ->
        send(test_pid, {:refreshed, secret["access_token"]})
        {:ok, Map.put(secret, "access_token", "refreshed")}
      end,
      skew_ms: 300_000
    }

    assert {:ok, "replacement"} =
             OAuthSecret.resolve(Resolver, "replacement-login", OAuthSecret.encode(stale), opts, spec)

    refute_received {:refreshed, _}

    assert {:ok, "refreshed"} =
             OAuthSecret.resolve(
               Resolver,
               "replacement-login",
               OAuthSecret.encode(stale),
               opts,
               Map.put(spec, :refresh_replaced, true)
             )

    assert_received {:refreshed, "replacement"}
  end

  defp secret(token, lifetime_ms) do
    %{
      "type" => "test_oauth",
      "access_token" => token,
      "refresh_token" => "refresh",
      "expires_at_ms" => System.system_time(:millisecond) + lifetime_ms
    }
  end
end
