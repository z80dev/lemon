defmodule LemonGateway.Voice.AudioConversion do
  @moduledoc """
  Pure-Elixir audio format conversion for Twilio voice calls.

  Twilio expects 8-bit mu-law (G.711) at 8000 Hz, mono channel.
  ElevenLabs returns MP3-encoded audio by default.

  This module provides:
  - 16-bit signed PCM to 8-bit mu-law encoding
  - MP3 frame detection (to identify MP3 input that requires external decoding)

  ## Mu-law encoding

  Mu-law compresses 16-bit linear PCM samples into 8-bit values using the
  ITU-T G.711 standard. The algorithm applies logarithmic compression with
  mu = 255, preserving dynamic range while halving bandwidth.

  The implementation uses only Elixir binary pattern matching and integer
  arithmetic — no external C libraries or NIFs are required.
  """

  @mu 255
  @bias 0x84
  @clip 0x7F7B

  # Pre-computed segment lookup: maps the top 4 bits of biased magnitude
  # to the segment number (0-7).
  @seg_table {0, 0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3}

  @doc """
  Converts raw 16-bit signed little-endian PCM data to 8-bit mu-law.

  Each pair of input bytes (one 16-bit sample) produces one output byte.
  If the input length is odd, the trailing byte is dropped.

  ## Example

      iex> pcm = <<0x00, 0x00>>  # silence
      iex> LemonGateway.Voice.AudioConversion.pcm16_to_mulaw(pcm)
      <<0xFF>>

  """
  @spec pcm16_to_mulaw(binary()) :: binary()
  def pcm16_to_mulaw(pcm_data) when is_binary(pcm_data) do
    do_pcm16_to_mulaw(pcm_data, [])
  end

  defp do_pcm16_to_mulaw(<<sample::little-signed-16, rest::binary>>, acc) do
    encoded = encode_mulaw_sample(sample)
    do_pcm16_to_mulaw(rest, [encoded | acc])
  end

  defp do_pcm16_to_mulaw(<<_::binary>>, acc) do
    # Remaining 0 or 1 bytes — discard partial sample
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc """
  Encode a single 16-bit signed PCM sample to an 8-bit mu-law byte.

  Implements the ITU-T G.711 mu-law compression algorithm:
  1. Determine sign bit
  2. Take absolute value, apply bias
  3. Clip to prevent overflow
  4. Find segment via top bits
  5. Pack sign + segment + quantization step into one byte
  6. Invert all bits (per G.711 convention)
  """
  @spec encode_mulaw_sample(integer()) :: byte()
  def encode_mulaw_sample(sample) when is_integer(sample) do
    # Determine sign
    {sign, sample} =
      if sample < 0 do
        {0x80, -sample}
      else
        {0x00, sample}
      end

    # Add bias and clip
    sample = min(sample + @bias, @clip)

    # Determine segment number from leading bits
    seg = segment(Bitwise.bsr(sample, 7) |> Bitwise.band(0xF))

    # Quantization step within segment
    low_nibble = Bitwise.bsr(sample, seg + 3) |> Bitwise.band(0x0F)

    # Pack: sign (bit 7) | segment (bits 6-4) | quantization (bits 3-0), then invert
    mulaw_byte = Bitwise.bor(sign, Bitwise.bor(Bitwise.bsl(seg, 4), low_nibble))

    # G.711 convention: invert all bits
    Bitwise.bxor(mulaw_byte, 0xFF)
  end

  @doc """
  Returns `true` if the binary appears to start with an MP3 sync word.

  When ElevenLabs returns MP3-encoded audio, callers should decode to PCM
  first before calling `pcm16_to_mulaw/1`. This function provides a quick
  header check.
  """
  @spec mp3_data?(binary()) :: boolean()
  def mp3_data?(<<0xFF, second, _rest::binary>>) do
    # MP3 frame sync: first 11 bits are all 1s
    Bitwise.band(second, 0xE0) == 0xE0
  end

  def mp3_data?(_), do: false

  # Segment lookup using the pre-computed table
  defp segment(val) when val >= 0 and val <= 15 do
    elem(@seg_table, val)
  end

  defp segment(_), do: 0
end
