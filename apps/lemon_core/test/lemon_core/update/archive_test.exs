defmodule LemonCore.Update.ArchiveTest do
  use ExUnit.Case, async: true

  alias LemonCore.Update.Archive

  @moduletag :tmp_dir

  test "accepts a regular confined release tree", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.mkdir_p!(Path.join(source, "bin"))
    File.write!(Path.join(source, "bin/lemon"), "safe")
    tarball = Path.join(tmp_dir, "safe.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", source, "."])

    assert :ok = Archive.validate(tarball)
  end

  test "rejects parent traversal before extraction", %{tmp_dir: tmp_dir} do
    tarball = Path.join(tmp_dir, "traversal.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(tarball), [{~c"../escape", "bad"}], [:compressed])

    assert {:error, :archive_path_escape} = Archive.validate(tarball)
  end

  test "rejects absolute member paths before extraction", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "absolute-payload")
    File.write!(source, "bad")
    tarball = Path.join(tmp_dir, "absolute.tar.gz")
    {_, 0} = System.cmd("tar", ["-czPf", tarball, source])

    assert {:error, :archive_path_escape} = Archive.validate(tarball)
  end

  test "rejects symbolic links, hard links, and fifos", %{tmp_dir: tmp_dir} do
    for kind <- [:symlink, :hardlink, :fifo] do
      source = Path.join(tmp_dir, Atom.to_string(kind))
      File.mkdir_p!(source)
      regular = Path.join(source, "regular")
      File.write!(regular, "safe")

      case kind do
        :symlink -> File.ln_s!("regular", Path.join(source, "entry"))
        :hardlink -> File.ln!(regular, Path.join(source, "entry"))
        :fifo -> {_, 0} = System.cmd("mkfifo", [Path.join(source, "entry")])
      end

      tarball = Path.join(tmp_dir, "#{kind}.tar.gz")
      {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", source, "."])
      assert {:error, :archive_unsafe_entry_type} = Archive.validate(tarball)
    end
  end

  test "post-extract validation rejects links and expanded byte overflow", %{tmp_dir: tmp_dir} do
    tree = Path.join(tmp_dir, "tree")
    File.mkdir_p!(tree)
    File.write!(Path.join(tree, "payload"), "12345")

    assert {:error, {:unsafe_staged_entry, :regular}} =
             Archive.validate_tree(tree, max_expanded_bytes: 4)

    File.rm!(Path.join(tree, "payload"))
    File.ln_s!("outside", Path.join(tree, "link"))
    assert {:error, {:unsafe_staged_entry, :symlink}} = Archive.validate_tree(tree)
  end

  test "rejects device archive type flags before extraction", %{tmp_dir: tmp_dir} do
    tarball = Path.join(tmp_dir, "device.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(tarball), [{~c"device", "payload"}], [:compressed])
    make_first_entry_type!(tarball, ?3)

    assert {:error, :archive_unsafe_entry_type} = Archive.validate(tarball)
  end

  defp make_first_entry_type!(tarball, type) do
    raw = tarball |> File.read!() |> :zlib.gunzip()
    <<header::binary-size(512), rest::binary>> = raw

    header = replace_bytes(header, 156, 1, <<type>>)
    header = replace_bytes(header, 148, 8, String.duplicate(" ", 8))
    checksum = header |> :binary.bin_to_list() |> Enum.sum()
    encoded = checksum |> Integer.to_string(8) |> String.pad_leading(6, "0")
    header = replace_bytes(header, 148, 8, encoded <> <<0, 32>>)
    File.write!(tarball, :zlib.gzip(header <> rest))
  end

  defp replace_bytes(binary, offset, length, replacement) do
    prefix = binary_part(binary, 0, offset)
    suffix = binary_part(binary, offset + length, byte_size(binary) - offset - length)
    prefix <> replacement <> suffix
  end
end
