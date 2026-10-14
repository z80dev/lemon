defmodule LemonAi.Auth.OAuthForceRefreshTest do
  # Swaps Req's global default plug and OAuth client env vars.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{
    AnthropicOAuth,
    GitHubCopilotOAuth,
    GoogleAntigravityOAuth,
    GoogleGeminiCliOAuth,
    KimiCodeOAuth,
    OpenAICodexOAuth,
    XAIOAuth
  }

  @env ~w(GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET)

  @modules [
    {AnthropicOAuth, "anthropic_oauth", "fresh-token"},
    {GitHubCopilotOAuth, "github_copilot_oauth", "fresh-copilot-token"},
    {GoogleAntigravityOAuth, "google_antigravity_oauth", "fresh-token"},
    {GoogleGeminiCliOAuth, "google_gemini_cli_oauth", "fresh-token"},
    {KimiCodeOAuth, "kimi_code_oauth", "fresh-token"},
    {OpenAICodexOAuth, "openai_codex_oauth", "fresh-token"},
    {XAIOAuth, "xai_oauth", "fresh-token"}
  ]

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID", "test-client-id")
    System.put_env("GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET", "test-client-secret")

    test_pid = self()

    # One body every provider's refresh endpoint accepts.
    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :token_request)

      Req.Test.json(conn, %{
        "access_token" => "fresh-token",
        "refresh_token" => "fresh-refresh-token",
        "expires_in" => 3600,
        "token" => "fresh-copilot-token",
        "expires_at" => div(System.system_time(:millisecond), 1000) + 3600
      })
    end)

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  for {module, type, fresh} <- @modules do
    describe "#{inspect(module)} force_refresh" do
      test "refreshes and persists an unexpired token the provider rejected" do
        secret = unexpired_secret(unquote(type))
        test_pid = self()
        revision = make_ref()

        assert {:ok, _current} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret, [])

        refute_received :token_request

        assert {:ok, api_key} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                   force_refresh: true,
                   reload_secret: fn _ -> {:ok, secret, revision} end,
                   persist_secret: fn name, value, expected ->
                     assert expected == revision
                     send(test_pid, {:persisted, name, value})
                     :ok
                   end
                 )

        assert_received :token_request
        assert api_key =~ unquote(fresh)
        assert_received {:persisted, "llm_secret", stored}
        assert Jason.decode!(stored)["access_token"] == unquote(fresh)
      end

      test "fails instead of returning the rejected token when refresh fails" do
        Req.Test.stub(__MODULE__, fn conn ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "invalid_grant"})
        end)

        secret = unexpired_secret(unquote(type))

        assert {:error, _reason} =
                 unquote(module).resolve_api_key_from_secret(
                   "llm_secret",
                   secret,
                   force_refresh: true,
                   reload_secret: fn _ -> {:ok, secret, :test_revision} end,
                   persist_secret: fn _name, _value, _revision -> :ok end
                 )
      end

      test "reports a payload without a refresh token as not refreshable" do
        secret =
          unquote(type)
          |> unexpired_secret()
          |> Jason.decode!()
          |> Map.delete("refresh_token")
          |> Jason.encode!()

        assert {:error, :not_refreshable} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", secret,
                   force_refresh: true
                 )

        refute_received :token_request
      end
    end
  end

  for {module, type, _fresh} <- @modules,
      mutation <- [:replacement, :deletion, :delete_recreate],
      refresh_mode <- [:forced, :near_expiry] do
    test "#{inspect(module)} rejects a paused #{refresh_mode} refresh after #{mutation}" do
      stale =
        unexpired_secret(unquote(type))
        |> Jason.decode!()
        |> Map.put("expires_at_ms", System.system_time(:millisecond) + 60_000)
        |> Jason.encode!()

      initial_revision = make_ref()
      storage = start_supervised!({Agent, fn -> %{secret: stale, revision: initial_revision} end})
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:refresh_paused, self()})
        await_refresh_release()

        Req.Test.json(conn, %{
          "access_token" => "late-refresh-token",
          "refresh_token" => "late-refresh-grant",
          "expires_in" => 3600,
          "token" => "late-refresh-token",
          "expires_at" => div(System.system_time(:millisecond), 1000) + 3600
        })
      end)

      opts = [
        force_refresh: unquote(refresh_mode) == :forced,
        reload_secret: fn "selected_login" -> reload_storage(storage) end,
        persist_secret: fn "selected_login", encoded, expected ->
          send(test_pid, {:cas_attempt, expected})

          Agent.get_and_update(storage, fn state ->
            if state.revision == expected,
              do: {:ok, %{secret: encoded, revision: make_ref()}},
              else: {{:error, :stale_revision}, state}
          end)
        end
      ]

      task =
        Task.async(fn ->
          unquote(module).resolve_api_key_from_secret("selected_login", stale, opts)
        end)

      assert_receive {:refresh_paused, refresher}, 5_000

      replacement =
        stale
        |> Jason.decode!()
        |> Map.put("access_token", "replacement-token")
        |> Jason.encode!()

      changed =
        case unquote(mutation) do
          :replacement ->
            %{secret: replacement, revision: make_ref()}

          :deletion ->
            %{secret: nil, revision: make_ref()}

          :delete_recreate ->
            Agent.get_and_update(storage, fn _ ->
              {:ok, %{secret: nil, revision: make_ref()}}
            end)

            %{secret: stale, revision: make_ref()}
        end

      Agent.get_and_update(storage, fn _ -> {:ok, changed} end)
      send(refresher, :continue_refresh)

      assert {:error, :oauth_secret_changed} = Task.await(task, 5_000)
      assert_received {:cas_attempt, ^initial_revision}
      assert Agent.get(storage, & &1) == changed
      refute_received {:cas_attempt, _}
      refute_received {:refresh_paused, _}
    end
  end

  for {module, type, _fresh} <- @modules,
      mutation <- [:replacement, :deletion, :expired_replacement] do
    test "#{inspect(module)} reloads fallback after a paused transient failure and #{mutation}" do
      stale =
        unexpired_secret(unquote(type))
        |> Jason.decode!()
        |> Map.put("expires_at_ms", System.system_time(:millisecond) + 60_000)
        |> Jason.encode!()

      storage = start_supervised!({Agent, fn -> %{secret: stale, revision: make_ref()} end})
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:refresh_paused, self()})
        await_refresh_release()
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
      end)

      task =
        Task.async(fn ->
          unquote(module).resolve_api_key_from_secret("selected_login", stale,
            reload_secret: fn "selected_login" -> reload_storage(storage) end,
            persist_secret: fn _, _, _ -> flunk("failed refresh must not persist") end
          )
        end)

      assert_receive {:refresh_paused, refresher}, 5_000

      replacement =
        unexpired_secret(unquote(type))
        |> Jason.decode!()
        |> Map.put("access_token", "replacement-token")

      {encoded, expected} =
        case unquote(mutation) do
          :replacement ->
            {Jason.encode!(replacement), :usable}

          :deletion ->
            {nil, :oauth_secret_missing}

          :expired_replacement ->
            expired = Map.put(replacement, "expires_at_ms", System.system_time(:millisecond) - 1)
            {Jason.encode!(expired), :expired_access_token}
        end

      changed = %{secret: encoded, revision: make_ref()}
      Agent.get_and_update(storage, fn _ -> {:ok, changed} end)
      send(refresher, :continue_refresh)

      case expected do
        :usable ->
          assert {:ok, key} = Task.await(task, 5_000)
          assert key =~ "replacement-token"

        reason ->
          assert {:error, ^reason} = Task.await(task, 5_000)
      end

      assert Agent.get(storage, & &1) == changed
      refute_received {:refresh_paused, _}
    end
  end

  test "Gemini transient fallback does not enrich or persist a replacement login" do
    stale =
      unexpired_secret("google_gemini_cli_oauth")
      |> Jason.decode!()
      |> Map.put("expires_at_ms", System.system_time(:millisecond) + 60_000)
      |> Jason.encode!()

    storage = start_supervised!({Agent, fn -> %{secret: stale, revision: make_ref()} end})
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:refresh_paused, self()})
      await_refresh_release()
      conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
    end)

    task =
      Task.async(fn ->
        GoogleGeminiCliOAuth.resolve_api_key_from_secret("selected_login", stale,
          reload_secret: fn "selected_login" -> reload_storage(storage) end,
          persist_secret: fn _, _, _ -> flunk("fallback must not persist") end
        )
      end)

    assert_receive {:refresh_paused, refresher}, 5_000

    replacement =
      unexpired_secret("google_gemini_cli_oauth")
      |> Jason.decode!()
      |> Map.put("access_token", "replacement-token")
      |> Map.drop(["project_id", "projectId", "managed_project_id"])
      |> Jason.encode!()

    changed = %{secret: replacement, revision: make_ref()}
    Agent.get_and_update(storage, fn _ -> {:ok, changed} end)
    Req.Test.stub(__MODULE__, fn _ -> flunk("fallback must not enrich project context") end)
    send(refresher, :continue_refresh)

    assert {:error, :missing_gemini_project} = Task.await(task, 5_000)
    assert Agent.get(storage, & &1) == changed
  end

  test "a forced Codex refresh uses a token another caller already rotated" do
    stale = unexpired_secret("openai_codex_oauth")

    rotated =
      stale
      |> Jason.decode!()
      |> Map.put("access_token", "rotated-token")
      |> Jason.encode!()

    assert {:ok, "rotated-token"} =
             OpenAICodexOAuth.resolve_api_key_from_secret("llm_secret", stale,
               force_refresh: true,
               reload_secret: fn "llm_secret" -> {:ok, rotated, :test_revision} end,
               persist_secret: fn _name, _value, _revision -> flunk("must not persist") end
             )

    refute_received :token_request
  end

  for {module, type} <- [
        {GitHubCopilotOAuth, "github_copilot_oauth"},
        {GoogleAntigravityOAuth, "google_antigravity_oauth"},
        {GoogleGeminiCliOAuth, "google_gemini_cli_oauth"}
      ] do
    test "#{inspect(module)} never reuses an expired token after a refresh failure" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "unavailable", "private" => "provider-private-body"})
      end)

      now = System.system_time(:millisecond)
      secret = unexpired_secret(unquote(type)) |> Jason.decode!()
      expired = Map.put(secret, "expires_at_ms", now - 1_000)

      for payload <- [expired, Map.delete(expired, "refresh_token")] do
        assert {:error, _} =
                 unquote(module).resolve_api_key_from_secret("llm_secret", Jason.encode!(payload))
      end

      # Near expiry but still valid: transient refresh failures may reuse it.
      near_expiry = Map.put(secret, "expires_at_ms", now + 60_000)

      assert {:ok, key} =
               unquote(module).resolve_api_key_from_secret(
                 "llm_secret",
                 Jason.encode!(near_expiry)
               )

      assert key =~ "rejected-token"
    end

    test "#{inspect(module)} reloads the owning login before refreshing and fails closed on removal" do
      stale = unexpired_secret(unquote(type))

      rotated =
        Jason.decode!(stale)
        |> Map.put("access_token", "another-session-token")
        |> Jason.encode!()

      assert {:ok, key} =
               unquote(module).resolve_api_key_from_secret("selected_login", stale,
                 force_refresh: true,
                 reload_secret: fn "selected_login" -> {:ok, rotated, :test_revision} end,
                 persist_secret: fn _, _, _ ->
                   flunk("a rotated login must not be refreshed again")
                 end
               )

      assert key =~ "another-session-token"

      for reload_result <- [:error, {:ok, "replacement-api-key"}] do
        assert {:error, _} =
                 unquote(module).resolve_api_key_from_secret("selected_login", stale,
                   force_refresh: true,
                   reload_secret: fn "selected_login" -> reload_result end
                 )
      end

      refute_received :token_request
    end

    test "#{inspect(module)} serializes refreshes for two stale readers of the same login" do
      stale = unexpired_secret(unquote(type))
      storage = start_supervised!({Agent, fn -> %{secret: stale, revision: 0, requests: 0} end})
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        count =
          Agent.get_and_update(storage, fn state ->
            {state.requests, %{state | requests: state.requests + 1}}
          end)

        send(test_pid, {:refresh_request, self()})

        if count == 0 do
          receive do
            :continue_refresh -> :ok
          after
            5_000 -> flunk("refresh barrier timed out")
          end
        end

        Req.Test.json(conn, %{
          "access_token" => "serialized-token",
          "refresh_token" => "rotated-refresh-token",
          "expires_in" => 3600,
          "token" => "serialized-token",
          "expires_at" => div(System.system_time(:millisecond), 1000) + 3600
        })
      end)

      opts = [
        force_refresh: true,
        reload_secret: fn "selected_login" ->
          Agent.get(storage, &{:ok, &1.secret, &1.revision})
        end,
        persist_secret: fn "selected_login", encoded, expected ->
          Agent.get_and_update(storage, fn state ->
            if state.revision == expected,
              do: {:ok, %{state | secret: encoded, revision: state.revision + 1}},
              else: {{:error, :stale_revision}, state}
          end)
        end
      ]

      resolve = fn ->
        unquote(module).resolve_api_key_from_secret("selected_login", stale, opts)
      end

      first = Task.async(resolve)
      assert_receive {:refresh_request, refresher}, 5_000
      second = Task.async(resolve)
      send(refresher, :continue_refresh)

      for task <- [first, second] do
        assert {:ok, key} = Task.await(task)
        assert key =~ "serialized-token"
      end

      assert Agent.get(storage, & &1.requests) == 1
      refute_received {:refresh_request, _}
    end
  end

  for {module, type} <- [
        {GoogleAntigravityOAuth, "google_antigravity_oauth"},
        {GoogleGeminiCliOAuth, "google_gemini_cli_oauth"}
      ] do
    test "#{inspect(module)} does not fall back after the refresh grant is revoked" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      secret =
        unexpired_secret(unquote(type))
        |> Jason.decode!()
        |> Map.put("expires_at_ms", System.system_time(:millisecond) + 60_000)
        |> Jason.encode!()

      assert {:error, :reauth_required} =
               unquote(module).resolve_api_key_from_secret("selected_login", secret)
    end
  end

  for status <- [401, 403], lifetime <- [:near_expiry, :expired] do
    test "Copilot #{status} rejection requires sign-in for a #{lifetime} token" do
      expires_in_ms = if unquote(lifetime) == :near_expiry, do: 60_000, else: -1_000

      secret =
        unexpired_secret("github_copilot_oauth")
        |> Jason.decode!()
        |> Map.put("expires_at_ms", System.system_time(:millisecond) + expires_in_ms)
        |> Jason.encode!()

      revision = make_ref()

      storage =
        start_supervised!({Agent, fn -> %{secret: secret, revision: revision, reads: 0} end})

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        send(test_pid, :copilot_token_request)
        conn |> Plug.Conn.put_status(unquote(status)) |> Req.Test.json(%{})
      end)

      assert {:error, :reauth_required} =
               GitHubCopilotOAuth.resolve_api_key_from_secret("selected_login", secret,
                 reload_secret: fn "selected_login" ->
                   Agent.get_and_update(storage, fn state ->
                     {{:ok, state.secret, state.revision}, %{state | reads: state.reads + 1}}
                   end)
                 end,
                 persist_secret: fn _, _, _ ->
                   send(test_pid, :unexpected_persist)
                   :ok
                 end
               )

      assert_received :copilot_token_request
      refute_received :copilot_token_request
      refute_received :unexpected_persist
      assert Agent.get(storage, & &1) == %{secret: secret, revision: revision, reads: 1}
    end
  end

  defp reload_storage(storage) do
    Agent.get(storage, fn
      %{secret: nil} -> {:error, :not_found}
      %{secret: encoded, revision: revision} -> {:ok, encoded, revision}
    end)
  end

  defp await_refresh_release do
    receive do
      :continue_refresh -> :ok
    after
      5_000 -> flunk("refresh barrier timed out")
    end
  end

  defp unexpired_secret(type) do
    now = System.system_time(:millisecond)

    Jason.encode!(%{
      "type" => type,
      "refresh_token" => "refresh-token",
      "access_token" => "rejected-token",
      "expires_at_ms" => now + 60 * 60 * 1000,
      "project_id" => "proj-123",
      "managed_project_id" => "proj-123",
      "projectId" => "proj-123",
      "token_endpoint" => "https://auth.x.ai/oauth2/token",
      "created_at_ms" => now,
      "updated_at_ms" => now
    })
  end
end
