defmodule LemonMCP.SamplingTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Sampling

  @params %{
    "messages" => [
      %{"role" => "user", "content" => %{"type" => "text", "text" => "secret prompt"}}
    ],
    "maxTokens" => 16,
    "modelPreferences" => %{"hints" => [%{"name" => "lemon-test"}]}
  }

  test "summarize redacts message text and counts request shape" do
    summary = Sampling.summarize(@params)

    assert summary.message_count == 1
    assert summary.roles == ["user"]
    assert summary.content_kinds == %{"text" => 1}
    assert summary.text_char_count == 13
    assert summary.max_tokens == 16
    assert summary.requested_model == "lemon-test"
    assert is_binary(summary.request_hash)
    refute inspect(summary) =~ "secret prompt"
  end

  test "reviewed model mode calls reviewer before delegate with a redacted summary" do
    parent = self()

    reviewer = fn summary ->
      send(parent, {:reviewer, summary})
      :approve
    end

    delegate = fn params, summary ->
      send(parent, {:delegate, params, summary})
      {:ok, %{"role" => "assistant", "content" => %{"type" => "text", "text" => "ok"}}}
    end

    assert {:ok, %{"role" => "assistant"}} =
             Sampling.handle(@params,
               mode: :reviewed_model,
               reviewer: reviewer,
               delegate: delegate
             )

    assert_receive {:reviewer, reviewer_summary}
    assert_receive {:delegate, delegate_params, delegate_summary}
    assert delegate_params == @params
    assert reviewer_summary == delegate_summary
    refute inspect(reviewer_summary) =~ "secret prompt"
  end

  test "max token limits reject with safe summary" do
    assert {:error, error} = Sampling.handle(@params, mode: :deny, max_tokens: 8)

    assert error.reason == "max_tokens_exceeded"
    assert error.request.max_tokens == 16
    refute inspect(error) =~ "secret prompt"
  end

  test "model allowlists reject unknown models with safe summary" do
    assert {:error, error} =
             Sampling.handle(@params, mode: :deny, allowed_models: ["other-model"])

    assert error.reason == "model_not_allowed"
    assert error.request.requested_model == "lemon-test"
    refute inspect(error) =~ "secret prompt"
  end

  test "review rejection hashes detail and does not call delegate" do
    parent = self()

    reviewer = fn _summary -> {:reject, "contains secret prompt"} end
    delegate = fn _params, _summary -> send(parent, :delegate_called) end

    assert {:error, error} =
             Sampling.handle(@params,
               mode: :reviewed_model,
               reviewer: reviewer,
               delegate: delegate
             )

    assert error.reason.kind == "review_rejected"
    assert is_binary(error.reason.detail_hash)
    refute inspect(error) =~ "secret prompt"
    refute_received :delegate_called
  end
end
