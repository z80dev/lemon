defmodule LemonControlPlane.Method do
  @moduledoc """
  Behaviour and macro for self-describing control plane methods.

  Modules that `use LemonControlPlane.Method` declare their metadata (name,
  scopes, schema, capabilities) at compile time. The registry and schema layer
  can then auto-discover these modules instead of relying on manually-maintained
  lists.

  ## Usage

      defmodule LemonControlPlane.Methods.Health do
        use LemonControlPlane.Method,
          name: "health",
          scopes: [],
          schema: %{optional: %{}}

        @impl true
        def handle(_params, _ctx) do
          {:ok, %{"ok" => true}}
        end
      end

  The macro defines the following functions automatically:

    * `name/0`       - returns the method name string
    * `scopes/0`     - returns the required scope list
    * `__schema__/0`  - returns the schema map (for auto-registration in Schemas)
    * `__capabilities__/0` - returns the capability gate list

  Modules that do **not** use the macro can still implement the
  `LemonControlPlane.Method` behaviour manually (only `name/0`, `scopes/0`,
  and `handle/2` are required callbacks). This preserves backward compatibility
  for the ~100 existing method modules during incremental migration.
  """

  @doc """
  Returns the method name (e.g., "health", "agent", "sessions.list").
  """
  @callback name() :: String.t()

  @doc """
  Returns the required scopes for this method.

  Return an empty list for public methods.
  """
  @callback scopes() :: [atom()]

  @doc """
  Handles the method call.

  ## Parameters

  - `params` - The method parameters from the request (may be nil)
  - `ctx` - The connection context including:
    - `auth` - Authentication context
    - `conn_id` - Connection ID
    - `conn_pid` - Connection process PID

  ## Return Values

  - `{:ok, payload}` - Success with response payload
  - `{:error, {code, message}}` - Error with code and message
  - `{:error, {code, message, details}}` - Error with additional details
  """
  @callback handle(params :: map() | nil, ctx :: map()) ::
              {:ok, term()}
              | {:error, {atom(), String.t()}}
              | {:error, {atom(), String.t(), term()}}

  @doc """
  Optional callback: returns the schema map for this method.

  Only implemented automatically by modules that `use LemonControlPlane.Method`.
  Manually-written modules do not need to implement this.
  """
  @callback __schema__() :: map()

  @doc """
  Optional callback: returns the capability gates for this method.

  Only implemented automatically by modules that `use LemonControlPlane.Method`.
  """
  @callback __capabilities__() :: [atom()]

  @optional_callbacks [__schema__: 0, __capabilities__: 0]

  @doc """
  Extracts a required parameter from the params map.

  Returns `{:ok, value}` if present, or an `{:error, ...}` tuple suitable for
  returning directly from `handle/2`.
  """
  @spec require_param(map(), String.t()) :: {:ok, term()} | {:error, {atom(), String.t(), nil}}
  def require_param(params, key) do
    case params[key] do
      nil -> {:error, {:invalid_request, "#{key} is required", nil}}
      value -> {:ok, value}
    end
  end

  # ------------------------------------------------------------------
  # Macro
  # ------------------------------------------------------------------

  @doc """
  Injects self-describing metadata into a method module.

  ## Options

    * `:name` (required) - the method name string
    * `:scopes` - list of required scope atoms (default `[]`)
    * `:schema` - schema map matching the format used in `Schemas` (default `%{}`)
    * `:capabilities` - capability gate atoms (default `[]`)
  """
  defmacro __using__(opts) do
    quote do
      @behaviour LemonControlPlane.Method

      @__method_name__ Keyword.fetch!(unquote(opts), :name)
      @__method_scopes__ Keyword.get(unquote(opts), :scopes, [])
      @__method_schema__ Keyword.get(unquote(opts), :schema, %{})
      @__method_capabilities__ Keyword.get(unquote(opts), :capabilities, [])

      @impl true
      def name, do: @__method_name__

      @impl true
      def scopes, do: @__method_scopes__

      @impl true
      def __schema__, do: @__method_schema__

      @impl true
      def __capabilities__, do: @__method_capabilities__

      # Register this module for compile-time discovery
      @after_compile {LemonControlPlane.Method, :__after_compile__}
    end
  end

  @doc false
  def __after_compile__(_env, _bytecode) do
    # This hook is intentionally empty. Discovery is performed at runtime
    # by scanning loaded modules (see `discover_methods/0`).
    :ok
  end

  # ------------------------------------------------------------------
  # Runtime discovery
  # ------------------------------------------------------------------

  @doc """
  Discovers all loaded modules that use the `LemonControlPlane.Method` macro
  (i.e., export `__schema__/0`).

  Returns a list of `{method_name, module}` tuples.
  """
  @spec discover_methods() :: [{String.t(), module()}]
  def discover_methods do
    prefix = ~c"Elixir.LemonControlPlane.Methods."

    :code.all_loaded()
    |> Enum.filter(fn {mod, _file} ->
      mod_str = Atom.to_charlist(mod)
      :lists.prefix(prefix, mod_str) and has_macro_metadata?(mod)
    end)
    |> Enum.map(fn {mod, _file} -> {mod.name(), mod} end)
  end

  @doc """
  Returns true if `module` was compiled with `use LemonControlPlane.Method`
  (i.e., exports the optional `__schema__/0` callback).
  """
  @spec has_macro_metadata?(module()) :: boolean()
  def has_macro_metadata?(module) do
    function_exported?(module, :__schema__, 0)
  end
end
