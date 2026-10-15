defmodule LemonAi.ImageInputsTest do
  use ExUnit.Case, async: true

  alias LemonAi.ImageInputs
  alias LemonAi.Types.{ImageContent, TextContent}

  test "validated native blocks and established wire images round-trip exactly" do
    images = [
      %ImageContent{
        mime_type: "image/png",
        data: Base.encode64(<<137, "PNG", 13, 10, 26, 10, 0>>)
      },
      %ImageContent{mime_type: "image/jpeg", data: Base.encode64(<<255, 216, 255, 0>>)},
      %ImageContent{mime_type: "image/gif", data: Base.encode64("GIF89a\0")},
      %ImageContent{mime_type: "image/webp", data: Base.encode64("RIFF\0\0\0\0WEBP\0")}
    ]

    assert {:ok, wire} = ImageInputs.encode(images)
    assert Enum.map(wire, & &1["type"]) == List.duplicate("image", 4)
    assert {:ok, ^images} = ImageInputs.validate(wire)
    assert {:ok, []} = ImageInputs.encode([])
    assert {:ok, []} = ImageInputs.validate([])
    assert {:error, _} = ImageInputs.encode(List.duplicate(hd(images), 6))
  end

  test "encoding is not generic struct serialization and wire validation stays strict" do
    for invalid <- [
          false,
          nil,
          [%TextContent{text: "not image"}],
          [%ImageContent{data: self()}],
          [%ImageContent{data: fn -> :secret end}],
          [%ImageContent{type: :text, data: "AAAA"}],
          [%{"type" => "image", "mime_type" => "image/png", "data" => "AAAA"}]
        ] do
      assert {:error, {:invalid_request, _, nil}} = ImageInputs.encode(invalid)
    end

    for data <- ["", "eA", "eA=", "eB==", "eA==\n", "____", "eA=="] do
      assert {:error, {:invalid_request, _, nil}} =
               ImageInputs.validate([
                 %{"type" => "image", "mime_type" => "image/png", "data" => data}
               ])
    end

    assert {:error, _} =
             ImageInputs.validate([
               %{"type" => "image", "mime_type" => "image/svg+xml", "data" => "AAAA"}
             ])
  end
end
