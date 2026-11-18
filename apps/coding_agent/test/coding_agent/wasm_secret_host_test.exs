defmodule CodingAgent.WasmSecretHostTest do
  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}
  alias CodingAgent.{Session, SettingsManager}
  alias LemonCore.{Secrets, Store}

  setup do
    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("ENV_ONLY_SECRET")
    end)

    :ok
  end

  test "reserved __lemon.secret.exists checks encrypted store on the internal channel" do
    assert {:ok, _} = Secrets.set("WASM_TEST_SECRET", "stored")

    session = start_session()

    assert {:ok, payload} =
             internal_call(session, "__lemon.secret.exists", "WASM_TEST_SECRET", ["WASM_TEST_*"])

    assert Jason.decode!(payload) == %{"exists" => true}
    GenServer.stop(session)
  end

  test "reserved __lemon.secret.resolve falls back to env when store secret is missing" do
    System.put_env("ENV_ONLY_SECRET", "env-value")

    session = start_session()

    assert {:ok, payload} =
             internal_call(session, "__lemon.secret.resolve", "ENV_ONLY_SECRET", [
               "ENV_ONLY_SECRET"
             ])

    assert Jason.decode!(payload) == %{"value" => "env-value", "source" => "env"}
    GenServer.stop(session)
  end

  test "reserved targets are refused on the tool channel" do
    assert {:ok, _} = Secrets.set("WASM_TEST_SECRET", "stored")
    session = start_session()
    params = Jason.encode!(%{"name" => "WASM_TEST_SECRET"})

    for target <- ["__lemon.secret.resolve", "__lemon.secret.exists", "__lemon.other"] do
      assert {:error, :reserved_target} =
               GenServer.call(session, {:wasm_host_tool_invoke, target, params})

      assert {:error, :reserved_target} =
               GenServer.call(
                 session,
                 {:wasm_host_tool_invoke, target, params, host_context(:tool)}
               )
    end

    GenServer.stop(session)
  end

  test "internal channel refuses secret names outside the caller allowlist" do
    assert {:ok, _} = Secrets.set("WASM_TEST_SECRET", "stored")
    System.put_env("ENV_ONLY_SECRET", "env-value")
    session = start_session()

    for target <- ["__lemon.secret.resolve", "__lemon.secret.exists"],
        name <- ["WASM_TEST_SECRET", "ENV_ONLY_SECRET"] do
      assert {:error, :secret_not_allowed} =
               internal_call(session, target, name, ["ALLOWED_*"])

      assert {:error, :secret_not_allowed} = internal_call(session, target, name, [])
    end

    GenServer.stop(session)
  end

  test "internal channel only serves reserved secret targets" do
    session = start_session()

    assert {:error, :invalid_internal_target} =
             internal_call(session, "read", "WASM_TEST_SECRET", ["*"])

    GenServer.stop(session)
  end

  test "padded names and whitespace-prefixed patterns are never trimmed into a match" do
    assert {:ok, _} = Secrets.set("WASM_TEST_SECRET", "stored")
    session = start_session()

    for target <- ["__lemon.secret.resolve", "__lemon.secret.exists"] do
      for name <- [" WASM_TEST_SECRET", "WASM_TEST_SECRET ", "\nWASM_TEST_SECRET", ""] do
        assert {:error, :invalid_secret_name} =
                 internal_call(session, target, name, ["WASM_*"])
      end

      for pattern <- [" WASM_*", "WASM_* ", " WASM_TEST_SECRET", "", " *"] do
        assert {:error, :secret_not_allowed} =
                 internal_call(session, target, "WASM_TEST_SECRET", [pattern])
      end
    end

    GenServer.stop(session)
  end

  defp internal_call(session, target, name, allowed) do
    GenServer.call(
      session,
      {:wasm_host_tool_invoke, target, Jason.encode!(%{"name" => name}),
       host_context({:internal, "caller_tool", allowed})}
    )
  end

  defp host_context(channel) do
    %{
      deadline: System.monotonic_time(:millisecond) + 10_000,
      owner: self(),
      signal: nil,
      host_channel: channel
    }
  end

  defp start_session do
    settings_manager = %SettingsManager{
      tools: %{wasm: %{enabled: false}},
      default_thinking_level: :medium
    }

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        settings_manager: settings_manager,
        stream_fn: mock_stream_fn_single(assistant_message("ok"))
      )

    session
  end

  defp mock_model do
    %Model{
      id: "mock-model",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model",
      usage: mock_usage(),
      stop_reason: :stop,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp mock_usage do
    %Usage{
      input: 10,
      output: 5,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 15,
      cost: %Cost{input: 0.0001, output: 0.0002, total: 0.0003}
    }
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(stream, {:start, response})
        LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
        LemonAi.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end
