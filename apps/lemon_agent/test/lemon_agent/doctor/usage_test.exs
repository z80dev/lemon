defmodule LemonAgent.Doctor.UsageTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Doctor.Checks.Usage
  alias LemonCore.Doctor.Check

  test "reports safe aggregate usage without leaking stored prompt or credential fields" do
    assert [%Check{name: "usage.status", status: :pass} = usage] =
             Usage.run(
               summary: %{
                 total_cost: 0.42,
                 total_requests: 3,
                 total_tokens: %{input: 1_000, output: 500},
                 breakdown: %{"openai" => 0.42},
                 requests: %{"openai" => 3},
                 tokens: %{"openai" => %{input: 1_000, output: 500}},
                 prompt: "private usage prompt",
                 api_key: "usage-secret-key"
               },
               today: %{},
               quotas: %{runs_limit: 10, tokens_limit: 2_000, cost_limit: 1.0}
             )

    assert usage.message =~ "3 request(s)"
    assert usage.message =~ "1500 token(s)"
    assert usage.message =~ "$0.4200 cost"
    assert usage.message =~ "1 provider(s)"
    refute inspect(usage) =~ "private usage prompt"
    refute inspect(usage) =~ "usage-secret-key"
  end

  test "warns when configured usage quotas are exceeded" do
    assert [%Check{name: "usage.status", status: :warn} = usage] =
             Usage.run(
               summary: %{
                 total_cost: 1.5,
                 total_requests: 3,
                 total_tokens: %{input: 1_000, output: 500}
               },
               today: %{},
               quotas: %{runs_limit: 2, tokens_limit: 1_000, cost_limit: 1.0}
             )

    assert usage.message =~ "over a configured quota"
    assert usage.remediation =~ "`usage.status`"
  end

  test "warns rather than treating unknown measurements as a cleared quota" do
    assert [%Check{name: "usage.status", status: :warn} = usage] =
             Usage.run(
               summary: %{total_requests: 1, total_cost: nil, total_tokens: nil},
               today: %{},
               quotas: %{runs_limit: 10, tokens_limit: 100, cost_limit: 1.0}
             )

    assert usage.message =~ "quota status is unknown"
    assert usage.message =~ "unknown token(s)"
    assert usage.message =~ "unknown cost"
    refute usage.message =~ "$0.0000"
  end
end
