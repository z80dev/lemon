defmodule LemonControlPlane.Protocol.ErrorsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Errors

  describe "error/3" do
    test "returns {code, message} when details are omitted or nil" do
      assert Errors.error(:invalid_request, "Malformed request") ==
               {:invalid_request, "Malformed request"}

      assert Errors.error(:invalid_request, "Malformed request", nil) ==
               {:invalid_request, "Malformed request"}
    end

    test "returns {code, message, details} when details are present" do
      details = %{field: "agentId"}

      assert Errors.error(:invalid_params, "Invalid agentId", details) ==
               {:invalid_params, "Invalid agentId", details}
    end
  end

  describe "to_payload/1" do
    test "converts {code, message}" do
      assert Errors.to_payload({:invalid_request, "Malformed request"}) == %{
               "code" => "INVALID_REQUEST",
               "message" => "Malformed request"
             }
    end

    test "converts {code, message, details}" do
      details = %{field: "agentId"}

      assert Errors.to_payload({:invalid_params, "Invalid agentId", details}) == %{
               "code" => "INVALID_PARAMS",
               "message" => "Invalid agentId",
               "details" => details
             }
    end

    test "converts map input" do
      assert Errors.to_payload(%{
               code: :custom_error,
               message: "Custom problem",
               details: %{trace_id: "abc-123"}
             }) == %{
               "code" => "custom_error",
               "message" => "Custom problem",
               "details" => %{trace_id: "abc-123"}
             }
    end

    test "falls back to INTERNAL_ERROR for unknown tuple code" do
      assert Errors.to_payload({:unknown_code, "Oops"}) == %{
               "code" => "INTERNAL_ERROR",
               "message" => "Oops"
             }
    end

    test "falls back for unexpected input" do
      assert Errors.to_payload(:boom) == %{
               "code" => "INTERNAL_ERROR",
               "message" => "An unexpected error occurred",
               "details" => ":boom"
             }
    end
  end

  describe "constructor helpers" do
    test "return expected tuples" do
      assert Errors.invalid_request("Bad frame") == {:invalid_request, "Bad frame"}

      assert Errors.method_not_found("agent.run") ==
               {:method_not_found, "Unknown method: agent.run"}

      assert Errors.unauthorized() == {:unauthorized, "Authentication required"}
      assert Errors.unauthorized("Token expired") == {:unauthorized, "Token expired"}

      assert Errors.permission_denied() == {:permission_denied, "Permission denied"}

      assert Errors.permission_denied("Missing scope: admin") ==
               {:permission_denied, "Missing scope: admin"}

      assert Errors.timeout() == {:timeout, "Operation timed out"}
      assert Errors.timeout("deadline exceeded") == {:timeout, "deadline exceeded"}
    end
  end
end
