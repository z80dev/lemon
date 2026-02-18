defmodule CodingAgent.SessionApiKeyResolutionTest do
  use ExUnit.Case, async: false

  alias Ai.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}
  alias CodingAgent.{Session, SettingsManager}
  alias LemonCore.{Secrets, Store}

  setup do
    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      System.delete_env("OPENAI_API_KEY")
    end)

    :ok
  end

  test "env key overrides plain and secret-backed provider keys" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")
    System.put_env("OPENAI_API_KEY", "from-env")

    settings =
      settings(%{
        "openai" => %{api_key: "from-plain", api_key_secret: "llm_openai_api_key"}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-env"}, 1_000
    GenServer.stop(session)
  end

  test "plain provider api_key overrides api_key_secret" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")

    settings =
      settings(%{
        "openai" => %{api_key: "from-plain", api_key_secret: "llm_openai_api_key"}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-plain"}, 1_000
    GenServer.stop(session)
  end

  test "api_key_secret is used when env and plain key are missing" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-secret")

    settings =
      settings(%{
        "openai" => %{api_key_secret: "llm_openai_api_key"}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-secret"}, 1_000
    GenServer.stop(session)
  end

  test "default provider secret mapping is used when api_key_secret is absent" do
    assert {:ok, _} = Secrets.set("llm_openai_api_key", "from-default-secret")

    settings =
      settings(%{
        "openai" => %{}
      })

    session = start_session(self(), settings)
    assert :ok = Session.prompt(session, "hello")

    assert_receive {:stream_api_key, "from-default-secret"}, 1_000
    GenServer.stop(session)
  end

  defp settings(providers) do
    %SettingsManager{
      default_thinking_level: :medium,
      providers: providers,
      tools: %{wasm: %{enabled: false}}
    }
  end

  defp start_session(test_pid, settings_manager) do
    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: mock_model(),
        settings_manager: settings_manager,
        stream_fn: stream_fn(test_pid)
      )

    session
  end

  defp stream_fn(test_pid) do
    fn _model, _context, options ->
      send(test_pid, {:stream_api_key, options.api_key})
      {:ok, response_stream()}
    end
  end

  defp response_stream do
    response = assistant_message("ok")
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})
      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end

  defp mock_model do
    %Model{
      id: "mock-openai-model",
      name: "Mock OpenAI",
      api: :mock,
      provider: :openai,
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
      provider: :openai,
      model: "mock-openai-model",
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

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end
