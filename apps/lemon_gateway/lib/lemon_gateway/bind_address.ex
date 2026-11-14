defmodule LemonGateway.BindAddress do
  @moduledoc "Parses gateway listener bind addresses with a loopback default."

  @spec parse(term()) :: :loopback | :any | :inet.ip_address()
  def parse(value) when is_binary(value) do
    case String.trim(value) do
      value when value in ["", "127.0.0.1", "localhost"] -> :loopback
      value when value in ["0.0.0.0", "any"] -> :any
      value ->
        case :inet.parse_address(String.to_charlist(value)) do
          {:ok, ip} -> ip
          {:error, _} -> :loopback
        end
    end
  end

  def parse(_), do: :loopback
end
