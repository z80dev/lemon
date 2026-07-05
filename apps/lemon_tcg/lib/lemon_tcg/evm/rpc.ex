defmodule LemonTcg.Evm.Rpc do
  @moduledoc """
  Minimal Ethereum JSON-RPC client: the calls needed to fill in an
  EIP-1559 transaction (`nonce`, fees, gas, chain id) and broadcast it.

  Configure the endpoint per chain via `opts[:rpc_url]` or the
  `:lemon_tcg, :evm_rpc_urls` app env (`%{polygon: url, base: url}`).
  Public defaults are used otherwise — override them for production.
  """

  @default_rpc %{
    polygon: "https://polygon-rpc.com",
    base: "https://mainnet.base.org",
    ethereum: "https://eth.llamarpc.com"
  }

  @doc "Populate nonce, chain id, gas, and EIP-1559 fees for `from` on `chain`."
  @spec prepare_eip1559(atom(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_eip1559(chain, from, tx, opts \\ []) do
    with {:ok, chain_id} <- chain_id(chain, opts),
         {:ok, nonce} <- transaction_count(chain, from, opts),
         {:ok, priority} <- max_priority_fee(chain, opts),
         {:ok, base_fee} <- base_fee(chain, opts) do
      max_fee = base_fee * 2 + priority

      filled =
        tx
        |> Map.put(:chain_id, chain_id)
        |> Map.put(:nonce, nonce)
        |> Map.put(:max_priority_fee_per_gas, priority)
        |> Map.put(:max_fee_per_gas, max_fee)

      with {:ok, gas} <- estimate_gas(chain, from, filled, opts) do
        {:ok, Map.put(filled, :gas, gas + div(gas, 5))}
      end
    end
  end

  @spec chain_id(atom(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def chain_id(chain, opts \\ []), do: call_hex_int(chain, "eth_chainId", [], opts)

  @spec transaction_count(atom(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def transaction_count(chain, address, opts \\ []),
    do: call_hex_int(chain, "eth_getTransactionCount", [address, "pending"], opts)

  @spec max_priority_fee(atom(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def max_priority_fee(chain, opts \\ []),
    do: call_hex_int(chain, "eth_maxPriorityFeePerGas", [], opts)

  @spec base_fee(atom(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def base_fee(chain, opts \\ []) do
    case request(chain, "eth_getBlockByNumber", ["latest", false], opts) do
      {:ok, %{"baseFeePerGas" => hex}} -> {:ok, hex_to_int(hex)}
      {:ok, _block} -> {:error, :no_base_fee}
      error -> error
    end
  end

  @spec estimate_gas(atom(), String.t(), map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def estimate_gas(chain, from, tx, opts \\ []) do
    params = %{
      "from" => from,
      "to" => hex(tx[:to]),
      "value" => "0x" <> Integer.to_string(Map.get(tx, :value, 0), 16),
      "data" => hex(tx[:data])
    }

    call_hex_int(chain, "eth_estimateGas", [params], opts)
  end

  @spec send_raw_transaction(atom(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def send_raw_transaction(chain, raw_tx_hex, opts \\ []) do
    request(chain, "eth_sendRawTransaction", [raw_tx_hex], opts)
  end

  defp call_hex_int(chain, method, params, opts) do
    case request(chain, method, params, opts) do
      {:ok, hex} when is_binary(hex) -> {:ok, hex_to_int(hex)}
      {:ok, other} -> {:error, {:unexpected_result, method, other}}
      error -> error
    end
  end

  defp request(chain, method, params, opts) do
    body = %{jsonrpc: "2.0", id: 1, method: method, params: params}

    req =
      [url: rpc_url(chain, opts), method: :post, json: body, receive_timeout: 20_000]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    case Req.request(req) do
      {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %Req.Response{status: 200, body: %{"error" => error}}} ->
        {:error, {:rpc_error, error}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp rpc_url(chain, opts) do
    configured =
      Keyword.get(opts, :rpc_url) ||
        get_in(Application.get_env(:lemon_tcg, :evm_rpc_urls, %{}), [chain])

    configured || Map.get(@default_rpc, chain) ||
      raise(ArgumentError, "no RPC url for chain #{inspect(chain)}")
  end

  defp hex_to_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex_to_int(hex) when is_binary(hex), do: String.to_integer(hex, 16)

  defp hex(nil), do: "0x"
  defp hex(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)
end
