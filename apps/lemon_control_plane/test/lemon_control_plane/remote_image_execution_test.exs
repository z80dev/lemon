defmodule LemonControlPlane.RemoteImageExecutionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.Worker
  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonAi.Types.{ImageContent, TextContent}
  alias LemonControlPlane.ImageInputs
  alias LemonCore.ExecutionContext
  alias LemonGateway.ExecutionRequest

  @tag :tmp_dir
  test "RPC image blocks become native content and survive remote image-only execution", %{
    tmp_dir: cwd
  } do
    wire = [%{"type" => "image", "mime_type" => "image/png", "data" => png()}]
    assert {:ok, [%ImageContent{}] = images} = ImageInputs.validate(wire)
    assert {:ok, context} = ExecutionContext.new(run_id: "image-only")

    request = %ExecutionRequest{
      run_id: "image-only",
      session_key: "agent:vision:main",
      prompt: "",
      execution_context: context,
      images: images
    }

    assert {:ok, payload} = RemoteRequestCodec.encode(request)
    assert payload["images"] == wire

    assert {:ok, decoded, _opts} =
             Worker.execution_request(
               payload,
               %Worker{name: "vision-node", default_cwd: cwd},
               "image-only"
             )

    assert decoded.prompt == ""
    assert decoded.images == images
    assert decoded.cwd == cwd

    assert {:ok, _, _} =
             Worker.execution_request(
               Map.put(payload, "prompt", nil),
               %Worker{name: "vision-node", default_cwd: cwd},
               "image-only"
             )

    assert {:error, {:invalid_request_payload, _}} =
             RemoteRequestCodec.encode(request, max_bytes: 64)
  end

  @tag :tmp_dir
  test "neither malformed content nor empty requests bypass image admission", %{tmp_dir: cwd} do
    state = %Worker{name: "vision-node", default_cwd: cwd}
    assert {:ok, context} = ExecutionContext.new(run_id: "image-invalid")
    assert {:ok, context} = ExecutionContext.for_remote(context, nil)
    assert {:ok, encoded_context} = ExecutionContext.encode(context)

    base = %{
      "version" => 2,
      "runId" => "image-invalid",
      "executionContext" => encoded_context,
      "prompt" => "",
      "images" => []
    }

    assert {:error, :missing_prompt} = Worker.execution_request(base, state, "empty")

    assert {:error, :missing_prompt} =
             Worker.execution_request(Map.put(base, "prompt", "  "), state, "empty")

    for bad <- [
          false,
          nil,
          "not-an-array",
          [%{"type" => "image", "mime_type" => "image/png", "data" => "eA=="}],
          [%{"type" => "image", "mime_type" => "image/png", "data" => "invalid"}],
          [%TextContent{text: "not an image"}]
        ] do
      assert {:error, _} =
               Worker.execution_request(Map.put(base, "images", bad), state, "invalid")
    end

    for bad <- [
          [%TextContent{text: "not an image"}],
          [%ImageContent{data: fn -> :private end}],
          [%ImageContent{type: :text, data: png()}],
          [%{"type" => "image", "mime_type" => "image/png", "data" => png()}],
          false
        ] do
      request = %ExecutionRequest{
        run_id: "image-invalid",
        session_key: "agent:vision:main",
        prompt: "hello",
        execution_context: context,
        images: bad
      }

      assert {:error, _} = RemoteRequestCodec.encode(request)
    end
  end

  test "shared validator retains count and aggregate decoded limits" do
    image = %ImageContent{mime_type: "image/png", data: png()}
    assert {:error, _} = LemonAi.ImageInputs.encode(List.duplicate(image, 6))

    large = %ImageContent{
      mime_type: "image/png",
      data: Base.encode64(<<137, "PNG", 13, 10, 26, 10>> <> :binary.copy(<<0>>, 5_242_873))
    }

    assert {:error, {:invalid_request, "images exceed the 10 MiB decoded size limit", nil}} =
             LemonAi.ImageInputs.encode([large, large])
  end

  defp png, do: Base.encode64(<<137, "PNG", 13, 10, 26, 10, 0>>)
end
