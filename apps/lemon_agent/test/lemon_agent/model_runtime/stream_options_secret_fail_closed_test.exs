defmodule LemonAgent.ModelRuntime.StreamOptionsSecretFailClosedTest do
  @moduledoc """
  An unreadable configured secret is a refusal all the way to the provider:
  stream options never substitute an inline key, ambient AWS credentials, a
  GOOGLE_APPLICATION_CREDENTIALS file or `gcloud`.
  """
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.StreamOptions, as: Builder
  alias LemonAi.EventStream
  alias LemonAi.Providers.GoogleVertex
  alias LemonAi.Types.{AssistantMessage, Context, Model, ModelCost, UserMessage}
  alias LemonCore.{Secrets, Store}

  @tripwire "ambient-must-not-win"
  @env_keys ~w(GOOGLE_APPLICATION_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS_JSON
               AZURE_OPENAI_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
               PATH HOME LEMON_SECRETS_MASTER_KEY)

  setup do
    saved = Map.new(@env_keys, &{&1, System.get_env(&1)})
    tmp = Path.join(System.tmp_dir!(), "stream_fail_closed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    System.put_env("HOME", tmp)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    Enum.each(
      ~w(GOOGLE_APPLICATION_CREDENTIALS GOOGLE_APPLICATION_CREDENTIALS_JSON),
      &System.delete_env/1
    )

    clear_secrets_table()

    previous_req = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.request_path, conn.req_headers})
      Plug.Conn.send_resp(conn, 500, "unexpected request")
    end)

    on_exit(fn ->
      Req.default_options(previous_req)
      Req.Test.set_req_test_to_private(%{})
      clear_secrets_table()

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "an unreadable api_key_secret never selects the inline key", %{tmp: tmp} do
    corrupt("ZAI_SECRET")
    corrupt("AZURE_SECRET")
    System.put_env("AZURE_OPENAI_API_KEY", @tripwire)

    zai =
      Builder.build_stream_options(
        model(:zai, :openai_completions),
        %{"zai" => %{api_key_secret: "ZAI_SECRET", api_key: @tripwire}},
        %{},
        tmp
      )

    refute inspect(zai) =~ @tripwire
    assert zai.api_key == nil
    assert zai.api_key_authoritative

    azure =
      Builder.build_stream_options(
        model(:azure_openai_responses, :azure_openai_responses),
        %{"azure_openai_responses" => %{api_key_secret: "AZURE_SECRET", api_key: @tripwire}},
        %{},
        tmp
      )

    refute inspect(azure) =~ @tripwire
    assert azure.api_key == nil
  end

  test "an unreadable AWS secret never selects the ambient AWS credentials", %{tmp: tmp} do
    corrupt("AWS_KEY_SECRET")
    System.put_env("AWS_ACCESS_KEY_ID", @tripwire)

    opts =
      Builder.build_stream_options(
        model(:amazon_bedrock, :bedrock_converse_stream),
        %{"amazon_bedrock" => %{access_key_id_secret: "AWS_KEY_SECRET", region: "us-east-1"}},
        %{},
        tmp
      )

    refute inspect(opts) =~ @tripwire
  end

  describe "Vertex with an unreadable service-account secret" do
    setup %{tmp: tmp} do
      corrupt("VERTEX_SA")

      bin = Path.join(tmp, "bin")
      File.mkdir_p!(bin)
      marker = Path.join(tmp, "gcloud-called")
      gcloud = Path.join(bin, "gcloud")
      File.write!(gcloud, "#!/bin/sh\n: > '#{marker}'\nprintf '#{@tripwire}'\n")
      File.chmod!(gcloud, 0o700)
      System.put_env("PATH", bin <> ":" <> (System.get_env("PATH") || ""))

      providers = %{
        "google_vertex" => %{
          project: "proj",
          location: "us-central1",
          service_account_json_secret: "VERTEX_SA"
        }
      }

      opts =
        Builder.build_stream_options(model(:google_vertex, :google_vertex), providers, nil, tmp)

      {:ok, opts: opts, marker: marker}
    end

    test "refuses before a GOOGLE_APPLICATION_CREDENTIALS file", %{opts: opts, tmp: tmp} do
      path = Path.join(tmp, "ambient-sa.json")
      File.write!(path, "{")
      System.put_env("GOOGLE_APPLICATION_CREDENTIALS", path)

      message = vertex_error(opts)
      refute message =~ "Failed to parse service account JSON"
      assert message =~ "could not be read"
      refute_received {:request, _, _}
    end

    test "refuses before gcloud", %{opts: opts, marker: marker} do
      message = vertex_error(opts)
      assert message =~ "could not be read"
      refute File.exists?(marker)
      refute_received {:request, _, _}
    end
  end

  defp vertex_error(opts) do
    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = GoogleVertex.stream(vertex_model(), context, opts)
    assert {:error, %AssistantMessage{error_message: message}} = EventStream.result(stream, 5_000)
    message
  end

  defp vertex_model do
    %{
      model(:google_vertex, :google_vertex)
      | id: "gemini-2.5-pro",
        base_url: "https://example.test"
    }
  end

  defp model(provider, api) do
    %Model{
      id: "#{provider}-model",
      name: "#{provider}-model",
      provider: provider,
      api: api,
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 0,
      max_tokens: 0,
      headers: %{}
    }
  end

  defp corrupt(name), do: :ok = Store.put(Secrets.table(), {"default", name}, "corrupt-record")

  defp clear_secrets_table do
    Secrets.table()
    |> Store.list()
    |> Enum.each(fn {key, _} -> Store.delete(Secrets.table(), key) end)
  end
end
