defmodule CodingAgent.Tools.ArchiveBombTest do
  # Measures VM-wide memory while inflating; must not overlap other suites.
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{ReadArchive, WriteArchive}
  alias LemonAgent.AbortSignal

  @moduletag :tmp_dir
  @mib 1024 * 1024

  # Raw deflate of `size` zero bytes plus its CRC, built without allocating `size`.
  defp zero_deflate(size) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :best_compression, :deflated, -15, 9, :default)
    chunk = :binary.copy(<<0>>, @mib)

    {data, crc} =
      Enum.reduce(1..div(size, @mib), {[], 0}, fn _, {acc, crc} ->
        {[acc | :zlib.deflate(z, chunk)], :erlang.crc32(crc, chunk)}
      end)

    data = IO.iodata_to_binary([data | :zlib.deflate(z, <<>>, :finish)])
    :zlib.close(z)
    {data, crc}
  end

  # Minimal single-or-multi member ZIP writer: [{name, method, data, crc, usize}].
  defp zip(members) do
    {locals, centrals, _offset} =
      Enum.reduce(members, {[], [], 0}, fn {name, method, data, crc, usize}, {l, c, offset} ->
        n = byte_size(name)

        local =
          <<0x04034B50::little-32, 20::little-16, 0::16, method::little-16, 0::32, crc::little-32,
            byte_size(data)::little-32, usize::little-32, n::little-16, 0::16, name::binary,
            data::binary>>

        central =
          <<0x02014B50::little-32, 20::little-16, 20::little-16, 0::16, method::little-16, 0::32,
            crc::little-32, byte_size(data)::little-32, usize::little-32, n::little-16, 0::16,
            0::16, 0::16, 0::16, 0::32, offset::little-32, name::binary>>

        {[l, local], [c, central], offset + byte_size(local)}
      end)

    locals = IO.iodata_to_binary(locals)
    centrals = IO.iodata_to_binary(centrals)
    count = length(members)

    locals <>
      centrals <>
      <<0x06054B50::little-32, 0::16, 0::16, count::little-16, count::little-16,
        byte_size(centrals)::little-32, byte_size(locals)::little-32, 0::16>>
  end

  defp peak_memory_during(fun) do
    :erlang.garbage_collect()
    base = :erlang.memory(:total)
    parent = self()

    sampler =
      spawn_link(fn ->
        sample = fn sample, peak ->
          receive do
            :stop -> send(parent, {:peak, peak})
          after
            1 -> sample.(sample, max(peak, :erlang.memory(:total)))
          end
        end

        sample.(sample, base)
      end)

    result = fun.()
    send(sampler, :stop)
    assert_receive {:peak, peak}, 5_000
    {result, peak - base}
  end

  test "a high-ratio zip bomb member is rejected with bounded memory", %{tmp_dir: dir} do
    {data, crc} = zero_deflate(256 * @mib)
    path = Path.join(dir, "bomb.zip")
    File.write!(path, zip([{"bomb.txt", 8, data, crc, 256 * @mib}]))

    {result, growth} =
      peak_memory_during(fn ->
        ReadArchive.read(path, "bomb.txt", %{}, AbortSignal.new(),
          format_max_member_bytes: 4 * @mib
        )
      end)

    assert {:error, message} = result
    assert message =~ "exceeding the 4194304-byte"
    assert growth < 64 * @mib
  end

  test "a member whose declared size lies is rejected during inflate", %{tmp_dir: dir} do
    {data, crc} = zero_deflate(256 * @mib)
    path = Path.join(dir, "liar.zip")
    File.write!(path, zip([{"liar.txt", 8, data, crc, 10}]))

    {result, growth} =
      peak_memory_during(fn ->
        ReadArchive.read(path, "liar.txt", %{}, AbortSignal.new(), [])
      end)

    assert {:error, message} = result
    assert message =~ "exceeds its declared size"
    assert growth < 64 * @mib
  end

  test "in-place ZIP writes bound decoding of unrelated members", %{tmp_dir: dir} do
    {data, crc} = zero_deflate(256 * @mib)
    path = Path.join(dir, "write.zip")
    original = zip([{"bomb.bin", 8, data, crc, 256 * @mib}])
    File.write!(path, original)

    {result, growth} =
      peak_memory_during(fn ->
        WriteArchive.write({path, "new.txt"}, "hi", AbortSignal.new(), dir,
          format_max_decoded_bytes: 8 * @mib
        )
      end)

    assert {:error, message} = result
    assert message =~ ":format_max_decoded_bytes"
    assert growth < 64 * @mib
    assert File.read!(path) == original
  end

  test "in-place tar.gz writes bound the gunzipped archive", %{tmp_dir: dir} do
    path = Path.join(dir, "write.tgz")
    raw = :binary.copy(<<0>>, 16 * @mib)
    File.write!(path, :zlib.gzip(raw))
    original = File.read!(path)

    assert {:error, message} =
             WriteArchive.write({path, "new.txt"}, "hi", AbortSignal.new(), dir,
               format_max_decoded_bytes: @mib
             )

    assert message =~ ":format_max_decoded_bytes"
    assert File.read!(path) == original
  end

  test "tar.gz listing is bounded by the decoded-archive cap", %{tmp_dir: dir} do
    path = Path.join(dir, "big.tgz")
    File.write!(path, :zlib.gzip(:binary.copy(<<0>>, 16 * @mib)))

    assert {:error, message} =
             ReadArchive.read(path, "", %{}, AbortSignal.new(), format_max_decoded_bytes: @mib)

    assert message =~ ":format_max_decoded_bytes"
  end

  test "ordinary zip members still round-trip through read and write", %{tmp_dir: dir} do
    path = Path.join(dir, "ok.zip")
    {:ok, _} = :zip.create(String.to_charlist(path), [{~c"a.txt", "alpha"}, {~c"b.txt", "beta"}])

    assert {:ok, result} = ReadArchive.read(path, "a.txt", %{}, AbortSignal.new(), [])
    assert hd(result.content).text =~ "alpha"

    assert %LemonAgent.Types.AgentToolResult{} =
             WriteArchive.write({path, "c.txt"}, "gamma", AbortSignal.new(), dir, [])

    {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
    assert Enum.sort(files) == [{~c"a.txt", "alpha"}, {~c"b.txt", "beta"}, {~c"c.txt", "gamma"}]
  end
end
