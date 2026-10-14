defmodule LemonAi.ImageInputs do
  @moduledoc """
  Validates the shared image-content wire format and encodes native image blocks.

  Images are strictly padded standard Base64 PNG, JPEG, GIF or WebP blocks,
  with at most five images totaling 10 MiB decoded. Only known `ImageContent`
  structs may be encoded; arbitrary structs and executable values are rejected.
  """

  alias LemonAi.Types.ImageContent

  @max_images 5
  @max_decoded_bytes 10_485_760
  @max_encoded_bytes div(@max_decoded_bytes + 2, 3) * 4
  @mime_types ["image/png", "image/jpeg", "image/gif", "image/webp"]

  @type validation_error :: {:invalid_request, String.t(), nil}

  @spec encode(term()) :: {:ok, [map()]} | {:error, validation_error()}
  def encode(images) do
    with {:ok, wire} <- encode_blocks(images, [], 0),
         :ok <- validate_sizes(wire, 0),
         {:ok, nil} <- normalize(wire, nil) do
      {:ok, wire}
    end
  end

  defp encode_blocks([], images, _count), do: {:ok, Enum.reverse(images)}

  defp encode_blocks([_ | _], _images, @max_images),
    do: invalid("images must contain at most 5 entries")

  defp encode_blocks(
         [%ImageContent{type: :image, mime_type: mime_type, data: data} | rest],
         images,
         count
       ) when mime_type in @mime_types and is_binary(data) do
    image = %{"type" => "image", "mime_type" => mime_type, "data" => data}
    encode_blocks(rest, [image | images], count + 1)
  end

  defp encode_blocks(_images, _acc, _count),
    do: invalid("images must contain only native image-content blocks")

  @spec validate(term()) :: {:ok, [ImageContent.t()]} | {:error, validation_error()}
  def validate(images) do
    with :ok <- validate_count(images, 0),
         :ok <- validate_sizes(images, 0) do
      normalize(images, [])
    end
  end

  defp validate_count([], _count), do: :ok

  defp validate_count([_image | _rest], @max_images),
    do: invalid("images must contain at most 5 entries")

  defp validate_count([_image | rest], count), do: validate_count(rest, count + 1)
  defp validate_count(_images, _count), do: invalid("images must be an array")

  defp validate_sizes([], _total), do: :ok

  defp validate_sizes([image | rest], total) do
    with {:ok, decoded_size} <- image_size(image) do
      total = total + decoded_size

      if total <= @max_decoded_bytes do
        validate_sizes(rest, total)
      else
        invalid("images exceed the 10 MiB decoded size limit")
      end
    end
  end

  defp image_size(%{"type" => "image", "mime_type" => mime_type, "data" => data})
       when mime_type in @mime_types and is_binary(data) do
    size = byte_size(data)

    cond do
      size > @max_encoded_bytes ->
        invalid("images exceed the 10 MiB decoded size limit")

      size == 0 or rem(size, 4) != 0 ->
        invalid("image data must be strict standard Base64")

      true ->
        {:ok, div(size, 4) * 3 - padding_bytes(data, size)}
    end
  end

  defp image_size(_image),
    do: invalid("each image must have type image, a supported mime_type and binary data")

  defp padding_bytes(data, size) do
    cond do
      :binary.at(data, size - 1) != ?= -> 0
      :binary.at(data, size - 2) == ?= -> 2
      true -> 1
    end
  end

  defp normalize([], nil), do: {:ok, nil}
  defp normalize([], images), do: {:ok, Enum.reverse(images)}

  defp normalize([%{"mime_type" => mime_type, "data" => data} | rest], images) do
    with true <- canonical_padding?(data),
         {:ok, decoded} <- Base.decode64(data, padding: true),
         true <- image_header_matches?(decoded, mime_type) do
      images =
        if is_nil(images),
          do: nil,
          else: [%ImageContent{type: :image, data: data, mime_type: mime_type} | images]

      normalize(rest, images)
    else
      :error -> invalid("image data must be strict standard Base64")
      false -> invalid("image data must be strict standard Base64 with a matching image header")
    end
  end

  defp canonical_padding?(data) do
    size = byte_size(data)

    case padding_bytes(data, size) do
      0 -> true
      1 -> rem(base64_value(:binary.at(data, size - 2)), 4) == 0
      2 -> rem(base64_value(:binary.at(data, size - 3)), 16) == 0
    end
  end

  defp base64_value(char) when char in ?A..?Z, do: char - ?A + 26
  defp base64_value(char) when char in ?a..?z, do: char - ?a + 26
  defp base64_value(char) when char in ?0..?9, do: char - ?0 + 52
  defp base64_value(?+), do: 62
  defp base64_value(?/), do: 63
  defp base64_value(_char), do: -1

  defp image_header_matches?(<<137, "PNG", 13, 10, 26, 10, _rest::binary>>, "image/png"),
    do: true

  defp image_header_matches?(<<255, 216, 255, _rest::binary>>, "image/jpeg"), do: true
  defp image_header_matches?(<<"GIF87a", _rest::binary>>, "image/gif"), do: true
  defp image_header_matches?(<<"GIF89a", _rest::binary>>, "image/gif"), do: true

  defp image_header_matches?(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>, "image/webp"),
    do: true

  defp image_header_matches?(_decoded, _mime_type), do: false

  defp invalid(message), do: {:error, {:invalid_request, message, nil}}
end
