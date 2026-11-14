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
  def from_spec({type, options_or_features}) when is_list(options_or_features) do
    if Keyword.keyword?(options_or_features) do
      new(type, options_or_features)
    else
      new(type, features: options_or_features)
    end
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

  defp mime_match?(_mime, "*/*"), do: true

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

  alias __MODULE__.Capability

  @typedoc "A capabilities map"
  @type t :: %{atom() => Capability.t()}

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

  @doc """
  Converts legacy capability format to new format.
  """
  @spec from_legacy(map()) :: t()
  def from_legacy(legacy) when is_map(legacy) do
    specs =
      []
      |> maybe_add(legacy[:edit_support], :edit)
      |> maybe_add(legacy[:delete_support], :delete)
      |> maybe_add(legacy[:thread_support], :threads)
      |> maybe_add(legacy[:reaction_support], :reactions)
      |> maybe_add(legacy[:voice_support], :voice)
      |> maybe_add(legacy[:file_support], :attachments)
      |> maybe_add(legacy[:rich_blocks], :rich_blocks)

    specs =
      if legacy[:image_support] do
        [{:attachments, features: [:images]} | specs]
      else
        specs
      end

    caps = new(specs)

    caps =
      if legacy[:chunk_limit] do
        put_in(
          caps,
          [Access.key(:chunk_limit)],
          Capability.new(:chunk_limit, enabled: true, value: legacy[:chunk_limit])
        )
      else
        caps
      end

    caps =
      if legacy[:rate_limit] do
        put_in(
          caps,
          [Access.key(:rate_limit)],
          Capability.new(:rate_limit, enabled: true, value: legacy[:rate_limit])
        )
      else
        caps
      end

    caps
  end

  # Helper functions

  defp maybe_add(list, true, capability), do: [capability | list]
  defp maybe_add(list, _, _), do: list
end
