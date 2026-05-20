defmodule LemonCore.UsageDiagnosticsTest do
  use ExUnit.Case, async: true

  alias LemonCore.UsageDiagnostics

  test "formats usage aggregates without surfacing sensitive stored fields" do
    today = Date.to_iso8601(Date.utc_today())

    result =
      UsageDiagnostics.status(
        summary: %{
          total_cost: 0.42,
          total_requests: 3,
          total_tokens: %{"input" => 1_000, "output" => 500},
          breakdown: %{"openai" => 0.4, anthropic: 0.02},
          requests: %{"openai" => 2, anthropic: 1},
          tokens: %{
            "openai" => %{"input" => 700, "output" => 300},
            anthropic: %{input: 300, output: 200}
          },
          prompt: "private usage diagnostics prompt",
          response: "private usage diagnostics response",
          api_key: "usage-diagnostics-secret-key"
        },
        today: %{
          date: today,
          total_cost: 0.42,
          requests: %{"openai" => 2, anthropic: 1},
          message_body: "private usage diagnostics message"
        },
        quotas: %{runs_limit: 10, tokens_limit: 2_000, cost_limit: 1.0}
      )

    assert result.status == "within_limits"
    assert result.period == "current"
    assert result.total_cost == 0.42
    assert result.total_requests == 3
    assert result.total_tokens == %{input: 1_000, output: 500, total: 1_500}
    assert result.today == %{date: today, cost: 0.42, requests: 3}
    assert result.quotas == %{runs_limit: 10, tokens_limit: 2_000, cost_limit: 1.0}
    assert result.cleanup.includes_prompts == false
    assert result.cleanup.includes_responses == false
    assert result.cleanup.includes_message_bodies == false
    assert result.cleanup.includes_credentials == false
    assert result.cleanup.includes_secret_values == false

    assert Enum.map(result.providers, & &1.provider) == ["anthropic", "openai"]

    openai = Enum.find(result.providers, &(&1.provider == "openai"))
    assert openai.cost == 0.4
    assert openai.requests == 2
    assert openai.input_tokens == 700
    assert openai.output_tokens == 300

    anthropic = Enum.find(result.providers, &(&1.provider == "anthropic"))
    assert anthropic.cost == 0.02
    assert anthropic.requests == 1
    assert anthropic.input_tokens == 300
    assert anthropic.output_tokens == 200

    result_text = inspect(result)
    refute result_text =~ "private usage diagnostics prompt"
    refute result_text =~ "private usage diagnostics response"
    refute result_text =~ "private usage diagnostics message"
    refute result_text =~ "usage-diagnostics-secret-key"
  end

  test "includes providers present only in request or token maps" do
    result =
      UsageDiagnostics.status(
        summary: %{
          requests: %{"openai" => 1},
          tokens: %{"zai" => %{input: 5, output: 6}}
        }
      )

    assert Enum.map(result.providers, & &1.provider) == ["openai", "zai"]
    assert Enum.find(result.providers, &(&1.provider == "openai")).requests == 1
    assert Enum.find(result.providers, &(&1.provider == "zai")).input_tokens == 5
  end

  test "reports over_limit when any configured quota is exceeded" do
    result =
      UsageDiagnostics.status(
        summary: %{
          total_cost: 1.5,
          total_requests: 3,
          total_tokens: %{input: 1_000, output: 500}
        },
        quotas: %{runs_limit: 2, tokens_limit: 2_000, cost_limit: 1.0}
      )

    assert result.status == "over_limit"
  end
end
