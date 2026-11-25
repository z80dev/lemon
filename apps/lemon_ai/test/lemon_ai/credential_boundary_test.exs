defmodule LemonAi.CredentialBoundaryTest do
  @moduledoc """
  `lemon_ai` ships no Lemon deployment credential discovery: no omp broker or
  token bridge, no other tools' credential files, no provider-local environment
  tables or external processes. OAuth helpers stay pure, with persistence
  injected by the caller.
  """
  # Swaps Req's global default plug.
  use ExUnit.Case, async: false

  alias LemonAi.Auth.{AnthropicOAuth, OAuthSecretResolver}

  @app_root Path.expand("../..", __DIR__)

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "the application ships and supervises no omp module or broker" do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    refute :lemon_agent in Application.spec(:lemon_ai, :applications)

    modules = :lemon_ai |> Application.spec(:modules) |> Enum.map(&inspect/1)

    assert "LemonAi.Auth.AnthropicOAuth" in modules
    refute Enum.any?(modules, &String.starts_with?(&1, "LemonAi.Auth.Omp"))

    children = LemonAi.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    refute Enum.any?(children, &(inspect(&1) =~ "Omp"))
  end

  test "providers neither spawn processes nor read ambient credentials" do
    sources = Path.wildcard(Path.join(@app_root, "lib/lemon_ai/providers/**/*.ex"))
    assert sources != []

    for path <- sources, source = File.read!(path), pattern <- ["System.cmd", "Port.open"] do
      refute source =~ pattern, "#{Path.relative_to(path, @app_root)} uses #{pattern}"
    end

    for path <- sources, source = File.read!(path) do
      refute source =~ "System.get_env(\"GOOGLE_APPLICATION_CREDENTIALS",
             "#{Path.relative_to(path, @app_root)} reads ambient Google credentials"

      refute source =~ ~r/def get_env_api_key/,
             "#{Path.relative_to(path, @app_root)} keeps a provider env table"
    end
  end

  test "package sources name no other tool's credential file or the omp binary" do
    files =
      ["lib/**/*.ex", "priv/**/*", "README.md", "CHANGELOG.md", "mix.exs"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@app_root, &1)))
      |> Enum.filter(&File.regular?/1)

    for path <- files, source = File.read!(path), needle <- ~w(~/.claude ~/.codex .bun/bin/omp) do
      refute source =~ needle, "#{Path.relative_to(path, @app_root)} contains #{needle}"
    end

    for path <- files, String.ends_with?(path, ".ex"), source = File.read!(path) do
      refute source =~ ~s(".claude"), "#{Path.relative_to(path, @app_root)} builds a .claude path"
      refute source =~ ~s(".codex"), "#{Path.relative_to(path, @app_root)} builds a .codex path"
    end
  end

  test "authorize, exchange and refresh run with caller-injected persistence only" do
    {:ok, auth} = AnthropicOAuth.authorize_url(redirect_uri: "http://localhost:53692/callback")
    assert auth.authorize_url =~ "code_challenge_method=S256"

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:token_request, body["grant_type"]})
      Req.Test.json(conn, token_response(body["grant_type"]))
    end)

    assert {:ok, secret} =
             AnthropicOAuth.exchange_code_for_secret("the-code", auth.code_verifier,
               redirect_uri: auth.redirect_uri,
               state: auth.state
             )

    assert_received {:token_request, "authorization_code"}

    # The caller's store: an in-memory versioned cell, compared on write.
    {:ok, store} = Agent.start_link(fn -> {1, AnthropicOAuth.encode_secret(secret)} end)
    {_revision, stored} = Agent.get(store, & &1)

    assert {:ok, "sk-ant-oat01-second"} =
             OAuthSecretResolver.resolve_with(
               AnthropicOAuth,
               "login",
               stored,
               store_callbacks(store)
             )

    assert_received {:token_request, "refresh_token"}
    assert {2, persisted} = Agent.get(store, & &1)
    assert {:ok, %{"refresh_token" => "refresh-2"}} = AnthropicOAuth.decode_secret(persisted)
  end

  # The umbrella test VM runs every Lemon application, so the same flow also
  # runs in a fresh peer VM where only `:lemon_ai` (and its dependencies) start.
  @peer_flow ~S"""
  {:ok, _} = Application.ensure_all_started(:lemon_ai)
  started = Enum.map(Application.started_applications(), &elem(&1, 0))
  children = LemonAi.Supervisor |> Supervisor.which_children() |> Enum.map(&inspect(elem(&1, 0)))
  {:ok, requests} = Agent.start_link(fn -> [] end)

  Req.default_options(
    plug: fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      grant = Jason.decode!(raw)["grant_type"]
      Agent.update(requests, &[grant | &1])

      Req.Test.json(
        conn,
        case grant do
          "authorization_code" ->
            %{"access_token" => "sk-ant-oat01-first", "refresh_token" => "refresh-1", "expires_in" => 1}

          "refresh_token" ->
            %{"access_token" => "sk-ant-oat01-second", "refresh_token" => "refresh-2", "expires_in" => 3600}
        end
      )
    end
  )

  alias LemonAi.Auth.{AnthropicOAuth, OAuthSecretResolver}
  {:ok, auth} = AnthropicOAuth.authorize_url(redirect_uri: "http://localhost:53692/callback")

  {:ok, secret} =
    AnthropicOAuth.exchange_code_for_secret("the-code", auth.code_verifier,
      redirect_uri: auth.redirect_uri,
      state: auth.state
    )

  {:ok, store} = Agent.start_link(fn -> {1, AnthropicOAuth.encode_secret(secret)} end)

  callbacks = [
    reload_secret: fn "login" ->
      {revision, encoded} = Agent.get(store, & &1)
      {:ok, encoded, revision}
    end,
    persist_secret: fn "login", encoded, revision ->
      Agent.get_and_update(store, fn
        {^revision, _old} -> {:ok, {revision + 1, encoded}}
        current -> {{:error, :stale_revision}, current}
      end)
    end
  ]

  {_revision, stored} = Agent.get(store, & &1)
  resolved = OAuthSecretResolver.resolve_with(AnthropicOAuth, "login", stored, callbacks)
  {revision, persisted} = Agent.get(store, & &1)

  %{
    started: started,
    children: children,
    resolved: resolved,
    revision: revision,
    persisted: AnthropicOAuth.decode_secret(persisted),
    requests: Enum.reverse(Agent.get(requests, & &1))
  }
  """

  test "a VM running only lemon_ai authorizes, exchanges and refreshes with injected persistence" do
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: args, wait_boot: 30_000})

    try do
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir], 30_000)
      {result, _binding} = :peer.call(peer, Code, :eval_string, [@peer_flow], 60_000)

      refute :lemon_agent in result.started
      refute :lemon_core in result.started
      assert :lemon_ai in result.started
      refute Enum.any?(result.children, &(&1 =~ "Omp"))
      assert result.requests == ["authorization_code", "refresh_token"]
      assert result.resolved == {:ok, "sk-ant-oat01-second"}
      assert result.revision == 2
      assert {:ok, %{"refresh_token" => "refresh-2"}} = result.persisted
    after
      :peer.stop(peer)
    end
  end

  defp token_response("authorization_code"),
    do: %{
      "access_token" => "sk-ant-oat01-first",
      "refresh_token" => "refresh-1",
      "expires_in" => 1
    }

  defp token_response("refresh_token"),
    do: %{
      "access_token" => "sk-ant-oat01-second",
      "refresh_token" => "refresh-2",
      "expires_in" => 3600
    }

  defp store_callbacks(store) do
    [
      reload_secret: fn "login" ->
        {revision, encoded} = Agent.get(store, & &1)
        {:ok, encoded, revision}
      end,
      persist_secret: fn "login", encoded, revision ->
        Agent.get_and_update(store, fn
          {^revision, _old} -> {:ok, {revision + 1, encoded}}
          current -> {{:error, :stale_revision}, current}
        end)
      end
    ]
  end
end
