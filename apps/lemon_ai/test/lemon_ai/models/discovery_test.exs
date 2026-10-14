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

    test "caches in the same scope until the TTL or a forced refresh" do
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

      assert [%Model{id: "cached-model"}] =
               Discovery.cached_models(:openai_models, base, opts)

      assert %Model{id: "cached-model"} =
               Discovery.cached_model(:openai_models, base, "cached-model", opts)
    end

    test "isolates credentials, headers, wire API and model defaults" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:requested, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"data" => [%{"id" => "shared-model"}]})
      end)

      base = "https://gateway.test/v1"

      original = [
        provider: "gateway",
        api_key: "account-one-secret",
        headers: %{"X-Tenant" => "tenant-one-secret"},
        model_defaults: %{headers: %{"X-Model-Secret" => "model-one-secret"}},
        req_options: req_options()
      ]

      assert {:ok, [first]} = Discovery.discover(:openai_models, base, original)
      assert_receive {:requested, ["Bearer account-one-secret"]}

      for changed <- [
            Keyword.put(original, :api_key, "account-two-secret"),
            Keyword.put(original, :headers, %{"x-tenant" => "tenant-two-secret"}),
            Keyword.put(original, :api, :openai_responses),
            Keyword.put(original, :model_defaults, %{headers: %{"X-Model-Secret" => "new-secret"}}),
            Keyword.put(
              original,
              :req_options,
              [auth: {:bearer, "req-account-secret"}] ++ req_options()
            ),
            Keyword.put(original, :req_options, [params: [tenant: "req-tenant"]] ++ req_options())
          ] do
        assert Discovery.cached_model(:openai_models, base, "shared-model", changed) == nil
        assert {:ok, [model]} = Discovery.discover(:openai_models, base, changed)
        assert_receive {:requested, _}
        assert model.api == Keyword.get(changed, :api, :openai_completions)
        assert model.headers == Keyword.fetch!(changed, :model_defaults).headers
        assert {:ok, [^model]} = Discovery.discover(:openai_models, base, changed)
        refute_receive {:requested, _}, 20
      end

      assert Discovery.cached_model(:openai_models, base, "shared-model", original) == first
      assert Discovery.cached_models(:openai_models, "https://other.test/v1", original) == []

      keys = inspect(ModelCache.stats().providers)
      refute keys =~ "account-one-secret"
      refute keys =~ "tenant-one-secret"
      refute keys =~ "model-one-secret"
      refute keys =~ "req-account-secret"
    end

    test "explicit auth headers replace generated auth case-insensitively" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer header-secret"]
        Req.Test.json(conn, %{"data" => []})
      end)

      assert {:ok, []} =
               Discovery.discover(:openai_models, "https://gateway.test/v1",
                 api_key: "unused-secret",
                 headers: %{"Authorization" => "Bearer header-secret"},
                 req_options: req_options()
               )
    end

    test "does not redirect credential-bearing discovery requests" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "gateway.test"

        conn
        |> Plug.Conn.put_resp_header("location", "https://other.test/v1/models")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:http_error, 302}} =
               Discovery.discover(:openai_models, "https://gateway.test/v1",
                 api_key: "account-secret",
                 req_options: [redirect: true] ++ req_options()
               )
    end

    test "rejects URLs with embedded credentials, queries or fragments before HTTP" do
      Req.Test.stub(__MODULE__, fn _ -> flunk("invalid URLs must not make requests") end)

      for base <- [
            "https://user:secret@gateway.test/v1",
            "https://gateway.test/v1?token=secret",
            "https://gateway.test/v1#fragment"
          ] do
        assert {:error, :invalid_base_url} =
                 Discovery.discover(:openai_models, base, req_options: req_options())
      end
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

    test "authentication rejection does not fall back to another listing path" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, conn.request_path)
        Plug.Conn.send_resp(conn, 401, "")
      end)

      assert {:error, {:authentication_rejected, 401}} =
               Discovery.discover(:ollama, "http://ollama.test:11434", req_options: req_options())

      assert_receive "/api/tags"
      refute_received "/v1/models"
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

      # A caller-supplied endpoint must not become the default provider's model.
      assert Models.known_model(:lm_studio, "qwen2.5-coder-7b") == nil
      assert Models.get_models(:lm_studio) == []
      refute Models.get_model(:lm_studio, "qwen2.5-coder-7b").base_url == model.base_url
      assert {:error, {:unknown_preset, :anthropic}} = Models.discover_preset(:anthropic)
    end
  end
end
