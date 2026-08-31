defmodule LemonCore.JSONPayload do
  @moduledoc """
  Validates bounded JSON protocol payloads before they cross process or network
  boundaries.

  The byte limit matches the control-plane `maxPayload` default. Depth and item
  limits prevent compact, deeply nested or very wide terms from consuming
  unbounded traversal/encoding work even when their encoded byte size is small.
  """

  @default_max_bytes 1_048_576
  @default_max_depth 32
  @default_max_items 10_000

  @type stats :: %{
          bytes: non_neg_integer(),
          depth: non_neg_integer(),
          item_count: non_neg_integer()
        }

  @type limit_error ::
          {:max_bytes, pos_integer()}
          | {:max_depth, pos_integer()}
          | {:max_items, pos_integer()}
          | {:not_json_safe, term()}

  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @spec default_max_depth() :: pos_integer()
  def default_max_depth, do: @default_max_depth

  @spec default_max_items() :: pos_integer()
  def default_max_items, do: @default_max_items

  @doc "Returns validated JSON statistics without retaining the encoded copy."
  @spec validate(term(), keyword()) :: {:ok, stats()} | {:error, limit_error()}
  def validate(value, opts \\ []) do
    limits = limits(opts)

    try do
      with {:ok, walked} <- walk(value, 0, %{depth: 0, item_count: 0}, limits),
           {:ok, encoded} <- encode(value),
           :ok <- enforce_bytes(byte_size(encoded), limits.max_bytes) do
        {:ok, Map.put(walked, :bytes, byte_size(encoded))}
      end
    rescue
      error -> {:error, {:not_json_safe, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:not_json_safe, {kind, reason}}}
    end
  end

  @doc "Validates and returns a JSON-decoded value with string object keys."
  @spec round_trip(term(), keyword()) :: {:ok, term()} | {:error, limit_error()}
  def round_trip(value, opts \\ []) do
    with {:ok, _stats} <- validate(value, opts),
         {:ok, encoded} <- encode(value),
         {:ok, decoded} <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:not_json_safe, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Builds a content-free summary for a payload already accepted at the boundary."
  @spec summary(term(), keyword()) :: map()
  def summary(value, opts \\ []) do
    case validate(value, opts) do
      {:ok, stats} ->
        %{
          present: not is_nil(value),
          kind: kind(value),
          bytes: stats.bytes,
          depth: stats.depth,
          item_count: stats.item_count
        }

      {:error, reason} ->
        %{
          present: not is_nil(value),
          kind: kind(value),
          invalid: true,
          reason: error_kind(reason)
        }
    end
  end

  defp limits(opts) do
    %{
      max_bytes: positive_limit(opts[:max_bytes], @default_max_bytes),
      max_depth: positive_limit(opts[:max_depth], @default_max_depth),
      max_items: positive_limit(opts[:max_items], @default_max_items)
    }
  end

  defp positive_limit(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, fallback), do: fallback

  defp walk(_value, depth, _stats, %{max_depth: max_depth}) when depth > max_depth,
    do: {:error, {:max_depth, max_depth}}

  defp walk(value, depth, stats, limits)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) or
              is_atom(value) do
    bump(stats, depth, limits)
  end

  defp walk(value, depth, stats, limits) when is_list(value) do
    with {:ok, stats} <- bump(stats, depth, limits) do
      Enum.reduce_while(value, {:ok, stats}, fn item, {:ok, acc} ->
        case walk(item, depth + 1, acc, limits) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp walk(%_{} = value, _depth, _stats, _limits),
    do: {:error, {:not_json_safe, {:struct, value.__struct__}}}

  defp walk(value, depth, stats, limits) when is_map(value) do
    with {:ok, stats} <- bump(stats, depth, limits) do
      Enum.reduce_while(value, {:ok, stats}, fn {key, item}, {:ok, acc} ->
        if is_binary(key) or is_atom(key) do
          case walk(item, depth + 1, acc, limits) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _reason} = error -> {:halt, error}
          end
        else
          {:halt, {:error, {:not_json_safe, {:invalid_object_key, key_kind(key)}}}}
        end
      end)
    end
  end

  defp walk(value, _depth, _stats, _limits),
    do: {:error, {:not_json_safe, {:unsupported_type, kind(value)}}}

  defp bump(stats, depth, %{max_items: max_items}) do
    item_count = stats.item_count + 1

    if item_count > max_items do
      {:error, {:max_items, max_items}}
    else
      {:ok, %{stats | item_count: item_count, depth: max(stats.depth, depth)}}
    end
  end

  defp encode(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:not_json_safe, reason}}
    end
  end

  defp enforce_bytes(bytes, max_bytes) when bytes <= max_bytes, do: :ok
  defp enforce_bytes(_bytes, max_bytes), do: {:error, {:max_bytes, max_bytes}}

  defp error_kind({kind, _detail}) when kind in [:max_bytes, :max_depth, :max_items], do: kind
  defp error_kind({:not_json_safe, _detail}), do: :not_json_safe
  defp error_kind(_reason), do: :invalid

  defp kind(value) when is_map(value), do: :object
  defp kind(value) when is_list(value), do: :array
  defp kind(value) when is_binary(value), do: :string
  defp kind(value) when is_boolean(value), do: :boolean
  defp kind(value) when is_number(value), do: :number
  defp kind(nil), do: :null
  defp kind(value) when is_atom(value), do: :atom
  defp kind(_value), do: :other

  defp key_kind(key) when is_integer(key), do: :integer
  defp key_kind(key) when is_tuple(key), do: :tuple
  defp key_kind(_key), do: :other
end
