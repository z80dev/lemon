defmodule LemonChannels.ImageDownload do
  @moduledoc false

  @max_bytes 5 * 1024 * 1024
  @timeout_ms 30_000
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

    if images == [] do
      inbound
    else
      reason = if length(images) > @max_images, do: :limit, else: nil
      put_images(inbound, Enum.take(images, @max_images), reason)
    end
  end

  # Discord CDN media (images, voice notes) through `LemonCore.Net.HTTP`: the
  # address is authorized and pinned, redirects are refused, the body is cut
  # off above `max_bytes` while it streams, and the whole download has a 30 s
  # deadline. `net_opts` are fetcher stand-ins for tests (`:resolver`, `:send`).
  def download(url, max_bytes \\ @max_bytes, net_opts \\ []) do
    opts =
      net_opts
      |> Keyword.take([:resolver, :send])
      |> Keyword.merge(timeout_ms: @timeout_ms, max_body_bytes: max_bytes, max_redirects: 0)

    with true <- discord_url?(url),
         {:ok, %{status: 200, body: body}} when body != "" <-
           LemonCore.Net.HTTP.request(:get, url, opts) do
      {:ok, body}
    else
      {:error, {:body_too_large, _}} -> {:error, :too_large}
      _ -> {:error, :download_failed}
    end
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

    inbound = %{inbound | message: Map.put(inbound.message, :text, text)}
    reason = if failed?, do: :download_or_limit, else: nil
    put_images(inbound, Enum.reverse(images), reason)
  rescue
    _ -> put_images(inbound, :keep, :unavailable)
  end

  defp put_images(inbound, images, reason) do
    suffix =
      case reason do
        nil -> ""
        :limit -> "\n[Image unavailable: image limit exceeded.]"
        :download_or_limit -> "\n[Image unavailable: download failed or image limit exceeded.]"
        :unavailable -> "\n[Image unavailable.]"
      end

    message = Map.update!(inbound.message, :text, &(&1 <> suffix))
    message = if images == :keep, do: message, else: Map.put(message, :images, images)
    %{inbound | message: message}
  end
end
