defmodule LemonChannels.Capabilities.Capability do
  @moduledoc """
  Represents a single channel capability.

  Capabilities can be simple boolean features or complex configurations
  with constraints and supported sub-features.
  """

  @type type ::
          :attachments
          | :rich_blocks
          | :streaming
          | :threads
          | :reactions
          | :edit
          | :delete
          | :voice
          | :chunk_limit
          | :rate_limit
          | atom()

  @type spec ::
          type()
          | {type(), keyword()}
          | {type(), [atom()]}

  @type t :: %__MODULE__{
          type: type(),
          enabled: boolean(),
          config: map()
        }

  defstruct [:type, :enabled, :config]

  @doc """
  Creates a new capability.

  ## Examples

      Capability.new(:threads, enabled: true)
      Capability.new(:attachments, enabled: true, max_size: 10_000_000)
  """
  @spec new(type(), keyword()) :: t()
  def new(type, opts \\ []) do
    %__MODULE__{
      type: type,
      enabled: Keyword.get(opts, :enabled, true),
      config: build_config(type, opts)
    }
  end

  @doc """
  Creates a capability from a spec.
  """
  @spec from_spec(spec()) :: t() | nil
  def from_spec({type, opts}) when is_list(opts) do
    new(type, opts)
  end

  def from_spec({type, features}) when is_list(features) do
    new(type, features: features)
  end

  def from_spec(type) when is_atom(type) do
    new(type, [])
  end

  def from_spec(_), do: nil

  @doc """
  Validates parameters against capability constraints.
  """
  @spec validate(t(), map()) :: :ok | {:error, term()}
  def validate(%__MODULE__{type: :attachments, config: config}, params) do
    size = params[:size] || params["size"]
    mime_type = params[:mime_type] || params["mime_type"]
    max_size = config[:max_size]
    allowed_mimes = config[:allowed_mimes]

    cond do
      max_size && size && size > max_size ->
        {:error, :file_too_large}

      allowed_mimes && mime_type && not mime_allowed?(mime_type, allowed_mimes) ->
        {:error, :mime_type_not_allowed}

      true ->
        :ok
    end
  end

  def validate(%__MODULE__{type: :rich_blocks, config: config}, params) do
    block_type = params[:type] || params["type"]
    features = config[:features] || []

    if block_type && block_type not in features do
      {:error, {:block_type_not_supported, block_type}}
    else
      :ok
    end
  end

  def validate(%__MODULE__{}, _params) do
    :ok
  end

  @doc """
  Merges two capabilities. The override takes precedence.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override) do
    %__MODULE__{
      type: override.type || base.type,
      enabled: override.enabled,
      config: Map.merge(base.config || %{}, override.config || %{})
    }
  end

  def merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override)
  end

  # Private functions

  defp build_config(:attachments, opts) do
    %{
      max_size: Keyword.get(opts, :max_size, 10_000_000),
      allowed_mimes: Keyword.get(opts, :allowed_mimes, ["*/*"]),
      features: Keyword.get(opts, :features, [:images, :videos, :documents, :audio])
    }
  end

  defp build_config(:rich_blocks, opts) do
    %{
      features: Keyword.get(opts, :features, [:markdown, :buttons, :sections, :divider, :header]),
      max_blocks: Keyword.get(opts, :max_blocks, 50),
      max_block_size: Keyword.get(opts, :max_block_size, 3000)
    }
  end

  defp build_config(:streaming, opts) do
    %{
      mode: Keyword.get(opts, :mode, :buffered),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, 1000),
      supports_interruption: Keyword.get(opts, :supports_interruption, false)
    }
  end

  defp build_config(:threads, _opts) do
    %{
      max_depth: 10,
      supports_forking: true
    }
  end

  defp build_config(:reactions, _opts) do
    %{
      max_reactions_per_message: 20,
      supported_emoji_sets: [:unicode, :custom]
    }
  end

  defp build_config(:chunk_limit, opts) do
    %{
      value: Keyword.get(opts, :value, 4096)
    }
  end

  defp build_config(:rate_limit, opts) do
    %{
      value: Keyword.get(opts, :value, nil)
    }
  end

  defp build_config(_, opts) do
    Map.new(opts)
  end

  defp mime_allowed?(mime_type, patterns) do
    Enum.any?(patterns, fn pattern ->
      mime_match?(mime_type, pattern)
    end)
  end

  defp mime_match?(mime, "*/*"), do: true

  defp mime_match?(mime, pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, "/*") do
      prefix = String.replace_suffix(pattern, "/*", "/")
      String.starts_with?(mime, prefix)
    else
      mime == pattern
    end
  end

  defp mime_match?(_, _), do: false
end

defmodule LemonChannels.Capabilities.Registry do
  @moduledoc """
  Registry for capability sets and lookups.
  """

  alias LemonChannels.Capabilities
  alias LemonChannels.Capabilities.Capability

  @doc """
  Returns a predefined capability set.
  """
  @spec get_set(atom()) :: [Capability.t()]
  def get_set(name) when is_atom(name) do
    case Process.get({:capability_set, name}) do
      nil -> get_builtin_set(name)
      capabilities -> capabilities
    end
  end

  defp get_builtin_set(:messaging) do
    [
      Capability.new(:threads, enabled: true),
      Capability.new(:reactions, enabled: true),
      Capability.new(:edit, enabled: true),
      Capability.new(:delete, enabled: true)
    ]
  end

  defp get_builtin_set(:rich_content) do
    [
      Capability.new(:attachments,
        enabled: true,
        max_size: 50_000_000,
        allowed_mimes: ["image/*", "video/*", "application/pdf"]
      ),
      Capability.new(:rich_blocks,
        enabled: true,
        features: [:markdown, :buttons, :sections, :divider, :header, :image]
      )
    ]
  end

  defp get_builtin_set(:realtime) do
    [
      Capability.new(:streaming,
        enabled: true,
        mode: :realtime,
        max_latency_ms: 500,
        supports_interruption: true
      ),
      Capability.new(:voice, enabled: true)
    ]
  end

  defp get_builtin_set(:full) do
    get_set(:messaging) ++ get_set(:rich_content) ++ get_set(:realtime)
  end

  defp get_builtin_set(:minimal) do
    [
      Capability.new(:chunk_limit, enabled: true, value: 2000)
    ]
  end

  defp get_builtin_set(_) do
    []
  end

  @doc """
  Registers a custom capability set.

  Note: Custom sets are not persisted and only exist for the current process.
  """
  @spec register_set(atom(), [Capability.t()]) :: :ok
  def register_set(name, capabilities) when is_atom(name) and is_list(capabilities) do
    Process.put({:capability_set, name}, capabilities)
    :ok
  end

  @doc """
  Looks up capabilities by adapter ID.
  """
  @spec lookup(atom() | String.t()) :: Capabilities.t()
  def lookup(adapter_id) when is_atom(adapter_id) do
    lookup(Atom.to_string(adapter_id))
  end

  def lookup("telegram") do
    Capabilities.new([
      :threads,
      :reactions,
      :edit,
      :delete,
      :voice,
      {:attachments, max_size: 20_000_000, features: [:images, :videos, :documents, :audio]},
      {:rich_blocks, features: [:markdown, :buttons]},
      {:chunk_limit, value: 4096},
      {:rate_limit, value: 30}
    ])
  end

  def lookup("discord") do
    Capabilities.new([
      :threads,
      :edit,
      :delete,
      {:attachments, max_size: 25_000_000, features: [:images, :videos, :documents]},
      {:rich_blocks, features: [:markdown, :sections, :divider, :header, :image, :buttons]},
      {:chunk_limit, value: 2000},
      {:rate_limit, value: 5}
    ])
  end

  def lookup("x_api") do
    Capabilities.new([
      :threads,
      :edit,
      :delete,
      {:attachments, max_size: 5_000_000, features: [:images, :videos]},
      {:rich_blocks, features: []},
      {:chunk_limit, value: 280},
      {:rate_limit, value: 2400}
    ])
  end

  def lookup("xmtp") do
    Capabilities.new([
      :threads,
      {:attachments, enabled: false},
      {:rich_blocks, enabled: false},
      {:chunk_limit, value: 2000}
    ])
  end

  def lookup(_) do
    Capabilities.empty()
  end
end

defmodule LemonChannels.Capabilities do
  @moduledoc """
  Channel capability definitions and registry.

  Provides a comprehensive system for defining, validating, and querying
  channel capabilities including attachments, rich blocks, streaming,
  threads, and reactions.

  ## Capability Types

  - `:attachments` - File upload support with size limits and mime types
  - `:rich_blocks` - Structured UI blocks (markdown, buttons, sections, etc.)
  - `:streaming` - Real-time message streaming support
  - `:threads` - Thread/conversation nesting support
  - `:reactions` - Message reaction support
  - `:edit` - Message editing support
  - `:delete` - Message deletion support

  ## Usage

      # Define capabilities for a channel
      caps = Capabilities.new([
        :attachments,
        {:rich_blocks, [:markdown, :buttons]},
        :threads
      ])

      # Check if capability is supported
      Capabilities.supports?(caps, :attachments)
      # => true

      # Get capability details
      Capabilities.get(caps, :attachments)
      # => %{max_size: 10_000_000, allowed_mimes: ["image/*", "video/*"]}

      # Validate a capability request
      Capabilities.validate(caps, :attachments, %{size: 5_000_000, mime_type: "image/png"})
      # => :ok
  """

  alias __MODULE__.{Capability, Registry}

  @typedoc "A capabilities map"
  @type t :: %{atom() => Capability.t()}

  # Legacy capability types for backward compatibility
  @typedoc "Legacy capability map (deprecated, use Capability structs)"
  @type legacy_t :: %{
          edit_support: boolean(),
          delete_support: boolean(),
          chunk_limit: non_neg_integer(),
          rate_limit: non_neg_integer() | nil,
          voice_support: boolean(),
          image_support: boolean(),
          file_support: boolean(),
          reaction_support: boolean(),
          thread_support: boolean()
        }

  @doc """
  Creates a new capabilities map from a list of capability specs.

  ## Examples

      # Simple boolean capabilities
      Capabilities.new([:threads, :reactions, :streaming])

      # Capabilities with configuration
      Capabilities.new([
        :threads,
        {:attachments, max_size: 10_000_000},
        {:rich_blocks, [:markdown, :buttons, :sections]}
      ])
  """
  @spec new([Capability.spec()]) :: t()
  def new(specs) when is_list(specs) do
    specs
    |> Enum.map(&Capability.from_spec/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn cap -> {cap.type, cap} end)
    |> then(&Map.merge(default_capabilities(), &1))
  end

  @doc """
  Returns an empty capabilities map.
  """
  @spec empty() :: t()
  def empty do
    %{}
  end

  @doc """
  Checks if a capability is supported.

  ## Examples

      caps = Capabilities.new([:threads, :reactions])
      Capabilities.supports?(caps, :threads)
      # => true
      Capabilities.supports?(caps, :streaming)
      # => false
  """
  @spec supports?(t(), Capability.type()) :: boolean()
  def supports?(caps, capability_type) when is_map(caps) do
    case Map.get(caps, capability_type) do
      nil -> false
      %{enabled: enabled} -> enabled
      %Capability{enabled: enabled} -> enabled
      _ -> false
    end
  end

  @doc """
  Checks if a capability supports specific features.

  ## Examples

      caps = Capabilities.new([{:rich_blocks, [:markdown, :buttons]}])
      Capabilities.supports_feature?(caps, :rich_blocks, :markdown)
      # => true
      Capabilities.supports_feature?(caps, :rich_blocks, :tables)
      # => false
  """
  @spec supports_feature?(t(), Capability.type(), atom()) :: boolean()
  def supports_feature?(caps, capability_type, feature) when is_map(caps) do
    case Map.get(caps, capability_type) do
      %Capability{config: %{features: features}} ->
        feature in features

      %{features: features} ->
        feature in features

      _ ->
        false
    end
  end

  @doc """
  Gets a capability by type.

  ## Examples

      caps = Capabilities.new([{:attachments, max_size: 10_000_000}])
      Capabilities.get(caps, :attachments)
      # => %Capability{type: :attachments, enabled: true, config: %{max_size: 10000000}}
  """
  @spec get(t(), Capability.type()) :: Capability.t() | nil
  def get(caps, capability_type) when is_map(caps) do
    Map.get(caps, capability_type)
  end

  @doc """
  Validates a capability request against the supported capabilities.

  Returns `:ok` if valid, or `{:error, reason}` if invalid.

  ## Examples

      caps = Capabilities.new([{:attachments, max_size: 10_000_000}])
      Capabilities.validate(caps, :attachments, %{size: 5_000_000, mime_type: "image/png"})
      # => :ok

      Capabilities.validate(caps, :attachments, %{size: 15_000_000, mime_type: "image/png"})
      # => {:error, :file_too_large}
  """
  @spec validate(t(), Capability.type(), map()) :: :ok | {:error, term()}
  def validate(caps, capability_type, params) when is_map(caps) do
    case Map.get(caps, capability_type) do
      nil ->
        {:error, :capability_not_supported}

      %Capability{enabled: false} ->
        {:error, :capability_disabled}

      %{enabled: false} ->
        {:error, :capability_disabled}

      capability ->
        Capability.validate(capability, params)
    end
  end

  @doc """
  Returns a list of all supported capability types.
  """
  @spec list(t()) :: [Capability.type()]
  def list(caps) when is_map(caps) do
    caps
    |> Enum.filter(fn {_type, cap} ->
      case cap do
        %Capability{enabled: enabled} -> enabled
        %{enabled: enabled} -> enabled
        _ -> false
      end
    end)
    |> Enum.map(fn {type, _} -> type end)
  end

  @doc """
  Merges two capabilities maps. The second map takes precedence.

  ## Examples

      base = Capabilities.new([:threads, {:attachments, max_size: 5_000_000}])
      override = Capabilities.new([{:attachments, max_size: 10_000_000}, :streaming])
      Capabilities.merge(base, override)
      # => %{attachments: %{max_size: 10000000}, threads: %{...}, streaming: %{...}}
  """
  @spec merge(t(), t()) :: t()
  def merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _type, base_cap, override_cap ->
      Capability.merge(base_cap, override_cap)
    end)
  end

  @doc """
  Returns suggested fallback options for unsupported capabilities.

  ## Examples

      caps = Capabilities.new([:threads])  # no rich_blocks
      Capabilities.fallback_for(caps, :rich_blocks)
      # => {:text, "Fallback to plain text representation"}
  """
  @spec fallback_for(t(), Capability.type()) :: {:ok, term()} | {:error, :no_fallback}
  def fallback_for(_caps, capability_type) do
    case capability_type do
      :rich_blocks ->
        {:ok, {:text, "[Rich content not supported in this channel]"}}

      :attachments ->
        {:ok, {:link, "[File attachment not supported - use external link]"}}

      :streaming ->
        {:ok, {:buffer, "[Streaming not supported - message will be sent complete]"}}

      :reactions ->
        {:ok, {:text_reply, "[Reactions not supported - using text reply instead]"}}

      _ ->
        {:error, :no_fallback}
    end
  end

  @doc """
  Creates a capability set for common channel types.

  ## Predefined Sets

  - `:messaging` - Basic messaging (threads, reactions, edit, delete)
  - `:rich_content` - Rich content support (attachments, rich_blocks)
  - `:realtime` - Real-time features (streaming, voice)
  - `:full` - All capabilities

  ## Examples

      Capabilities.set(:messaging)
      # => [%Capability{type: :threads}, %Capability{type: :reactions}, ...]
  """
  @spec set(atom()) :: [Capability.t()]
  def set(name) when is_atom(name) do
    Registry.get_set(name)
  end

  @doc """
  Returns the default capabilities that all channels should have.
  """
  @spec default_capabilities() :: t()
  def default_capabilities do
    %{
      edit: Capability.new(:edit, enabled: false),
      delete: Capability.new(:delete, enabled: false),
      chunk_limit: Capability.new(:chunk_limit, enabled: true, value: 4096),
      rate_limit: Capability.new(:rate_limit, enabled: false)
    }
  end

  # Legacy functions for backward compatibility

  @doc """
  Default capabilities for a channel (legacy format).

  Deprecated: Use `new/1` or `default_capabilities/0` instead.
  """
  @spec defaults() :: legacy_t()
  def defaults do
    %{
      edit_support: false,
      delete_support: false,
      chunk_limit: 4096,
      rate_limit: nil,
      voice_support: false,
      image_support: false,
      file_support: false,
      reaction_support: false,
      thread_support: false
    }
  end

  @doc """
  Merge capabilities with defaults (legacy format).

  Deprecated: Use `merge/2` instead.
  """
  @spec with_defaults(map()) :: legacy_t()
  def with_defaults(caps) do
    Map.merge(defaults(), caps)
  end

  @doc """
  Converts new capability format to legacy format.

  This is a temporary function for migration purposes.
  """
  @spec to_legacy(t()) :: legacy_t()
  def to_legacy(caps) when is_map(caps) do
    %{
      edit_support: supports?(caps, :edit),
      delete_support: supports?(caps, :delete),
      chunk_limit: get_chunk_limit(caps),
      rate_limit: get_rate_limit(caps),
      voice_support: supports?(caps, :voice),
      image_support: supports_feature?(caps, :attachments, :images),
      file_support: supports?(caps, :attachments),
      reaction_support: supports?(caps, :reactions),
      thread_support: supports?(caps, :threads)
    }
  end

  @doc """
  Converts legacy capability format to new format.
  """
  @spec from_legacy(legacy_t()) :: t()
  def from_legacy(legacy) when is_map(legacy) do
    specs =
      []
      |> maybe_add(legacy[:edit_support], :edit)
      |> maybe_add(legacy[:delete_support], :delete)
      |> maybe_add(legacy[:thread_support], :threads)
      |> maybe_add(legacy[:reaction_support], :reactions)
      |> maybe_add(legacy[:voice_support], :voice)
      |> maybe_add(legacy[:file_support], :attachments)

    specs =
      if legacy[:image_support] do
        [{:attachments, features: [:images]} | specs]
      else
        specs
      end

    caps = new(specs)

    caps =
      if legacy[:chunk_limit] do
        put_in(caps, [Access.key(:chunk_limit)],
          Capability.new(:chunk_limit, enabled: true, value: legacy[:chunk_limit])
        )
      else
        caps
      end

    caps =
      if legacy[:rate_limit] do
        put_in(caps, [Access.key(:rate_limit)],
          Capability.new(:rate_limit, enabled: true, value: legacy[:rate_limit])
        )
      else
        caps
      end

    caps
  end

  # Helper functions

  defp get_chunk_limit(caps) do
    case get(caps, :chunk_limit) do
      %Capability{config: %{value: value}} -> value
      %{config: %{value: value}} -> value
      _ -> 4096
    end
  end

  defp get_rate_limit(caps) do
    case get(caps, :rate_limit) do
      %Capability{enabled: true, config: %{value: value}} -> value
      %{enabled: true, config: %{value: value}} -> value
      _ -> nil
    end
  end

  defp maybe_add(list, true, capability), do: [capability | list]
  defp maybe_add(list, _, _), do: list
end
