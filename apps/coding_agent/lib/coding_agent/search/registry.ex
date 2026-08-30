defmodule CodingAgent.Search.Registry do
  @moduledoc """
  Crash-resilient registry for built-in and extension search providers.

  Search provider reads happen for every web tool call while writes are limited
  to application startup and extension reload, so the registry uses
  `:persistent_term` with a global mutation lock. Built-ins cannot be replaced
  accidentally; an extension conflict is reported to the extension lifecycle.
  """

  alias CodingAgent.Search.Provider

  @persistent_term_key {__MODULE__, :providers}
  @mutation_lock {__MODULE__, :mutation_lock}

  @type provider_spec :: %{
          required(:id) => String.t(),
          required(:module) => module(),
          required(:capabilities) => [Provider.capability()],
          required(:source) => String.t(),
          optional(:priority) => integer(),
          optional(:config) => map()
        }

  @doc "Initializes the registry with bundled providers. Safe to call repeatedly."
  @spec init() :: :ok
  def init do
    with_mutation_lock(fn ->
      unless initialized?() do
        :persistent_term.put(@persistent_term_key, builtin_specs())
      end

      :ok
    end)
  end

  @doc "Restores only bundled providers. Intended for deterministic tests."
  @spec reset() :: :ok
  def reset do
    with_mutation_lock(fn ->
      :persistent_term.put(@persistent_term_key, builtin_specs())
      :ok
    end)
  end

  @doc "Registers a provider without replacing an existing identifier."
  @spec register(String.t() | atom(), module(), keyword()) ::
          :ok | {:error, :already_registered | :invalid_provider}
  def register(id, module, opts \\ []) when is_atom(module) and is_list(opts) do
    with {:ok, spec} <- build_spec(id, module, opts) do
      with_mutation_lock(fn ->
        providers = providers()

        if Map.has_key?(providers, spec.id) do
          {:error, :already_registered}
        else
          :persistent_term.put(@persistent_term_key, Map.put(providers, spec.id, spec))
          :ok
        end
      end)
    end
  end

  @doc "Unregisters a non-builtin provider."
  @spec unregister(String.t() | atom()) :: :ok | {:error, :builtin_provider}
  def unregister(id) do
    normalized = normalize_id(id)

    if Map.has_key?(builtin_specs(), normalized) do
      {:error, :builtin_provider}
    else
      with_mutation_lock(fn ->
        :persistent_term.put(@persistent_term_key, Map.delete(providers(), normalized))
        :ok
      end)
    end
  end

  @doc "Returns one provider specification."
  @spec fetch(String.t() | atom()) :: {:ok, provider_spec()} | {:error, :not_found}
  def fetch(id) do
    case Map.fetch(providers(), normalize_id(id)) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, :not_found}
    end
  end

  @doc "Lists providers deterministically, optionally filtered by capability."
  @spec list(keyword()) :: [provider_spec()]
  def list(opts \\ []) do
    capability = Keyword.get(opts, :capability)

    providers()
    |> Map.values()
    |> Enum.filter(fn spec ->
      is_nil(capability) or capability in spec.capabilities
    end)
    |> Enum.sort_by(fn spec -> {-Map.get(spec, :priority, 0), spec.id} end)
  end

  @doc "Returns redaction-safe provider metadata for diagnostics."
  @spec status() :: map()
  def status do
    specs = list()

    %{
      providers:
        Enum.map(specs, fn spec ->
          Map.take(spec, [:id, :capabilities, :source, :priority])
        end),
      count: length(specs),
      search_count: Enum.count(specs, &(:search in &1.capabilities)),
      extract_count: Enum.count(specs, &(:extract in &1.capabilities))
    }
  end

  @doc false
  def initialized? do
    try do
      :persistent_term.get(@persistent_term_key)
      true
    rescue
      ArgumentError -> false
    end
  end

  defp providers do
    unless initialized?(), do: init()
    :persistent_term.get(@persistent_term_key)
  end

  defp builtin_specs do
    [
      {"brave", CodingAgent.Search.Providers.Brave, 100},
      {"perplexity", CodingAgent.Search.Providers.Perplexity, 90},
      {"duckduckgo", CodingAgent.Search.Providers.DuckDuckGo, 50},
      {"searxng", CodingAgent.Search.Providers.Searxng, 40},
      {"direct", CodingAgent.Search.Providers.DirectExtract, 100},
      {"firecrawl", CodingAgent.Search.Providers.FirecrawlExtract, 80}
    ]
    |> Enum.reduce(%{}, fn {id, module, priority}, acc ->
      spec = %{
        id: id,
        module: module,
        capabilities: module.capabilities(),
        source: "builtin",
        priority: priority,
        config: %{}
      }

      Map.put(acc, id, spec)
    end)
  end

  defp build_spec(id, module, opts) do
    normalized_id = normalize_id(id)

    capabilities =
      if function_exported?(module, :capabilities, 0), do: module.capabilities(), else: []

    valid? =
      normalized_id != "" and function_exported?(module, :id, 0) and
        function_exported?(module, :available?, 2) and capabilities != [] and
        Enum.all?(capabilities, &Provider.valid_capability?/1) and
        Enum.all?(capabilities, &callback_available?(module, &1))

    if valid? do
      {:ok,
       %{
         id: normalized_id,
         module: module,
         capabilities: Enum.uniq(capabilities),
         source: Keyword.get(opts, :source, "runtime"),
         priority: Keyword.get(opts, :priority, 0),
         config: Keyword.get(opts, :config, %{})
       }}
    else
      {:error, :invalid_provider}
    end
  end

  defp callback_available?(module, :search), do: function_exported?(module, :search, 2)
  defp callback_available?(module, :extract), do: function_exported?(module, :extract, 2)

  defp normalize_id(id) when is_atom(id), do: id |> Atom.to_string() |> normalize_id()

  defp normalize_id(id) when is_binary(id) do
    id |> String.trim() |> String.downcase()
  end

  defp normalize_id(_), do: ""

  defp with_mutation_lock(fun), do: :global.trans({@mutation_lock, self()}, fun)
end
