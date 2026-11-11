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

  test "rejects declared expanded bytes before extraction", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "bounded-source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "payload"), "12345")
    tarball = Path.join(tmp_dir, "expanded.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", source, "."])

    assert {:error, :archive_expanded_size_limit} =
             Archive.validate(tarball, max_expanded_bytes: 4)
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

  describe "lemon_bot backend archives" do
    test "accepts a confined backend tree with relocatable node_modules links", %{
      tmp_dir: tmp_dir
    } do
      source = bot_source!(tmp_dir, "ok")
      File.mkdir_p!(Path.join(source, "bot/node_modules/@img"))
      File.ln_s!("../sharp", Path.join(source, "bot/node_modules/@img/alias"))
      File.mkdir_p!(Path.join(source, "bot/node_modules/sharp"))
      File.write!(Path.join(source, "bot/node_modules/sharp/index.js"), "x")

      assert :ok = Archive.validate_bot(bot_tarball!(tmp_dir, source, "ok"))
    end

    test "rejects a member outside the bot/ prefix", %{tmp_dir: tmp_dir} do
      source = bot_source!(tmp_dir, "stray")
      File.mkdir_p!(Path.join(source, "bin"))
      File.write!(Path.join(source, "bin/lemon"), "x")

      assert {:error, :archive_path_escape} =
               Archive.validate_bot(bot_tarball!(tmp_dir, source, "stray"))
    end

    test "rejects parent traversal and absolute member paths", %{tmp_dir: tmp_dir} do
      traversal = Path.join(tmp_dir, "bot-traversal.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(traversal),
          [{~c"bot/../../escape", "bad"}],
          [:compressed]
        )

      assert {:error, :archive_path_escape} = Archive.validate_bot(traversal)

      payload = Path.join(tmp_dir, "bot-absolute-payload")
      File.write!(payload, "bad")
      absolute = Path.join(tmp_dir, "bot-absolute.tar.gz")
      {_, 0} = System.cmd("tar", ["-czPf", absolute, payload])

      assert {:error, :archive_path_escape} = Archive.validate_bot(absolute)
    end

    test "rejects a symlink that escapes the bot/ prefix", %{tmp_dir: tmp_dir} do
      source = bot_source!(tmp_dir, "escape")
      File.ln_s!("../../../../etc/passwd", Path.join(source, "bot/escape"))

      assert {:error, :archive_path_escape} =
               Archive.validate_bot(bot_tarball!(tmp_dir, source, "escape"))
    end

    test "rejects an absolute symlink target", %{tmp_dir: tmp_dir} do
      source = bot_source!(tmp_dir, "absolute-link")
      File.ln_s!("/etc/passwd", Path.join(source, "bot/link"))

      assert {:error, :archive_path_escape} =
               Archive.validate_bot(bot_tarball!(tmp_dir, source, "absolute-link"))
    end

    test "rejects a member reached through an earlier symlinked directory", %{tmp_dir: tmp_dir} do
      tarball = Path.join(tmp_dir, "bot-through-link.tar.gz")

      # `tar` cannot be made to author this shape, so the headers are written
      # by hand: bot/web -> bin, then a member written through that link.
      File.write!(
        tarball,
        :zlib.gzip(
          member_header("bot/bin/lemon-bot", 0) <>
            link_header("bot/web", "bin") <>
            member_header("bot/web/payload", 0) <>
            end_blocks()
        )
      )

      assert {:error, :archive_path_escape} = Archive.validate_bot(tarball)
    end

    test "rejects a symlinked backend binary and duplicate members", %{tmp_dir: tmp_dir} do
      linked = Path.join(tmp_dir, "bot-linked-binary.tar.gz")

      File.write!(
        linked,
        :zlib.gzip(
          member_header("bot/bin/real", 0) <>
            link_header("bot/bin/lemon-bot", "real") <>
            end_blocks()
        )
      )

      assert {:error, :archive_unsafe_entry_type} = Archive.validate_bot(linked)

      duplicate = Path.join(tmp_dir, "bot-duplicate.tar.gz")

      File.write!(
        duplicate,
        :zlib.gzip(
          member_header("bot/bin/lemon-bot", 0) <>
            member_header("bot/bin/lemon-bot", 0) <>
            end_blocks()
        )
      )

      assert {:error, {:archive_duplicate_entry, "bot/bin/lemon-bot"}} =
               Archive.validate_bot(duplicate)
    end

    test "rejects unsupported member types and bounded limits", %{tmp_dir: tmp_dir} do
      source = bot_source!(tmp_dir, "fifo")
      {_, 0} = System.cmd("mkfifo", [Path.join(source, "bot/pipe")])

      assert {:error, :archive_unsafe_entry_type} =
               Archive.validate_bot(bot_tarball!(tmp_dir, source, "fifo"))

      bounded = bot_source!(tmp_dir, "bounded")
      File.write!(Path.join(bounded, "bot/payload"), "12345")
      tarball = bot_tarball!(tmp_dir, bounded, "bounded")

      assert {:error, :archive_expanded_size_limit} =
               Archive.validate_bot(tarball, max_expanded_bytes: 4)

      assert {:error, :archive_entry_limit} =
               Archive.validate_bot(tarball, max_archive_entries: 1)
    end

    test "preflight carries the backend tarball beside the runtime and TUI", %{tmp_dir: tmp_dir} do
      runtime = Path.join(tmp_dir, "runtime.tar.gz")
      runtime_src = Path.join(tmp_dir, "runtime-src")
      File.mkdir_p!(Path.join(runtime_src, "bin"))
      File.write!(Path.join(runtime_src, "bin/lemon"), "x")
      {_, 0} = System.cmd("tar", ["-czf", runtime, "-C", runtime_src, "."])

      good = bot_tarball!(tmp_dir, bot_source!(tmp_dir, "preflight-ok"), "preflight-ok")
      assert :ok = Archive.preflight({runtime, nil, good})
      assert :ok = Archive.preflight({runtime, nil})

      bad_source = bot_source!(tmp_dir, "preflight-bad")
      File.ln_s!("/etc/passwd", Path.join(bad_source, "bot/link"))
      bad = bot_tarball!(tmp_dir, bad_source, "preflight-bad")

      assert {:error, :archive_path_escape} = Archive.preflight({runtime, nil, bad})
    end

    test "post-extract backend validation keeps links inside the staged tree", %{
      tmp_dir: tmp_dir
    } do
      tree = Path.join(tmp_dir, "bot-tree")
      File.mkdir_p!(Path.join(tree, "bot/bin"))
      File.write!(Path.join(tree, "bot/bin/lemon-bot"), "x")
      File.ln_s!("bin", Path.join(tree, "bot/alias"))

      assert :ok = Archive.validate_bot_tree(tree)

      File.ln_s!("../../../outside", Path.join(tree, "bot/escape"))
      assert {:error, :archive_path_escape} = Archive.validate_bot_tree(tree)
      File.rm!(Path.join(tree, "bot/escape"))

      File.rm!(Path.join(tree, "bot/bin/lemon-bot"))
      File.ln_s!("other", Path.join(tree, "bot/bin/lemon-bot"))
      assert {:error, :archive_unsafe_entry_type} = Archive.validate_bot_tree(tree)
    end

    test "post-extract backend validation refuses devices and oversized trees", %{
      tmp_dir: tmp_dir
    } do
      tree = Path.join(tmp_dir, "bot-tree-bounds")
      File.mkdir_p!(Path.join(tree, "bot"))
      File.write!(Path.join(tree, "bot/payload"), "12345")

      assert {:error, :archive_expanded_size_limit} =
               Archive.validate_bot_tree(tree, max_expanded_bytes: 4)

      {_, 0} = System.cmd("mkfifo", [Path.join(tree, "bot/pipe")])
      assert {:error, {:unsafe_staged_entry, :other}} = Archive.validate_bot_tree(tree)
    end
  end

  defp bot_source!(tmp_dir, name) do
    source = Path.join([tmp_dir, "bot-sources", name])
    File.mkdir_p!(Path.join(source, "bot/bin"))
    File.write!(Path.join(source, "bot/bin/lemon-bot"), "#!/bin/sh\n")
    source
  end

  # COPYFILE_DISABLE keeps macOS tar from adding `._*` AppleDouble members,
  # which a release tarball never carries.
  defp bot_tarball!(tmp_dir, source, name) do
    tarball = Path.join(tmp_dir, "bot-#{name}.tar.gz")

    {_, 0} =
      System.cmd("tar", ["-czf", tarball, "-C", source, "."], env: [{"COPYFILE_DISABLE", "1"}])

    tarball
  end

  defp member_header(name, size), do: tar_header(name, "", ?0, size)
  defp link_header(name, target), do: tar_header(name, target, ?2, 0)

  defp tar_header(name, linkname, type, size) do
    header =
      pad(name, 100) <>
        pad("000755 ", 8) <>
        pad("000000 ", 8) <>
        pad("000000 ", 8) <>
        pad(String.pad_leading(Integer.to_string(size, 8), 11, "0") <> " ", 12) <>
        pad("00000000000 ", 12) <>
        String.duplicate(" ", 8) <>
        <<type>> <>
        pad(linkname, 100) <>
        pad("ustar", 6) <>
        pad("00", 2) <>
        pad("", 32) <>
        pad("", 32) <>
        pad("", 8) <> pad("", 8) <> pad("", 155) <> pad("", 12)

    checksum = header |> :binary.bin_to_list() |> Enum.sum()
    encoded = checksum |> Integer.to_string(8) |> String.pad_leading(6, "0")

    replace_bytes(header, 148, 8, encoded <> <<0, 32>>)
  end

  defp pad(value, length), do: value <> String.duplicate(<<0>>, length - byte_size(value))

  defp end_blocks, do: String.duplicate(<<0>>, 1024)

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
