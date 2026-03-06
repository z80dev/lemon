defmodule LemonChannels.Adapters.Telegram.FileBatcher do
  @moduledoc false

  @telegram_media_group_max_items 10

  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))

  @spec batch([map()]) :: [[map()]]
  def batch(files) when is_list(files) do
    {batches_rev, pending_images_rev} =
      Enum.reduce(files, {[], []}, fn file, {batches, pending_images} ->
        path = file[:path] || file["path"]

        if image_file?(path) do
          pending_images = [file | pending_images]

          if length(pending_images) >= @telegram_media_group_max_items do
            {[Enum.reverse(pending_images) | batches], []}
          else
            {batches, pending_images}
          end
        else
          batches = flush_image_batch(batches, pending_images)
          {[[file] | batches], []}
        end
      end)

    batches_rev
    |> flush_image_batch(pending_images_rev)
    |> Enum.reverse()
  end

  def batch(_), do: []

  defp flush_image_batch(batches, []), do: batches
  defp flush_image_batch(batches, pending_images), do: [Enum.reverse(pending_images) | batches]

  defp image_file?(path) when is_binary(path),
    do:
      path
      |> Path.extname()
      |> String.downcase()
      |> then(&MapSet.member?(@image_extensions, &1))

  defp image_file?(_), do: false
end
