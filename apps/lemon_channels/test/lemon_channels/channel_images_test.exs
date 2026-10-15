defmodule LemonChannels.ChannelImagesTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Inbound, as: Discord
  alias LemonChannels.Adapters.Telegram.Inbound, as: Telegram
  alias LemonChannels.{ImageDownload, RunRequestBuilder}
  alias LemonChannels.Telegram.FakeAPI

  setup do
    FakeAPI.reset()
    :ok
  end

  test "file put captions retain their exact command and do not download image input" do
    request =
      telegram(%{"photo" => [photo("image", 10, 1)], "caption" => "/file put screenshot.jpg"})

    assert request.prompt == "/file put screenshot.jpg"
    assert request.images == []
    assert FakeAPI.sent(:get_file) == []
  end

  test "debounced images survive later text messages and share the image count cap" do
    image = %{data: "cG5n", mime_type: "image/png"}
    previous = %{message: %{text: "first", images: List.duplicate(image, 4)}}
    text = %{message: %{text: "second"}}
    assert ImageDownload.merge(text, previous).message.images == previous.message.images
    extra = %{message: %{text: "third", images: [image]}}
    merged = ImageDownload.merge(extra, previous)
    assert length(merged.message.images) == 4
    assert merged.message.text =~ "image limit exceeded"
  end

  test "Telegram chooses the largest photo within cap and preserves its caption" do
    FakeAPI.put_file("small", "small")
    FakeAPI.put_file("large", "large")

    photos = [
      photo("small", 10, 10),
      photo("large", 20, 20),
      photo("oversize", 30, ImageDownload.max_bytes() + 1)
    ]

    request = telegram(%{"photo" => photos, "caption" => "Explain this"})
    assert request.prompt == "Explain this"
    assert request.images == [%{data: Base.encode64("large"), mime_type: "image/jpeg"}]
  end

  test "caption-less Telegram photo still produces a nonempty prompt" do
    FakeAPI.put_file("photo", "jpeg")
    request = telegram(%{"photo" => [photo("photo", 10, 4)]})
    assert request.prompt == "[image]"
    assert [%{mime_type: "image/jpeg"}] = request.images
  end

  test "image documents reach the model, non-image documents remain unchanged" do
    FakeAPI.put_file("doc", "png")
    doc = %{"file_id" => "doc", "mime_type" => "image/png", "file_size" => 3}
    assert [%{mime_type: "image/png", data: "cG5n"}] = telegram(%{"document" => doc}).images

    request =
      telegram(%{"document" => %{doc | "mime_type" => "application/pdf"}, "caption" => "file"})

    assert request.images == []
    assert request.prompt == "file"
  end

  test "oversize metadata, oversized downloaded bodies and failures degrade to a note" do
    FakeAPI.put_file("oversize", :binary.copy("a", ImageDownload.max_bytes() + 1))
    request = telegram(%{"photo" => [photo("oversize", 10, ImageDownload.max_bytes() + 1)]})
    assert request.images == []
    assert request.prompt =~ "Image unavailable"
    assert FakeAPI.sent(:download_file) == []

    FakeAPI.stub(:get_file, {:ok, %{"ok" => true, "result" => %{"file_path" => "test"}}})
    FakeAPI.stub(:download_file, {:ok, :binary.copy("a", ImageDownload.max_bytes() + 1)})
    assert telegram(%{"photo" => [photo("photo", 10, 1)]}).images == []
    FakeAPI.stub(:get_file, {:error, :failed})
    assert telegram(%{"photo" => [photo("photo", 10, 1)]}).prompt =~ "Image unavailable"
  end

  test "Discord images use CDN-only downloads and keep non-image and failed attachment URLs" do
    image = attachment("https://cdn.discordapp.com/image.png", "image/png")
    file = attachment("https://example.com/file.txt", "text/plain")
    unsafe = attachment("https://example.com/image.png", "image/png")

    request =
      discord([image, file, unsafe], fn url, cap ->
        assert url == image.url
        assert cap == ImageDownload.max_bytes()
        {:ok, "png"}
      end)

    assert request.images == [%{data: "cG5n", mime_type: "image/png"}]
    assert request.prompt =~ file.url
    assert request.prompt =~ unsafe.url
    assert request.prompt =~ "Image unavailable"
  end

  test "Discord bounds count and size and keeps fallback text on download failure" do
    image = attachment("https://media.discordapp.net/image.png", "image/png")
    request = discord(List.duplicate(image, 6), fn _, _ -> {:ok, "png"} end)
    assert length(request.images) == 4
    assert request.prompt =~ "Image unavailable"

    assert discord([%{image | size: ImageDownload.max_bytes() + 1}], fn _, _ ->
             flunk("oversize fetched")
           end).images == []

    assert discord([image], fn _, _ -> {:error, :timeout} end).prompt =~ image.url
    refute ImageDownload.discord_url?("http://cdn.discordapp.com/image.png")
    refute ImageDownload.discord_url?("https://cdn.discordapp.com.evil.test/image.png")
    refute ImageDownload.discord_url?("https://user@cdn.discordapp.com/image.png")
  end

  test "streaming downloader stops oversized bodies and does not follow redirects" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "123456") end

    assert {:error, :too_large} =
             ImageDownload.download("https://cdn.discordapp.com/test", 5, plug: plug)

    assert {:ok, "123456"} =
             ImageDownload.download("https://cdn.discordapp.com/test", 6, plug: plug)

    redirect = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://example.com")
      |> Plug.Conn.send_resp(302, "")
    end

    assert {:error, :download_failed} =
             ImageDownload.download("https://cdn.discordapp.com/test", 6, plug: redirect)
  end

  defp photo(id, width, size),
    do: %{"file_id" => id, "width" => width, "height" => width, "file_size" => size}

  defp telegram(extra) do
    update = %{
      "message" =>
        Map.merge(%{"message_id" => 1, "chat" => %{"id" => 1, "type" => "private"}}, extra)
    }

    {:ok, inbound} = Telegram.normalize(update)
    inbound |> Telegram.attach_images(FakeAPI, "token") |> RunRequestBuilder.from_inbound()
  end

  defp attachment(url, type), do: %{url: url, content_type: type, size: 3}

  defp discord(attachments, download) do
    {:ok, inbound} =
      Discord.normalize(%{
        account_id: "default",
        message: %{id: 1, channel_id: 2, content: "look", attachments: attachments}
      })

    inbound |> Discord.attach_images(download) |> RunRequestBuilder.from_inbound()
  end
end
