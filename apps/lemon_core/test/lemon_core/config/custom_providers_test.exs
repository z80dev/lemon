defmodule LemonCore.Config.CustomProvidersTest do
  @moduledoc """
  Parsing and validation of custom provider/model definitions under `[providers.<id>]`.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Config.{Modular, Providers}

  @toml """
  [providers.my-gateway]
  api = "openai-completions"
  base_url = "https://llm.internal/v1"
  api_key_env = "MY_GATEWAY_KEY"
  auth = "none"
  headers = { "X-Team" = "platform" }
  discovery = { type = "lm-studio", timeout_ms = 2500 }

  [[providers.my-gateway.models]]
  id = "qwen3-coder"
  name = "Qwen3 Coder"
  context_window = 131072
  max_tokens = 16384
  reasoning = false
  input = ["text", "image"]
  cost = { input = 0.5, output = 1, cacheRead = 0.1 }
  headers = { "X-Model" = "qwen" }
  """

  test "parses custom provider keys into a validated binary shape" do
    {:ok, settings} = Toml.decode(@toml)
    providers = Providers.resolve(settings)
    cfg = Providers.get_provider(providers, "my-gateway")

    assert cfg.api == "openai_completions"
    assert cfg.base_url == "https://llm.internal/v1"
    assert cfg.api_key_env == "MY_GATEWAY_KEY"
    assert cfg.auth == "none"
    assert cfg.headers == %{"X-Team" => "platform"}
    assert cfg.discovery == "openai"
    assert cfg.discovery_timeout_ms == 2500

    assert [model] = cfg.models

    assert model == %{
             id: "qwen3-coder",
             name: "Qwen3 Coder",
             context_window: 131_072,
             max_tokens: 16_384,
             reasoning: false,
             input: ["text", "image"],
             cost: %{input: 0.5, output: 1, cache_read: 0.1},
             headers: %{"X-Model" => "qwen"}
           }

    assert {:ok, _config} = Modular.validate_settings(settings)
  end

  test "lemon config validation reports bad api, missing base_url and model errors" do
    settings = %{
      "providers" => %{
        "broken" => %{
          "api" => "carrier-pigeon",
          "auth" => "maybe",
          "discovery" => "proxy",
          "headers" => %{"X-Num" => 1},
          "models" => [
            %{"name" => "No id", "context_window" => 0, "input" => ["audio"]},
            %{"id" => "ok", "reasoning" => "yes", "cost" => %{"input" => -1}}
          ]
        },
        "keyless" => %{"api" => "openai_responses", "auth" => "none"}
      }
    }

    assert {:error, errors} = Modular.validate_settings(settings)

    expected = [
      "providers.providers.broken.api: invalid value \"carrier-pigeon\"",
      "providers.providers.broken.auth: invalid value \"maybe\"",
      "providers.providers.broken.discovery: invalid value \"proxy\"",
      "providers.providers.broken.base_url: is required",
      "providers.providers.broken.headers: header values must be strings",
      "providers.providers.broken.models[0].id: is required",
      "providers.providers.broken.models[0].context_window: must be a positive integer",
      "providers.providers.broken.models[0].input: must list",
      "providers.providers.broken.models[1].reasoning: must be a boolean",
      "providers.providers.broken.models[1].cost: prices must be non-negative numbers",
      "providers.providers.keyless.base_url: is required"
    ]

    for message <- expected do
      assert Enum.any?(errors, &String.starts_with?(&1, message)),
             "missing #{inspect(message)} in #{inspect(errors)}"
    end
  end
end
