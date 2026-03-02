defmodule LemonGateway.Transports.Webhook.PayloadTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Transports.Webhook.Payload

  describe "normalize/1" do
    test "extracts prompt from 'prompt' field" do
      assert {:ok, normalized} = Payload.normalize(%{"prompt" => "Hello"})
      assert normalized.prompt == "Hello"
    end

    test "extracts prompt from 'text' field" do
      assert {:ok, normalized} = Payload.normalize(%{"text" => "Hello"})
      assert normalized.prompt == "Hello"
    end

    test "extracts prompt from 'message' field" do
      assert {:ok, normalized} = Payload.normalize(%{"message" => "Hello"})
      assert normalized.prompt == "Hello"
    end

    test "extracts prompt from 'input' field" do
      assert {:ok, normalized} = Payload.normalize(%{"input" => "Hello"})
      assert normalized.prompt == "Hello"
    end

    test "extracts prompt from nested 'body.text' field" do
      assert {:ok, normalized} = Payload.normalize(%{"body" => %{"text" => "Hello"}})
      assert normalized.prompt == "Hello"
    end

    test "extracts prompt from nested 'content.text' field" do
      assert {:ok, normalized} = Payload.normalize(%{"content" => %{"text" => "Hello"}})
      assert normalized.prompt == "Hello"
    end

    test "returns error for empty payload" do
      assert {:error, :unprocessable_entity} = Payload.normalize(%{})
    end

    test "returns error for blank prompt" do
      assert {:error, :unprocessable_entity} = Payload.normalize(%{"prompt" => ""})
      assert {:error, :unprocessable_entity} = Payload.normalize(%{"prompt" => "   "})
    end

    test "returns error for non-map input" do
      assert {:error, :unprocessable_entity} = Payload.normalize("string")
      assert {:error, :unprocessable_entity} = Payload.normalize(nil)
    end

    test "extracts metadata from map" do
      payload = %{"prompt" => "Go", "metadata" => %{"source" => "zapier"}}
      assert {:ok, normalized} = Payload.normalize(payload)
      assert normalized.metadata == %{"source" => "zapier"}
    end

    test "extracts metadata from JSON string" do
      payload = %{"prompt" => "Go", "metadata" => ~s({"source":"api"})}
      assert {:ok, normalized} = Payload.normalize(payload)
      assert normalized.metadata == %{"source" => "api"}
    end

    test "returns empty map for invalid metadata" do
      payload = %{"prompt" => "Go", "metadata" => "not-json"}
      assert {:ok, normalized} = Payload.normalize(payload)
      assert normalized.metadata == %{}
    end

    test "extracts attachments from files array" do
      payload = %{
        "prompt" => "Check this",
        "files" => [%{"name" => "doc.txt", "url" => "https://example.test/doc.txt"}]
      }

      assert {:ok, normalized} = Payload.normalize(payload)
      assert length(normalized.attachments) == 1
      assert hd(normalized.attachments).url == "https://example.test/doc.txt"
    end

    test "extracts attachments from urls array" do
      payload = %{
        "prompt" => "Check",
        "urls" => ["https://example.test/img.png"]
      }

      assert {:ok, normalized} = Payload.normalize(payload)
      assert length(normalized.attachments) == 1
    end

    test "appends attachment info to prompt" do
      payload = %{
        "prompt" => "Review",
        "files" => [%{"name" => "spec.txt", "url" => "https://example.test/spec.txt"}]
      }

      assert {:ok, normalized} = Payload.normalize(payload)
      assert normalized.prompt =~ "Review"
      assert normalized.prompt =~ "Attachments:"
      assert normalized.prompt =~ "spec.txt"
      assert normalized.prompt =~ "https://example.test/spec.txt"
    end

    test "deduplicates attachments" do
      payload = %{
        "prompt" => "Go",
        "attachments" => [
          %{"url" => "https://example.test/a.txt"},
          %{"url" => "https://example.test/a.txt"}
        ]
      }

      assert {:ok, normalized} = Payload.normalize(payload)
      assert length(normalized.attachments) == 1
    end

    test "handles complex multi-source payload" do
      payload = %{
        "content" => %{"text" => "Ship this"},
        "files" => [%{"name" => "spec.txt", "url" => "https://example.test/spec.txt"}],
        "urls" => ["https://example.test/mock.png"],
        "metadata" => %{"source" => "zapier", "workflow_id" => "wf_123"}
      }

      assert {:ok, normalized} = Payload.normalize(payload)
      assert normalized.prompt =~ "Ship this"
      assert normalized.prompt =~ "Attachments:"
      assert length(normalized.attachments) == 2
      assert normalized.metadata["source"] == "zapier"
    end
  end
end
