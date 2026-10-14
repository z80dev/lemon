defmodule LemonAi.Models.DiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonAi.{ModelCache, Models}
  alias LemonAi.Models.Discovery
  alias LemonAi.Types.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    ModelCache.invalidate_all()
    on_exit(&ModelCache.invalidate_all/0)
    :ok
  end

  defp req_options, do: [plug: {Req.Test, __MODULE__}]

  describe "openai_models" do
    test "lists /models with bearer auth and builds usable models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path, conn.req_headers})

        Req.Test.json(conn, %{
          "object" => "list",
          "data" => [
            %{"id" => "zeta/model", "context_length" => 32_768},
            %{"id" => "alpha-model", "max_model_len" => 8_192},
            %{"id" => ""},
            %{"object" => "model"}
          ]
        })
      end)

      assert {:ok, [alpha, zeta]} =
               Discovery.discover(:openai_models, "https://api.example.test/v1/",
                 provider: :together,
                 api_key: "synthetic-key",
                 req_options: req_options(),
                 model_defaults: %{max_tokens: 16_384, compat: %{supports_store: false}}
               )

      assert_receive {:request, "GET", "/v1/models", headers}
      assert {"authorization", "Bearer synthetic-key"} in headers

      assert %Model{
               id: "alpha-model",
               provider: :together,
               api: :openai_completions,
               base_url: "https://api.example.test/v1",
               context_window: 8_192,
               max_tokens: 8_192,
               compat: %{supports_store: false}
             } = alpha

      assert %Model{id: "zeta/model", context_window: 32_768, max_tokens: 16_384} = zeta
    end

    test "omits Authorization without an api key" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Req.Test.json(conn, [%{"id" => "local-model"}])
      end)

      assert {:ok, [%Model{id: "local-model"}]} =
               Discovery.discover(:openai_models, "http://127.0.0.1:1234/v1",
                 provider: :lm_studio,
                 req_options: req_options()
               )

      assert_receive {:headers, headers}
      refute List.keymember?(headers, "authorization", 0)
    end

    test "returns errors instead of raising and does not cache failures" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> Plug.Conn.send_resp(conn, 401, "nope")
          1 -> Plug.Conn.send_resp(conn, 500, "boom")
          2 -> Req.Test.json(conn, %{"unexpected" => true})
          3 -> Req.Test.transport_error(conn, :econnrefused)
          _ -> Req.Test.json(conn, %{"data" => [%{"id" => "recovered"}]})
        end
      end)

      opts = [provider: :vllm, req_options: req_options()]
      base = "http://127.0.0.1:8000/v1"

      assert {:error, {:authentication_rejected, 401}} =
               Discovery.discover(:openai_models, base, opts)

      assert {:error, {:http_error, 500}} = Discovery.discover(:openai_models, base, opts)

      assert {:error, :invalid_discovery_response} =
               Discovery.discover(:openai_models, base, opts)

      assert {:error, :transport_failure} = Discovery.discover(:openai_models, base, opts)
      assert {:ok, [%Model{id: "recovered"}]} = Discovery.discover(:openai_models, base, opts)
    end

    test "rejects unsupported kinds, apis and base urls" do
      assert {:error, {:unsupported_discovery_kind, :bogus}} =
               Discovery.discover(:bogus, "http://127.0.0.1:1/v1", [])

      assert {:error, :invalid_base_url} = Discovery.discover(:openai_models, "not a url", [])

      assert {:error, {:unsupported_api, :anthropic_messages}} =
               Discovery.discover(:openai_models, "http://127.0.0.1:1/v1",
                 api: :anthropic_messages
               )
    end

    test "caches by kind, provider and base url until the TTL or a forced refresh" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :requested)
        Req.Test.json(conn, %{"data" => [%{"id" => "cached-model"}]})
      end)

      opts = [provider: :vllm, req_options: req_options()]
      base = "http://127.0.0.1:8000/v1"

      assert {:ok, [_]} = Discovery.discover(:openai_models, base, opts)
      assert_receive :requested
      assert {:ok, [_]} = Discovery.discover(:openai_models, base, opts)
      refute_receive :requested, 50

      assert {:ok, [_]} = Discovery.discover(:openai_models, base, [{:ttl_ms, 0} | opts])
      assert_receive :requested

      assert {:ok, [_]} =
               Discovery.discover(:openai_models, base, [{:force_refresh, true} | opts])

      assert_receive :requested

      assert {:ok, [_]} = Discovery.discover(:openai_models, "http://other.test/v1", opts)
      assert_receive :requested

      assert [%Model{id: "cached-model"}] = Discovery.cached_models(:vllm)
      assert %Model{id: "cached-model"} = Discovery.cached_model(:vllm, "cached-model")
    end
  end

  describe "ollama" do
    test "uses native /api/tags and /api/show metadata" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        case {conn.method, conn.request_path} do
          {"GET", "/api/tags"} ->
            Req.Test.json(conn, %{
              "models" => [
                %{"name" => "qwen3:32b", "model" => "qwen3:32b"},
                %{"name" => "llava:7b", "model" => "llava:7b"}
              ]
            })

          {"POST", "/api/show"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            case Jason.decode!(body) do
              %{"model" => "qwen3:32b"} ->
                Req.Test.json(conn, %{
                  "capabilities" => ["completion", "tools", "thinking"],
                  "model_info" => %{"qwen3.context_length" => 40_960}
                })

              %{"model" => "llava:7b"} ->
                Plug.Conn.send_resp(conn, 500, "no metadata")
            end
        end
      end)

      assert {:ok, [llava, qwen]} =
               Discovery.discover(:ollama, "http://127.0.0.1:11434/v1",
                 provider: :ollama,
                 req_options: req_options(),
                 model_defaults: %{max_tokens: 8_192}
               )

      assert_receive {:request, "GET", "/api/tags"}

      assert %Model{
               id: "qwen3:32b",
               base_url: "http://127.0.0.1:11434/v1",
               context_window: 40_960,
               max_tokens: 8_192,
               reasoning: true,
               input: [:text]
             } = qwen

      assert %Model{id: "llava:7b", context_window: 128_000, reasoning: false} = llava
    end

    test "falls back to /v1/models when the native listing is unavailable" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/tags" -> Plug.Conn.send_resp(conn, 404, "not found")
          "/v1/models" -> Req.Test.json(conn, %{"data" => [%{"id" => "gpt-oss:20b"}]})
        end
      end)

      assert {:ok, [%Model{id: "gpt-oss:20b", base_url: "http://ollama.test:11434/v1"}]} =
               Discovery.discover(:ollama, "http://ollama.test:11434",
                 provider: :ollama,
                 req_options: req_options()
               )
    end
  end

  describe "LemonAi.Models presets" do
    test "discover_preset applies preset api, compat and defaults" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "lmstudio.test"
        Req.Test.json(conn, %{"data" => [%{"id" => "qwen2.5-coder-7b"}]})
      end)

      assert {:ok, [model]} =
               Models.discover_preset(:lm_studio,
                 base_url: "http://lmstudio.test:1234/v1",
                 req_options: req_options()
               )

      assert %Model{
               provider: :lm_studio,
               api: :openai_completions,
               base_url: "http://lmstudio.test:1234/v1",
               compat: %{allow_missing_api_key: true}
             } = model

      assert Models.get_model(:lm_studio, "qwen2.5-coder-7b") == model
      assert Models.known_model(:lm_studio, "qwen2.5-coder-7b") == model
      assert Models.get_models(:lm_studio) == [model]
      assert {:error, {:unknown_preset, :anthropic}} = Models.discover_preset(:anthropic)
    end
  end
end
