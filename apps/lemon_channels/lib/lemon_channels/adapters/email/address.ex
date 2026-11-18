defmodule LemonChannels.Adapters.Email.Address do
  @moduledoc """
  The one mailbox-address parser for the email adapter, inbound and outbound.

  A sender's address is an identity: it is checked against the allowlist, it
  owns thread state, it is the session's peer, and it is the SMTP recipient of
  the reply. All of those must be the *same* mailbox, so every path parses with
  this module and nothing extracts a "best-looking" substring. An address this
  module cannot represent exactly is refused (`nil`), never approximated.

  `parse/1` accepts a bare mailbox (`a@b.example`) or a single name-addr
  (`Name <a@b.example>`). Quoted display names and comments are removed first,
  so an address written into the display name is never taken for the mailbox,
  and a value carrying more than one angle address names no single mailbox.
  The result is trimmed, lowercased and must satisfy `valid?/1`.

  `valid?/1` is anchored over the whole string: an RFC 5322 dot-atom local
  part (letters, digits and ``!#$%&'*+/=?^_`{|}~-``, dot-separated, at most 64
  bytes) and a domain of at least two LDH labels, at most 254 bytes overall.
  Quoted local parts, address literals and non-ASCII (SMTPUTF8) mailboxes are
  unsupported and therefore refused.
  """

  @max_bytes 254
  @max_local_bytes 64

  @atom "[a-z0-9!#$%&'*+/=?^_`{|}~-]+"
  @label "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
  @mailbox_source "\\A(#{@atom}(?:\\.#{@atom})*)@(#{@label}(?:\\.#{@label})+)\\z"

  @doc "The lowercased mailbox in `value`, or `nil` when it names none exactly."
  @spec parse(term()) :: binary() | nil
  def parse({_name, value}), do: parse(value)

  # Bounded before any regex runs: a header value is never this long, and an
  # oversized input must not cost a scan.
  def parse(value) when is_binary(value) and byte_size(value) > 1_024, do: nil

  def parse(value) when is_binary(value) do
    unquoted =
      value
      |> String.replace(~r/"(?:[^"\\]|\\.)*"/s, " ")
      |> String.replace(~r/\([^()]*\)/, " ")

    candidate =
      case Regex.scan(~r/<([^<>]*)>/, unquoted) do
        [[_, addr]] -> addr
        [] -> if String.contains?(unquoted, ["<", ">"]), do: nil, else: unquoted
        _ -> nil
      end

    with addr when is_binary(addr) <- candidate,
         addr = addr |> String.trim() |> String.downcase(),
         true <- valid?(addr) do
      addr
    else
      _ -> nil
    end
  end

  def parse(_value), do: nil

  @doc "Whether `addr` is, in its entirety, a supported lowercase mailbox."
  @spec valid?(term()) :: boolean()
  def valid?(addr) when is_binary(addr) and byte_size(addr) <= @max_bytes do
    case Regex.run(Regex.compile!(@mailbox_source), addr) do
      [_, local, _domain] -> byte_size(local) <= @max_local_bytes
      _ -> false
    end
  end

  def valid?(_addr), do: false
end
