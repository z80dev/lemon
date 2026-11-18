defmodule LemonChannels.Adapters.Email.MessageId do
  @moduledoc """
  RFC 2822 message identifiers: parsing, listing and rendering.

  Message ids arrive in every shape a mail provider can invent — bracketed
  (`<abc@host>`), bare, whitespace- or comma-separated in a `References`
  header, already split into a list, or as a `{name, value}` header tuple. The
  adapter, the thread store and outbound delivery all have to agree on what an
  id *is*, so the parsing lives here rather than three times over.

  Lists are capped at 25 entries, keeping the **newest** ones. `References`
  grows without bound on a long thread and a mail server will reject an
  oversized header, so the tail — the nearest ancestors, which is what a client
  threads on — is the part worth keeping.
  """

  @max_references 25

  @doc """
  The bare id, brackets and surrounding whitespace stripped, or `nil` if there
  is none or it is not a valid id.

  A valid id is `left@right` in printable US-ASCII with no whitespace, angle
  brackets or second `@`, at most 998 bytes. Anything else — notably a value
  carrying CR/LF — is treated as absent, because ids are written back into
  `In-Reply-To` and `References` headers of outbound mail and a line break
  there would let the original sender inject headers of their own.
  """
  @spec normalize(term()) :: binary() | nil
  def normalize(nil), do: nil

  def normalize(value) when is_list(value), do: Enum.find_value(value, &normalize/1)

  def normalize({_name, value}), do: normalize(value)

  def normalize(value) when is_binary(value) do
    id =
      value
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")

    if valid?(id), do: id
  end

  def normalize(_value), do: nil

  @doc "Whether `id` is a bare message id safe to render into a header."
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id) and byte_size(id) <= 998,
    do: Regex.match?(~r/\A[\x21-\x3B\x3D\x3F\x41-\x7E]+@[\x21-\x3B\x3D\x3F\x41-\x7E]+\z/, id)

  def valid?(_id), do: false

  @doc """
  Every id in a `References`-style value, oldest first.

  Prefers bracketed ids; falls back to splitting on whitespace and commas for
  providers that hand over an unbracketed list.
  """
  @spec list(term()) :: [binary()]
  def list(value) when is_list(value) do
    value
    |> Enum.flat_map(&list/1)
    |> Enum.reject(&is_nil/1)
  end

  def list(value) when is_binary(value) do
    bracketed =
      ~r/<([^>]+)>/
      |> Regex.scan(value, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&normalize/1)
      |> Enum.reject(&is_nil/1)

    case bracketed do
      [] ->
        value
        |> String.split(~r/[\s,]+/, trim: true)
        |> Enum.map(&normalize/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-@max_references)

      ids ->
        ids |> Enum.uniq() |> Enum.take(-@max_references)
    end
  end

  def list(value) do
    case normalize(value) do
      nil -> []
      id -> [id]
    end
  end

  @doc "Flattens several reference sets into one deduplicated, capped chain."
  @spec merge([term()]) :: [binary()]
  def merge(reference_sets) when is_list(reference_sets) do
    reference_sets
    |> Enum.flat_map(&list/1)
    |> Enum.uniq()
    |> Enum.take(-@max_references)
  end

  @doc "Renders an id for a header, or `nil` so the header can be omitted."
  @spec format(term()) :: binary() | nil
  def format(nil), do: nil
  def format(value) when is_binary(value), do: if(valid?(value), do: "<" <> value <> ">")
  def format(_value), do: nil

  @doc "Renders a list of ids for a `References` header, or `nil` when empty."
  @spec format_list(term()) :: [binary()] | nil
  def format_list(references) when is_list(references) do
    references
    |> Enum.map(&format/1)
    |> Enum.reject(&is_nil/1)
  end

  def format_list(_references), do: nil

  @doc "Generates a new message id for a message sent from `address`."
  @spec generate(binary() | nil) :: binary()
  def generate(address) when is_binary(address) do
    domain =
      address
      |> String.split("@")
      |> List.last()
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end
      |> case do
        "" -> "localhost"
        value -> value
      end

    "lemon-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}@#{domain}"
  end

  def generate(_address), do: generate("unknown@localhost")

  @doc "The cap applied to reference chains."
  @spec max_references() :: pos_integer()
  def max_references, do: @max_references
end
