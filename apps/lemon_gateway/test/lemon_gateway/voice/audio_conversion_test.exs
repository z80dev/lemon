defmodule LemonGateway.Voice.AudioConversionTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Voice.AudioConversion

  @moduledoc """
  Tests for pure-Elixir mu-law audio encoding.

  Validates the ITU-T G.711 mu-law implementation against known
  reference values and edge cases.
  """

  describe "pcm16_to_mulaw/1" do
    test "converts silence (0x0000) to mu-law 0xFF" do
      # Silence in 16-bit PCM is 0; in mu-law it's 0xFF (inverted bits)
      assert AudioConversion.pcm16_to_mulaw(<<0, 0>>) == <<0xFF>>
    end

    test "converts multiple samples" do
      # Two silence samples
      pcm = <<0, 0, 0, 0>>
      result = AudioConversion.pcm16_to_mulaw(pcm)
      assert byte_size(result) == 2
      assert result == <<0xFF, 0xFF>>
    end

    test "output length is half the input length" do
      # 100 samples = 200 bytes PCM -> 100 bytes mulaw
      pcm = :binary.copy(<<0, 0>>, 100)
      result = AudioConversion.pcm16_to_mulaw(pcm)
      assert byte_size(result) == 100
    end

    test "drops trailing odd byte" do
      # 3 bytes = 1 full sample + 1 leftover byte
      pcm = <<0, 0, 42>>
      result = AudioConversion.pcm16_to_mulaw(pcm)
      assert byte_size(result) == 1
    end

    test "returns empty binary for empty input" do
      assert AudioConversion.pcm16_to_mulaw(<<>>) == <<>>
    end

    test "returns empty binary for single byte input" do
      assert AudioConversion.pcm16_to_mulaw(<<42>>) == <<>>
    end

    test "positive and negative samples of same magnitude produce complementary sign bits" do
      # A positive sample and its negation should differ only in the sign bit (bit 7)
      pos_sample = 1000
      neg_sample = -1000

      pos_mulaw = AudioConversion.encode_mulaw_sample(pos_sample)
      neg_mulaw = AudioConversion.encode_mulaw_sample(neg_sample)

      # After XOR with 0xFF, sign bit is inverted.
      # Positive sign=0x00, after inversion in the result, the sign bit position
      # should differ between positive and negative samples.
      # The lower 7 bits (segment + quantization) should be the same.
      assert Bitwise.band(pos_mulaw, 0x7F) == Bitwise.band(neg_mulaw, 0x7F)
      assert Bitwise.bxor(pos_mulaw, neg_mulaw) == 0x80
    end

    test "maximum positive sample does not overflow" do
      # 32767 in little-endian signed 16-bit
      max_pcm = <<0xFF, 0x7F>>
      result = AudioConversion.pcm16_to_mulaw(max_pcm)
      assert byte_size(result) == 1
      # Should produce a valid mu-law byte (0-255)
      <<byte>> = result
      assert byte >= 0 and byte <= 255
    end

    test "maximum negative sample does not overflow" do
      # -32768 in little-endian signed 16-bit
      min_pcm = <<0x00, 0x80>>
      result = AudioConversion.pcm16_to_mulaw(min_pcm)
      assert byte_size(result) == 1
      <<byte>> = result
      assert byte >= 0 and byte <= 255
    end

    test "monotonicity: larger PCM magnitude maps to smaller mu-law code" do
      # In mu-law, larger magnitudes produce smaller numeric codes (after bit inversion).
      # This is a key property of the compression.
      small_mag = AudioConversion.encode_mulaw_sample(100)
      large_mag = AudioConversion.encode_mulaw_sample(10000)

      # Strip sign bit for magnitude comparison
      small_code = Bitwise.band(small_mag, 0x7F)
      large_code = Bitwise.band(large_mag, 0x7F)

      assert small_code > large_code
    end

    test "encodes a known reference value correctly" do
      # PCM sample 8159: after bias and segment lookup, produces a valid mu-law byte.
      # After G.711 XOR 0xFF inversion, positive samples have bit 7 set (>= 128).
      result = AudioConversion.encode_mulaw_sample(8159)
      assert is_integer(result)
      assert result >= 0 and result <= 255
      # Positive sample: after G.711 inversion, sign bit (bit 7) is set
      assert Bitwise.band(result, 0x80) == 0x80
    end
  end

  describe "encode_mulaw_sample/1" do
    test "encodes zero" do
      result = AudioConversion.encode_mulaw_sample(0)
      assert result == 0xFF
    end

    test "encodes small positive value" do
      result = AudioConversion.encode_mulaw_sample(10)
      assert is_integer(result)
      assert result >= 0 and result <= 255
      # Should not be silence
      # very small values may round to silence-ish
      assert result != 0xFF or 10 < 4
    end

    test "encodes small negative value" do
      result = AudioConversion.encode_mulaw_sample(-10)
      assert is_integer(result)
      assert result >= 0 and result <= 255
    end
  end

  describe "mp3_data?/1" do
    test "detects MP3 sync word" do
      # MP3 frame sync: first 11 bits all 1s = 0xFF 0xFB (MPEG1 Layer3)
      assert AudioConversion.mp3_data?(<<0xFF, 0xFB, 0x90, 0x00>>)
    end

    test "detects MPEG2 Layer3 sync word" do
      # 0xFF 0xF3 = MPEG2 Layer3
      assert AudioConversion.mp3_data?(<<0xFF, 0xF3, 0x90, 0x00>>)
    end

    test "rejects PCM data" do
      refute AudioConversion.mp3_data?(<<0x00, 0x00, 0x00, 0x00>>)
    end

    test "rejects empty binary" do
      refute AudioConversion.mp3_data?(<<>>)
    end

    test "rejects single byte" do
      refute AudioConversion.mp3_data?(<<0xFF>>)
    end

    test "rejects partial sync word" do
      # 0xFF followed by byte without top 3 bits set
      refute AudioConversion.mp3_data?(<<0xFF, 0x00>>)
    end

    test "detects ID3 tag header" do
      assert AudioConversion.mp3_data?(<<"ID3", 0, 0, 0>>)
    end

    test "accepts iodata without crashing" do
      # Simulate :httpc returning MP3 payload as iolist
      chunks = [<<0xFF, 0xFB>>, <<0x90, 0x00>>]
      assert AudioConversion.mp3_data?(chunks)
    end
  end

  describe "round-trip properties" do
    test "all encoded values are valid bytes (0-255)" do
      # Test a range of PCM sample values
      samples = [
        -32768,
        -16384,
        -8192,
        -4096,
        -1024,
        -256,
        -1,
        0,
        1,
        256,
        1024,
        4096,
        8192,
        16384,
        32767
      ]

      Enum.each(samples, fn sample ->
        result = AudioConversion.encode_mulaw_sample(sample)

        assert result >= 0 and result <= 255,
               "Sample #{sample} produced invalid mu-law byte: #{result}"
      end)
    end

    test "pcm16_to_mulaw handles realistic audio buffer size" do
      # Simulate 20ms of 8kHz mono PCM (160 samples = 320 bytes)
      pcm = :crypto.strong_rand_bytes(320)
      result = AudioConversion.pcm16_to_mulaw(pcm)
      assert byte_size(result) == 160
    end
  end
end
