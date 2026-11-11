defmodule CodingAgent.ExecutionNode.ConnectFailureTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.ConnectFailure

  test "classifies old and current controller errors without trusting arbitrary reasons" do
    for code <- ["UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND"] do
      assert ConnectFailure.classify(%{"code" => code}) ==
               {:needs_reauthorization, "credential_rejected"}

      for reason <- ~w(session_expired session_invalid node_not_found node_name_conflict) do
        assert ConnectFailure.classify(%{"code" => code, "details" => %{"reason" => reason}}) ==
                 {:needs_reauthorization, reason}
      end
    end

    assert ConnectFailure.classify(%{"code" => "CONFLICT"}) == {:conflict, "conflict"}
    assert ConnectFailure.classify(%{
             "code" => "CONFLICT",
             "details" => %{"reason" => "node_name_conflict"}
           }) ==
             {:conflict, "node_name_conflict"}

    assert ConnectFailure.classify(%{"code" => "UNAUTHORIZED", "details" => %{"reason" => "secret"}}) ==
             {:needs_reauthorization, "credential_rejected"}
  end

  test "outages and malformed or unknown responses are transient" do
    codes = ~w(INTERNAL_ERROR UNAVAILABLE TIMEOUT RATE_LIMITED UNKNOWN)
    errors = Enum.map(codes, &%{"code" => &1})

    for error <- [nil, [], "UNAUTHORIZED", %{}, %{"details" => nil}] ++ errors do
      assert ConnectFailure.classify(error) == :transient
    end
  end
end
