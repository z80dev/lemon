defmodule LemonControlPlane.Methods.NativeFollowupAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize

  alias LemonControlPlane.Methods.{
    ProfileFollowupAdmissionSet,
    ProfilesGet,
    ProfilesList,
    ProfilesRoster,
    Registry,
    RunsFollowupLineageGet
  }

  alias LemonCore.{ProfileStore, Secrets, Store}
  alias LemonRouter.NativeFollowupAdmission

  @origin "https://native-issuer.example.test"
  @token "private-native-cp-issuer-token"

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    root = Path.join(System.tmp_dir!(), "native-cp-issuer-" <> suffix)
    state = Path.join(root, "state")
    File.mkdir_p!(state)
    previous_paths = Application.fetch_env(:lemon_core, :paths)
    previous_secrets = Application.fetch_env(:lemon_core, Secrets)
    previous_origins = Application.fetch_env(:lemon_router, :native_followup_allowed_origins)
    previous_origin_env = System.get_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
    key_env = "NATIVE_CP_ISSUER_KEY_" <> suffix
    id = "native-cp-" <> suffix

    System.put_env(key_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")

    Application.put_env(:lemon_core, :paths,
      home_state_dir: state,
      global_config: Path.join(state, "config.toml")
    )

    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: key_env)
    Application.put_env(:lemon_router, :native_followup_allowed_origins, [@origin])

    assert {:ok, _} =
             ProfileStore.create(%{
               "id" => id,
               "name" => "Native admission CP",
               "description" => "Untouched"
             })

    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    on_exit(fn ->
      {:ok, secrets} = Secrets.list()

      for secret <- secrets,
          String.starts_with?(secret.name, "native_followup/" <> id <> "/"),
          do: Secrets.delete(secret.name)

      Store.delete(:native_followup_admission_configs, id)
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, Secrets, previous_secrets)
      restore_env(:lemon_router, :native_followup_allowed_origins, previous_origins)

      if is_nil(previous_origin_env),
        do: System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS"),
        else: System.put_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", previous_origin_env)

      System.delete_env(key_env)
      File.rm_rf!(root)
    end)

    %{
      id: id,
      params: %{
        "profileId" => id,
        "url" => @origin <> "/internal/runtime/followup/admission",
        "token" => @token
      }
    }
  end

  test "real registered admin setter writes encrypted credential and returns no private data",
       ctx do
    assert {:ok, ProfileFollowupAdmissionSet} = Registry.lookup("profile.followup.admission.set")
    assert {:ok, RunsFollowupLineageGet} = Registry.lookup("runs.followup.lineage.get")
    assert ProfileFollowupAdmissionSet.scopes() == [:admin]
    assert RunsFollowupLineageGet.scopes() == [:admin]

    assert {:ok, %{"profileId" => id, "configured" => true} = response} =
             Registry.dispatch(
               "profile.followup.admission.set",
               ctx.params,
               auth_context([:admin])
             )

    assert id == ctx.id
    assert map_size(response) == 2
    assert {:ok, config} = NativeFollowupAdmission.fetch_config(ctx.id)
    assert {:ok, @token} = Secrets.get(config.token_secret)
    assert Enum.sort(Map.keys(config)) == Enum.sort([:profile_id, :url, :token_secret])

    assert {:ok, stored} =
             Store.fetch(Secrets.table(), {Secrets.default_owner(), config.token_secret})

    refute inspect(stored) =~ @token

    assert {:ok, get} = ProfilesGet.handle(%{"id" => ctx.id}, %{})
    assert {:ok, list} = ProfilesList.handle(%{}, %{})
    assert {:ok, roster} = ProfilesRoster.handle(%{}, %{})
    assert {:ok, profile} = ProfileStore.get(ctx.id)
    assert profile["description"] == "Untouched"

    for projection <- [response, get, list, roster, profile] do
      refute inspect(projection) =~ @token
      refute inspect(projection) =~ @origin
      refute inspect(projection) =~ config.token_secret
    end

    assert {:error, {:method_not_found, _}} =
             Registry.dispatch(
               "profile.followup.admission.get",
               %{"profileId" => ctx.id},
               auth_context([:admin])
             )
  end

  test "nonadmin and paired-node auth cannot configure or read sealed followup lineage", ctx do
    for scopes <- [[], [:read], [:write], [:invoke, :event]] do
      assert {:error, _} =
               Registry.dispatch(
                 "profile.followup.admission.set",
                 ctx.params,
                 auth_context(scopes)
               )

      assert {:error, _} =
               Registry.dispatch(
                 "runs.followup.lineage.get",
                 %{"runId" => "reserved-native-F"},
                 auth_context(scopes)
               )
    end

    node = %{
      role: :node,
      scopes: [:invoke, :event],
      token: nil,
      client_id: "worker",
      identity: %{"type" => "node", "nodeId" => "worker"}
    }

    assert {:error, _} =
             Authorize.authorize(
               node,
               ProfileFollowupAdmissionSet.name(),
               ProfileFollowupAdmissionSet.scopes()
             )

    assert {:error, _} =
             Authorize.authorize(
               node,
               RunsFollowupLineageGet.name(),
               RunsFollowupLineageGet.scopes()
             )

    assert {:error, :admission_unavailable} = NativeFollowupAdmission.fetch_config(ctx.id)
  end

  test "setter rejects extra caller authority, duplicate aliases and bad shapes", ctx do
    for params <- [
          nil,
          [],
          Map.delete(ctx.params, "token"),
          Map.put(ctx.params, "actor", "forged"),
          Map.put(ctx.params, "parentRunId", "model-selected-parent"),
          Map.put(ctx.params, :profileId, ctx.id),
          Map.put(ctx.params, "mcpServers", []),
          Map.put(ctx.params, "token", "secret\r\nheader"),
          Map.put(ctx.params, "url", "https://unlisted.example.test/check")
        ] do
      assert {:error, _} = ProfileFollowupAdmissionSet.handle(params, %{})
    end

    assert {:error, {:not_found, _}} =
             ProfileFollowupAdmissionSet.handle(
               %{ctx.params | "profileId" => "missing-profile"},
               %{}
             )
  end

  test "readonly lineage getter accepts only actual reserved F, never parent or principal claims" do
    for params <- [
          nil,
          [],
          %{},
          %{"runId" => "../escape"},
          %{"runId" => "F", "parentRunId" => "parent"},
          %{"runId" => "F", "profileId" => "source"},
          %{"runId" => "F", "actor" => "forged"},
          %{"runId" => "F", :runId => "ambiguous"}
        ] do
      assert {:error, {:invalid_request, _}} = RunsFollowupLineageGet.handle(params, %{})
    end

    absent = "native-cp-absent-#{System.unique_integer([:positive])}"
    assert {:error, {:not_found, _}} = RunsFollowupLineageGet.handle(%{"runId" => absent}, %{})
  end

  test "registered three-field setter consumes the actual current target transport, never response authority",
       ctx do
    assert {:ok, _} =
             Registry.dispatch(
               "profile.followup.admission.set",
               ctx.params,
               auth_context([:admin])
             )

    assert {:ok, config} = NativeFollowupAdmission.fetch_config(ctx.id)
    run_id = "native-cp-fixed-F"
    invocation = invocation(run_id)
    lineage = %{run_id: run_id, source_profile_id: ctx.id, target_profile_id: ctx.id}
    opts = [plug: {Req.Test, __MODULE__}]
    Req.Test.stub(__MODULE__, fn _ -> flunk("empty current target templates called issuer") end)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(config, lineage, opts)
    core = hd(invocation["invocationMcpServers"])
    template = Map.put(core, "headers", %{})
    assert {:ok, _} = ProfileStore.update(ctx.id, %{"mcpServers" => [template]})

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"runId" => run_id}
      Req.Test.json(conn, %{"allow" => true, "invocation" => invocation})
    end)

    assert {:ok, actual} = NativeFollowupAdmission.check(config, lineage, opts)
    assert actual == invocation

    forged =
      core
      |> Map.put("url", "https://response-self-authorized.example.test/mcp")
      |> Map.put("allowedOrigins", ["https://response-self-authorized.example.test"])

    candidate =
      invocation
      |> Map.put("invocationMcpServers", [forged])
      |> Map.update!("invocationProof", &Map.put(&1, "serverUrl", forged["url"]))

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"allow" => true, "invocation" => candidate}))
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(config, lineage, opts)

    assert {:ok, _} =
             ProfileStore.update(ctx.id, %{"mcpServers" => [Map.put(forged, "headers", %{})]})

    assert {:ok, ^candidate} = NativeFollowupAdmission.check(config, lineage, opts)
    assert {:ok, _} = ProfileStore.update(ctx.id, %{"mcpServers" => []})
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(config, lineage, opts)
  end

  defp invocation(run_id) do
    %{
      "invocationContextKey" => "current-target-context",
      "memoryContextKey" => "current-target-memory",
      "invocationToolPolicy" => %{"allow" => ["read"], "deny" => []},
      "invocationMcpServers" => [
        %{
          "name" => "lemon-bot",
          "url" => "https://core.example.test/mcp",
          "allowedOrigins" => ["https://core.example.test"],
          "approvedPrivateOrigins" => [],
          "headers" => %{
            "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{run_id}}"
          }
        }
      ],
      "invocationProof" => %{
        "runId" => run_id,
        "serverName" => "lemon-bot",
        "serverUrl" => "https://core.example.test/mcp",
        "headerName" => "X-Lemon-Bot-Invocation",
        "secretName" => "lemon_bot/invocations/" <> run_id
      },
      "sharedMemoryGrant" => false
    }
  end

  defp auth_context(scopes),
    do: %{
      conn_id: "native-issuer-cp-test",
      conn_pid: self(),
      auth: %{role: :operator, scopes: scopes, token: nil, client_id: nil, identity: nil}
    }

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
