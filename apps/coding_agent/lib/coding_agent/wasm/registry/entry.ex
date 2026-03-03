defmodule CodingAgent.Wasm.Registry.Entry do
  @moduledoc """
  Represents a WASM module entry in the registry.

  Contains metadata about the module including:
  - Source information (type, URI, version)
  - Caching information (path, checksum, size)
  - Access tracking (count, timestamps)
  - Expiration information

  ## Fields

    * `:name` - The unique name of the module
    * `:source` - Source information map with :type, :uri, :checksum, :version, :metadata
    * `:size_bytes` - Size of the WASM binary in bytes
    * `:cache_path` - Local filesystem path to cached binary
    * `:checksum` - SHA256 checksum of the binary
    * `:registered_at` - Timestamp when module was registered (milliseconds)
    * `:expires_at` - Expiration timestamp (nil for no expiration)
    * `:version` - Semantic version string
    * `:access_count` - Number of times module was accessed
    * `:last_accessed_at` - Last access timestamp

  """

  @type source :: %{
          type: CodingAgent.Wasm.Registry.source_type(),
          uri: String.t(),
          checksum: String.t() | nil,
          version: String.t() | nil,
          metadata: map()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          source: source(),
          size_bytes: non_neg_integer(),
          cache_path: String.t() | nil,
          checksum: String.t() | nil,
          registered_at: integer(),
          expires_at: integer() | nil,
          version: String.t() | nil,
          access_count: non_neg_integer(),
          last_accessed_at: integer()
        }

  defstruct [
    :name,
    :source,
    :size_bytes,
    :cache_path,
    :checksum,
    :registered_at,
    :expires_at,
    :version,
    :access_count,
    :last_accessed_at
  ]

  @doc """
  Returns true if the entry has expired.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    System.system_time(:millisecond) > expires_at
  end

  @doc """
  Returns the age of the entry in milliseconds.
  """
  @spec age_ms(t()) :: non_neg_integer()
  def age_ms(%__MODULE__{registered_at: registered_at}) do
    System.system_time(:millisecond) - registered_at
  end

  @doc """
  Returns true if the entry is still valid (not expired and has cache file).
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = entry) do
    not expired?(entry) and cache_exists?(entry)
  end

  @doc """
  Returns true if the cache file exists.
  """
  @spec cache_exists?(t()) :: boolean()
  def cache_exists?(%__MODULE__{cache_path: nil}), do: false

  def cache_exists?(%__MODULE__{cache_path: path}) do
    File.exists?(path)
  end

  @doc """
  Converts the entry to a serializable map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      name: entry.name,
      source: entry.source,
      size_bytes: entry.size_bytes,
      checksum: entry.checksum,
      registered_at: entry.registered_at,
      expires_at: entry.expires_at,
      version: entry.version,
      access_count: entry.access_count,
      last_accessed_at: entry.last_accessed_at
    }
  end

  @doc """
  Creates an entry from a serialized map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"] || map[:name],
      source: map["source"] || map[:source],
      size_bytes: map["size_bytes"] || map[:size_bytes] || 0,
      cache_path: map["cache_path"] || map[:cache_path],
      checksum: map["checksum"] || map[:checksum],
      registered_at: map["registered_at"] || map[:registered_at] || 0,
      expires_at: map["expires_at"] || map[:expires_at],
      version: map["version"] || map[:version],
      access_count: map["access_count"] || map[:access_count] || 0,
      last_accessed_at: map["last_accessed_at"] || map[:last_accessed_at] || 0
    }
  end
end
