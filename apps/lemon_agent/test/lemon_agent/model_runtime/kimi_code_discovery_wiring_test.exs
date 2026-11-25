defmodule LemonAgent.ModelRuntime.KimiCodeDiscoveryWiringTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{CustomProviders, ModelCatalog}

  @base_url "https://kimi.example/coding"

  setup do
    LemonAi.ModelCache.invalidate_all()
    on_exit(&LemonAi.ModelCache.invalidate_all/0)

    for name <- ["KIMI_API_KEY", "MOONSHOT_API_KEY"] do
      previous = System.get_env(name)
      System.delete_env(name)
      on_exit(fn -> if previous, do: System.put_env(name, previous) end)
    end

    :ok
  end

  test "the picker lists the account's Kimi Code models and lookup resolves them" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:listed, conn.request_path})

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "k9-preview",
            "display_name" => "K9 Preview",
            "context_length" => 524_288,
            "supports_thinking_type" => "only",
            "think_efforts" => %{"support" => true, "valid_efforts" => ["low", "max"]}
          }
        ]
      })
    end)

    cfg = %{
      providers: %{"kimi_coding" => %{api_key: "sk-kimi-wiring", base_url: @base_url}},
      agent: %{}
    }

    models =
      ModelCatalog.available_models(
        config: cfg,
        discover_custom: false,
        kimi_code_req_options: [plug: {Req.Test, __MODULE__}]
      )

    assert_received {:listed, "/coding/v1/models"}
    kimi = Enum.filter(models, &(&1.provider == :kimi_coding))
    assert [%{id: "k9-preview", name: "K9 Preview", base_url: @base_url}] = kimi

    model = CustomProviders.lookup(cfg, "kimi_coding", "k9-preview")
    assert model.adaptive_thinking
    assert model.reasoning_efforts == [:low, :max]
    assert model.context_window == 524_288

    # Without a listing for this credential the bundled registry applies.
    assert is_nil(CustomProviders.lookup(cfg, "kimi_coding", "k3"))
  end
end
