defmodule CodingAgent.Session.CompactionManagerOverflowTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.CompactionManager

  describe "context_length_exceeded_error?/1" do
    test "detects structured provider errors, including inside wrappers" do
      http = {:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}}

      for error <- [
            %{category: :context_length, message: "provider said no"},
            :context_length_exceeded,
            http,
            {:http_error, 400, %{error: %{message: "maximum context length exceeded"}}},
            {:error, http},
            {:assistant_error, http},
            %{reason: http},
            {:error, %{category: :context_length}},
            "This model's context window is full"
          ] do
        assert CompactionManager.context_length_exceeded_error?(error), inspect(error)
      end
    end

    test "does not flag unrelated failures" do
      for error <- [
            {:http_error, 429, "Rate limited"},
            %{category: :rate_limit},
            {:error, :timeout},
            nil
          ] do
        refute CompactionManager.context_length_exceeded_error?(error), inspect(error)
      end
    end
  end
end
