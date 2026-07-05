defmodule LemonTcg.Evm.Eip712 do
  @moduledoc """
  EIP-712 signing digest: `keccak256(0x1901 || domainSeparator ||
  hashStruct(message))`.

  Callers supply the already-computed 32-byte domain separator and
  struct hash (Seaport, for example, defines its own type hashes). This
  module only assembles and hashes them, so we never guess a type layout.
  """

  alias LemonTcg.Evm.Keccak

  @doc "EIP-712 signing digest from a domain separator and a struct hash."
  @spec digest(binary(), binary()) :: binary()
  def digest(<<domain_separator::binary-size(32)>>, <<struct_hash::binary-size(32)>>) do
    Keccak.hash256(<<0x19, 0x01>> <> domain_separator <> struct_hash)
  end
end
