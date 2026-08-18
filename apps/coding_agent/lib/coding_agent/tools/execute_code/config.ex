defmodule CodingAgent.Tools.ExecuteCode.Config do
  @moduledoc """
  Resolved `execute_code` configuration for one working directory.

  The settings arriving through `settings_manager.tools[:execute_code]` have
  already been env-resolved by `LemonCore.Config.Tools.resolve/1`, so — exactly
  like `CodingAgent.Wasm.Config` — this module never reads the environment
  itself. It only normalizes the shape (atom- or string-keyed, string or native
  values) and applies the RPC allowlist.

  The allowlist is fixed at compile time: config may *narrow* it but never widen
  it, so no configuration can hand a script `bash`, `write`, or `edit`.

  `kernel_mode` and the kernel bounds freeze the persistent-interpreter
  contract: only an explicit "session" selects session mode and anything
  unrecognized stays `per_call`, so a config mistake can never silently enable
  persistence. The bounds are consumed by the `CodingAgent.PythonRepl`
  session path; `per_call` runs ignore them.
  """

  @rpc_allowlist ~w(read grep find ls webfetch)

  @default_timeout_ms 120_000
  @default_max_rpc_calls 100
  @default_max_rpc_result_bytes 5_242_880
  @default_max_output_bytes 50_000
  @default_kernel_mode "per_call"
  @default_kernel_idle_timeout_ms 1_800_000
  @default_max_live_kernels 16
  @default_max_queued_cells_per_kernel 8

  @type t :: %__MODULE__{
          enabled: boolean(),
          python_path: String.t() | nil,
          timeout_ms: pos_integer(),
          max_rpc_calls: pos_integer(),
          max_rpc_result_bytes: pos_integer(),
          max_output_bytes: pos_integer(),
          kernel_mode: kernel_mode(),
          kernel_idle_timeout_ms: pos_integer(),
          max_live_kernels: pos_integer(),
          max_queued_cells_per_kernel: pos_integer(),
          tools: [String.t()]
        }

  @typedoc """
  `"per_call"` (default): every script runs in a fresh process. `"session"`:
  scripts share a persistent interpreter. Normalization maps every other
  spelling to `"per_call"`.
  """
  @type kernel_mode :: String.t()

  defstruct enabled: false,
            python_path: nil,
            timeout_ms: @default_timeout_ms,
            max_rpc_calls: @default_max_rpc_calls,
            max_rpc_result_bytes: @default_max_rpc_result_bytes,
            max_output_bytes: @default_max_output_bytes,
            kernel_mode: @default_kernel_mode,
            kernel_idle_timeout_ms: @default_kernel_idle_timeout_ms,
            max_live_kernels: @default_max_live_kernels,
            max_queued_cells_per_kernel: @default_max_queued_cells_per_kernel,
            tools: @rpc_allowlist

  @doc """
  The full RPC allowlist, in the fixed order the python shim emits stubs.
  """
  @spec allowlist() :: [String.t()]
  def allowlist, do: @rpc_allowlist

  @doc """
  Load the `execute_code` config for `cwd` from a settings manager map.

  A `nil` or shapeless settings manager yields all defaults, which means
  `enabled: false` — registry gating is deterministic when no settings are
  passed.
  """
  @spec load(String.t(), map() | nil) :: t()
  def load(cwd, settings_manager \\ nil) do
    cwd = Path.expand(cwd)

    ec =
      settings_manager
      |> extract_execute_code_map()
      |> stringify_keys()

    %__MODULE__{
      enabled: parse_boolean(ec["enabled"], false),
      python_path: parse_optional_path(ec["python_path"], cwd),
      timeout_ms: parse_positive_integer(ec["timeout_ms"], @default_timeout_ms),
      max_rpc_calls: parse_positive_integer(ec["max_rpc_calls"], @default_max_rpc_calls),
      max_rpc_result_bytes:
        parse_positive_integer(ec["max_rpc_result_bytes"], @default_max_rpc_result_bytes),
      max_output_bytes: parse_positive_integer(ec["max_output_bytes"], @default_max_output_bytes),
      kernel_mode: parse_kernel_mode(ec["kernel_mode"]),
      kernel_idle_timeout_ms:
        parse_positive_integer(ec["kernel_idle_timeout_ms"], @default_kernel_idle_timeout_ms),
      max_live_kernels: parse_positive_integer(ec["max_live_kernels"], @default_max_live_kernels),
      max_queued_cells_per_kernel:
        parse_positive_integer(
          ec["max_queued_cells_per_kernel"],
          @default_max_queued_cells_per_kernel
        ),
      tools: parse_tools(ec["tools"])
    }
  end

  defp extract_execute_code_map(%{tools: tools}) when is_map(tools) do
    Map.get(tools, :execute_code) || Map.get(tools, "execute_code") || %{}
  end

  defp extract_execute_code_map(%{"tools" => tools}) when is_map(tools) do
    Map.get(tools, :execute_code) || Map.get(tools, "execute_code") || %{}
  end

  defp extract_execute_code_map(_), do: %{}

  defp stringify_keys(value), do: LemonCore.MapHelpers.stringify_keys(value)

  # An empty configured list means "everything on the allowlist". A non-empty
  # list narrows it: unknown names are dropped silently rather than widening the
  # surface, and an operator who lists only invalid names gets zero stubs (an
  # explicit "no tool access" script sandbox), not a silent reset to full.
  defp parse_tools(nil), do: @rpc_allowlist

  defp parse_tools(value) do
    case parse_string_list(value) do
      [] -> @rpc_allowlist
      names -> Enum.filter(names, &(&1 in @rpc_allowlist))
    end
  end

  defp parse_string_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_string_list(value) when is_binary(value) do
    value
    |> String.split(~r/[,:]/, trim: true)
    |> parse_string_list()
  end

  defp parse_string_list(_), do: []

  # Only an explicit "session" (string or atom spelling) selects session mode.
  # Everything else — typos, booleans, integers — stays per_call so invalid
  # config can never silently enable persistence.
  defp parse_kernel_mode(value) when value in ["session", :session], do: "session"
  defp parse_kernel_mode(_value), do: @default_kernel_mode

  defp parse_boolean(nil, default), do: default
  defp parse_boolean(value, _default) when value in [true, "true", "1", 1], do: true
  defp parse_boolean(value, _default) when value in [false, "false", "0", 0], do: false
  defp parse_boolean(_, default), do: default

  defp parse_positive_integer(value, _default) when is_integer(value), do: max(value, 1)

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> max(parsed, 1)
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp parse_optional_path(nil, _cwd), do: nil

  defp parse_optional_path(path, cwd) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> nil
      Path.type(trimmed) == :absolute -> Path.expand(trimmed)
      true -> Path.expand(trimmed, cwd)
    end
  end

  defp parse_optional_path(_, _cwd), do: nil
end
