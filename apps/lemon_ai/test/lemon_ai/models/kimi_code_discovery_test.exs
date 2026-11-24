defmodule LemonAi.Models.KimiCodeDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonAi.{ModelCache, Models}
  alias LemonAi.Models.KimiCodeDiscovery, as: Discovery

  # Fixture shaped like omp's live `/coding/v1/models` K3 row.
  @k3 %{
    "id" => "k3",
    "display_name" => "K3",
    "context_length" => 1_048_576,
    "supports_reasoning" => true,
    "supports_thinking_type" => "only",
    "supports_image_in" => true,
    "think_efforts" => %{
      "support" => true,
      "valid_efforts" => ["low", "high", "max"],
      "default_effort" => "max"
    },
    "protocol" => nil
  }

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    ModelCache.invalidate_all()
    on_exit(&ModelCache.invalidate_all/0)
    :ok
  end

  test "maps efforts, context, image input and per-family output caps" do
    {:ok, models} =
      Discovery.models_from_listing(%{
        "data" => [
          @k3,
          Map.merge(@k3, %{"id" => "k3-256k", "context_length" => 262_144}),
          %{"id" => "kimi-for-coding", "context_length" => 262_144, "supports_reasoning" => true},
          %{"id" => "kimi-k9-new", "display_name" => "K9", "context_length" => 131_072},
          Map.merge(@k3, %{
            "id" => "non-thinking",
            "supports_thinking_type" => "no",
            "think_efforts" => nil
          }),
          %{"id" => 42},
          "junk"
        ]
      })

    by_id = Map.new(models, &{&1.id, &1})
    assert Enum.sort(Map.keys(by_id)) == ~w(k3 k3-256k kimi-for-coding kimi-k9-new non-thinking)

    k3 = by_id["k3"]
    assert k3.name == "K3"
    assert k3.provider == :kimi_coding
    assert k3.api == :anthropic_messages
    assert k3.base_url == "https://api.kimi.com/coding"
    assert k3.reasoning and k3.adaptive_thinking
    assert k3.reasoning_efforts == [:low, :high, :max]
    assert k3.context_window == 1_048_576
    assert k3.max_tokens == 131_072
    assert k3.input == [:text, :image]
    assert k3.compat[:anthropic_session_user_id]

    assert by_id["k3-256k"].max_tokens == 131_072
    assert by_id["k3-256k"].context_window == 262_144

    # Catalog-known legacy row without efforts keeps the bundled thinking shape and image input.
    legacy = by_id["kimi-for-coding"]
    bundled = Models.get_model(:kimi_coding, "kimi-for-coding")
    assert legacy.max_tokens == 32_768
    assert legacy.context_window == 262_144
    assert legacy.adaptive_thinking == bundled.adaptive_thinking
    assert legacy.reasoning_efforts == bundled.reasoning_efforts
    assert :image in legacy.input

    new = by_id["kimi-k9-new"]
    assert new.name == "K9"
    assert new.max_tokens == 32_000
    refute new.reasoning
    assert new.input == [:text]

    off = by_id["non-thinking"]
    refute off.reasoning
    refute off.adaptive_thinking
    assert off.reasoning_efforts == []
  end

  test "malformed listing is an error, never an empty catalog" do
    assert {:error, :invalid_discovery_response} = Discovery.models_from_listing(%{"x" => 1})
    assert {:error, :invalid_discovery_response} = Discovery.models_from_listing(nil)
  end

  test "discover sends bearer + fingerprint, caches by account and never stores the token" do
    test_pid = self()
    token = jwt(%{"user_id" => "synthetic-user", "exp" => 4_102_444_800})

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :requested)
      assert conn.request_path == "/coding/v1/models"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> token]
      assert [_platform] = Plug.Conn.get_req_header(conn, "x-msh-platform")
      Req.Test.json(conn, %{"data" => [@k3]})
    end)

    assert {:ok, [%{id: "k3"} = model]} = Discovery.discover(options(token))
    assert_receive :requested

    # A refreshed token for the same account reuses the cached listing.
    renewed = jwt(%{"user_id" => "synthetic-user", "exp" => 4_102_444_900})
    assert {:ok, [^model]} = Discovery.discover(options(renewed))
    refute_receive :requested, 20
    assert Discovery.cached_model("k3", options(renewed)) == model
    assert is_nil(Discovery.cached_model("k3", options("other-key")))

    keys = inspect(ModelCache.stats().providers)
    refute keys =~ "synthetic-user"
    refute keys =~ token
  end

  test "HTTP failures return reason atoms without the credential" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 401, "secret body") end)
    assert {:error, {:authentication_rejected, 401}} = Discovery.discover(options("sk-kimi-x"))

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_error, 500}} = Discovery.discover(options("sk-kimi-x"))

    assert {:error, :missing_kimi_code_credentials} = Discovery.discover([])
  end

  test "list_models replaces bundled kimi_coding models only on a successful listing" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"data" => [@k3]}) end)

    discovered =
      Models.list_models(
        discover_kimi_code: true,
        kimi_code_access_token: "sk-kimi-list",
        kimi_code_base_url: "https://api.kimi.com/coding",
        kimi_code_req_options: [plug: {Req.Test, __MODULE__}]
      )

    assert [%{id: "k3"}] = Enum.filter(discovered, &(&1.provider == :kimi_coding))

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

    fallback =
      Models.list_models(
        discover_kimi_code: true,
        kimi_code_access_token: "sk-kimi-other",
        kimi_code_req_options: [plug: {Req.Test, __MODULE__}]
      )

    assert Enum.count(fallback, &(&1.provider == :kimi_coding)) ==
             length(Models.get_models(:kimi_coding))
  end

  defp options(token) do
    [
      access_token: token,
      base_url: "https://api.kimi.com/coding/",
      req_options: [plug: {Req.Test, __MODULE__}]
    ]
  end

  defp jwt(claims) do
    encode = &Base.url_encode64(Jason.encode!(&1), padding: false)
    encode.(%{"alg" => "none"}) <> "." <> encode.(claims) <> ".sig"
  end
end
