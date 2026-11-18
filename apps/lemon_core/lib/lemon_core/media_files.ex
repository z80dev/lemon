defmodule LemonCore.MediaFiles do
  @moduledoc """
  The one image-extension list shared by agent file tools, router artifact
  tracking and channel attachment batching.
  """

  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))

  @doc "Lowercase extensions (with leading dot) treated as images."
  @spec image_extensions() :: MapSet.t(String.t())
  def image_extensions, do: @image_extensions

  @doc "Whether `path` has an image extension (case-insensitive)."
  @spec image_path?(term()) :: boolean()
  def image_path?(path) when is_binary(path),
    do: MapSet.member?(@image_extensions, path |> Path.extname() |> String.downcase())

  def image_path?(_path), do: false
end
