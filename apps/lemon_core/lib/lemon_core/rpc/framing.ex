defmodule LemonCore.Rpc.Framing do
  @moduledoc "Wire framing independent of peer lifecycle and protocol policy."
  @callback encode(term()) :: {:ok, binary()} | {:error, term()}
  @callback decode(binary()) :: {:ok, [term()], binary()} | {:error, term()}
end
