defmodule LemonChannels.ImageDownload do
  @moduledoc false

  @max_bytes 5 * 1024 * 1024
  @max_images 4

  def max_bytes, do: @max_bytes
  def max_images, do: @max_images

  def image_mime?("image/" <> subtype), do: subtype != ""
  def image_mime?(_), do: false

  def discord_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443}
      when host in ["cdn.discordapp.com", "media.discordapp.net"] ->
        true

      _ ->
        false
    end
  end

  def discord_url?(_), do: false

  def merge(inbound, previous) do
    images = Map.get(previous.message, :images, []) ++ Map.get(inbound.message, :images, [])
    text = inbound.message.text

    text =
      if length(images) > @max_images,
        do: text <> "\n[Image unavailable: image limit exceeded.]",
        else: text

    if images == [] do
      inbound
    else
      message =
        inbound.message
        |> Map.put(:images, Enum.take(images, @max_images))
        |> Map.put(:text, text)

      %{inbound | message: message}
    end
  end

  def download(url, max_bytes \\ @max_bytes, opts \\ []) do
    into = fn {:data, chunk}, {req, resp} ->
      {size, chunks} = if is_tuple(resp.body), do: resp.body, else: {0, []}

      if size + byte_size(chunk) > max_bytes do
        {:halt, {req, %{resp | body: :too_large}}}
      else
        {:cont, {req, %{resp | body: {size + byte_size(chunk), [chunk | chunks]}}}}
      end
    end

    opts =
      Keyword.merge(opts,
        into: into,
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: 15_000
      )

    case Req.get(url, opts) do
      {:ok, %{body: :too_large}} ->
        {:error, :too_large}

      {:ok, %{status: 200, body: {size, chunks}}} when size > 0 ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      _ ->
        {:error, :download_failed}
    end
  rescue
    _ -> {:error, :download_failed}
  end

  def attach(inbound, candidates, fetch) do
    {images, failed?} =
      candidates
      |> Enum.take(@max_images)
      |> Enum.reduce({[], length(candidates) > @max_images}, fn candidate, {images, failed?} ->
        case fetch.(candidate) do
          {:ok, bytes, mime}
          when is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= @max_bytes ->
            {[%{data: Base.encode64(bytes), mime_type: mime} | images], failed?}

          _ ->
            {images, true}
        end
      end)

    text = inbound.message.text
    text = if String.trim(text) == "" and candidates != [], do: "[image]", else: text

    text =
      if failed?,
        do: text <> "\n[Image unavailable: download failed or image limit exceeded.]",
        else: text

    message = inbound.message |> Map.put(:text, text) |> Map.put(:images, Enum.reverse(images))
    %{inbound | message: message}
  rescue
    _ ->
      %{inbound | message: Map.update!(inbound.message, :text, &(&1 <> "\n[Image unavailable.]"))}
  end
end
