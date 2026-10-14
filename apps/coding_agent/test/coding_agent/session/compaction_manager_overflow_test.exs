defmodule CodingAgent.Session.CompactionManagerOverflowTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.CompactionManager

  describe "context_length_exceeded_error?/1" do
    test "recognizes structured provider errors" do
      assert CompactionManager.context_length_exceeded_error?(%{
               category: :context_length,
               message: "provider said no"
             })

      assert CompactionManager.context_length_exceeded_error?(:context_length_exceeded)

      assert CompactionManager.context_length_exceeded_error?(
               {:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}}
             )

      assert CompactionManager.context_length_exceeded_error?(
               {:http_error, 400, %{error: %{message: "maximum context length exceeded"}}}
             )
    end

    test "sees through common error wrappers" do
      http = {:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}}

      assert CompactionManager.context_length_exceeded_error?({:error, http})
      assert CompactionManager.context_length_exceeded_error?({:assistant_error, http})
      assert CompactionManager.context_length_exceeded_error?(%{reason: http})

      assert CompactionManager.context_length_exceeded_error?(
               {:error, %{category: :context_length}}
             )
    end

    test "keeps the text heuristics as a fallback" do
      assert CompactionManager.context_length_exceeded_error?(
               "This model's context window is full"
             )

      assert CompactionManager.context_length_exceeded_error?("上下文窗口已满")
      assert CompactionManager.context_length_exceeded_error?({:weird, "maximum context length"})
    end

    test "does not flag unrelated failures" do
      refute CompactionManager.context_length_exceeded_error?({:http_error, 429, "Rate limited"})
      refute CompactionManager.context_length_exceeded_error?(%{category: :rate_limit})
      refute CompactionManager.context_length_exceeded_error?({:error, :timeout})
      refute CompactionManager.context_length_exceeded_error?(nil)
    end
  end
end
