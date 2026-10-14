defmodule LemonCore.Secrets.Receipts do
  @moduledoc false
  import Kernel, except: [binding: 1]

  import Kernel, except: [binding: 1]

  alias LemonCore.MapHelpers
  alias LemonCore.Secrets

  @capacity 128
  @fields [:ciphertext, :nonce, :salt, :version, :staged, :expires_at]

  def operation_id(value) when is_binary(value) and byte_size(value) in 1..128 do
    if Regex.match?(~r/\A[A-Za-z0-9_:-]+\z/, value),
      do: :ok,
      else: {:error, :invalid_operation_id}
  end

  def operation_id(_), do: {:error, :invalid_operation_id}

  def node_id(value) when is_binary(value) and byte_size(value) in 1..256 do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid_node_id}
  end

  def node_id(_), do: {:error, :invalid_node_id}

  def entries(entry) do
    case Map.fetch(entry, :receipts) do
      {:ok, receipts} -> receipts
      :error -> Map.get(entry, "receipts", [])
    end
  end

  def receipt_only?(entry) when is_map(entry) do
    receipts = entries(entry)
    Map.keys(entry) in [[:receipts], ["receipts"]] and is_list(receipts) and receipts != [] and
      length(receipts) <= @capacity and Enum.all?(receipts, &valid?/1)
  end

  def receipt_only?(_), do: false

  # Complete owner scan: a failed/corrupt read is never evidence of absence.
  def find(rows, owner, node_id, operation_id) do
    Enum.reduce_while(rows, {:ok, nil}, fn
      {{^owner, name}, entry}, {:ok, found} when is_binary(name) and is_map(entry) ->
        receipts = entries(entry)

        if is_list(receipts) and length(receipts) <= @capacity and Enum.all?(receipts, &valid?/1) do
          matches = Enum.filter(receipts, fn receipt ->
            field(receipt, :node_id) == node_id and field(receipt, :operation_id) == operation_id
          end)

          case {found, matches} do
            {_, []} -> {:cont, {:ok, found}}
            {nil, [receipt]} -> {:cont, {:ok, {name, entry, receipt}}}
            _ -> {:halt, {:error, :secret_store_failed}}
          end
        else
          {:halt, {:error, :secret_store_failed}}
        end

      {{^owner, _}, _}, _ ->
        {:halt, {:error, :secret_store_failed}}

      _, acc ->
        {:cont, acc}
    end)
  end

  def append(entry, receipt) do
    receipts = entries(entry)

    if length(receipts) < @capacity,
      do: {:ok, put(entry, :receipts, [receipt | receipts])},
      else: {:error, :secret_receipt_capacity}
  end

  def intent(key, owner, node_id, name, value, provider, expires_at) do
    metadata = :erlang.term_to_binary({"lemon-secret-intent-v1", owner, node_id, name, provider, expires_at})
    :crypto.mac(:hmac, :sha256, key, [metadata, <<byte_size(value)::unsigned-big-64>>, value]) |> Base.encode64()
  end

  # Only the encrypted revision and active/expiry state, never usage counters.
  def binding(entry) do
    @fields
    |> Enum.map(fn
      :staged -> canonical_cipher(field(entry, :staged))
      key -> field(entry, key)
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  def current?(entry, receipt) do
    Secrets.value_entry?(entry) and not Secrets.expired_entry?(entry) and
      field(receipt, :binding) == binding(entry)
  end

  def same_intent?(receipt, intent) do
    stored = field(receipt, :intent)
    byte_size(stored) == byte_size(intent) and :crypto.hash_equals(stored, intent)
  end

  def proof(node_id, operation_id, nil) do
    %{node_id: node_id, operation_id: operation_id, status: "not_found", name: nil,
      current_binding_matches: false}
  end

  def proof(node_id, operation_id, {name, entry, receipt}) do
    %{node_id: node_id, operation_id: operation_id, status: "applied", name: name,
      current_binding_matches: current?(entry, receipt)}
  end

  def field(entry, key), do: MapHelpers.get_key(entry, key)

  defp valid?(entry) when is_map(entry) do
    operation_id(field(entry, :operation_id)) == :ok and node_id(field(entry, :node_id)) == :ok and
      valid_fingerprint?(field(entry, :intent)) and valid_fingerprint?(field(entry, :binding))
  end

  defp valid?(_), do: false

  defp valid_fingerprint?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> byte_size(bytes) == 32
      :error -> false
    end
  end

  defp valid_fingerprint?(_), do: false

  defp canonical_cipher(entry) when is_map(entry),
    do: Enum.map([:ciphertext, :nonce, :salt, :version], &field(entry, &1))

  defp canonical_cipher(_), do: nil

  defp put(entry, key, value), do: entry |> Map.put(key, value) |> Map.delete(Atom.to_string(key))
end
