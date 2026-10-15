defmodule LemonChannels.Adapters.Discord.FileErrorCopyTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Discord.FileOperations

  test "an unreadable file returns recovery steps without exception terms" do
    path =
      Path.join(System.tmp_dir!(), "missing-discord-file-#{System.unique_integer([:positive])}")

    assert {:error, text} = FileOperations.send_file_to_channel(123, path, "file")
    assert text =~ "Check"
    assert text =~ "file"
    refute text =~ "{"
    refute text =~ ":enoent"
    refute text =~ path
  end

  test "an invalid attachment URL has a recovery hint" do
    assert {:error, text} = FileOperations.download_attachment_bytes("http://[")
    assert text =~ "attachment is still available"
    refute text =~ "{"
    refute text =~ "%{"
  end
end
