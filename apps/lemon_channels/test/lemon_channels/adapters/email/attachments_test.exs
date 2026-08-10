defmodule LemonChannels.Adapters.Email.AttachmentsTest do
  @moduledoc """
  Attachment handling: what gets written, what gets refused, and what the agent
  is told about it.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Email
  alias LemonChannels.Adapters.Email.Attachments

  setup do
    previous = Application.get_env(:lemon_channels, Email)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:lemon_channels, Email)
        value -> Application.put_env(:lemon_channels, Email, value)
      end
    end)

    :ok
  end

  defp run(attachments) do
    {metas, writes} = Attachments.prepare(attachments)
    Enum.each(writes, & &1.())
    metas
  end

  describe "prepare/1" do
    test "writes inline bytes to a path the agent can open" do
      [meta] = run([%{"filename" => "notes.txt", "content" => "hello"}])

      assert meta.filename == "notes.txt"
      assert meta.bytes == 5
      assert File.read!(meta.path) == "hello"
    end

    test "decodes base64 content, which is how most providers send it" do
      encoded = Base.encode64(String.duplicate("lemon", 8))

      [meta] = run([%{"filename" => "blob.bin", "content" => encoded}])

      assert File.read!(meta.path) == String.duplicate("lemon", 8)
    end

    test "reduces a filename to something that cannot escape the directory" do
      [meta] = run([%{"filename" => "../../etc/passwd", "content" => "x"}])

      assert meta.filename == "passwd"
      assert Path.dirname(meta.path) |> Path.basename() == "lemon_channels_email_attachments"
    end

    test "names an unnamed attachment rather than writing to a bare directory" do
      [meta] = run([%{"content" => "x"}])

      assert meta.filename == "attachment.bin"
    end

    test "drops an attachment over the cap instead of truncating it" do
      Application.put_env(:lemon_channels, Email, attachment_max_bytes: 4)

      assert run([%{"filename" => "big.txt", "content" => "far too long"}]) == []
    end

    test "passes a URL-only attachment through without fetching it" do
      [meta] = run([%{"filename" => "remote.pdf", "url" => "https://example.com/remote.pdf"}])

      assert meta.url == "https://example.com/remote.pdf"
      assert meta.path == nil
      assert meta.bytes == nil
    end

    test "copies a multipart upload off the request's temp file" do
      source = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
      File.write!(source, "uploaded")
      on_exit(fn -> File.rm(source) end)

      [meta] =
        run([%Plug.Upload{path: source, filename: "report.csv", content_type: "text/csv"}])

      assert meta.filename == "report.csv"
      assert meta.content_type == "text/csv"
      assert File.read!(meta.path) == "uploaded"
    end

    test "ignores entries with neither content, upload nor url" do
      assert run([%{"filename" => "empty.txt"}, "", nil, 42]) == []
    end

    test "ignores a non-list" do
      assert Attachments.prepare(nil) == {[], []}
      assert Attachments.prepare("nope") == {[], []}
    end
  end

  describe "describe/1" do
    test "gives the agent the name, type, size and location" do
      assert Attachments.describe([
               %{filename: "a.txt", content_type: "text/plain", path: "/tmp/a.txt", bytes: 12}
             ]) == ["- a.txt (text/plain, 12 bytes) at /tmp/a.txt"]
    end

    test "says so when the size or type is unknown" do
      assert [line] = Attachments.describe([%{filename: "a", url: "https://x.test/a"}])

      assert line == "- a (application/octet-stream, size unknown) at https://x.test/a"
    end
  end

  describe "the inbound message" do
    test "carries attachment locations in the text, since that is the whole prompt" do
      {:ok, message} =
        Email.normalize_inbound(%{
          "from" => "a@b.test",
          "text" => "see attached",
          "message_id" => "<attach-#{System.unique_integer([:positive])}@b.test>",
          "attachments" => [%{"filename" => "spec.md", "content" => "# spec"}]
        })

      assert message.message.text =~ "see attached"
      assert message.message.text =~ "Attachments:"
      assert message.message.text =~ "spec.md"

      assert [%{filename: "spec.md"}] = message.meta.attachments
    end

    test "leaves the text alone when there are none" do
      {:ok, message} =
        Email.normalize_inbound(%{"from" => "a@b.test", "text" => "nothing attached"})

      assert message.message.text == "nothing attached"
      assert message.meta.attachments == []
    end
  end
end
