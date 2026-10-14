defmodule CodingAgent.Debug.Adapters do
  @moduledoc """
  Built-in debug adapter catalog and launch/attach adapter selection.

  Selection mirrors omp's DAP defaults: an explicit `adapter` wins; otherwise
  the program's file extension picks an adapter (`.py` → debugpy, `.go` → dlv,
  C/C++/Rust/Swift sources → lldb-dap); extensionless programs (compiled
  binaries) fall back to native debuggers in the order `gdb`, `lldb-dap`, with
  adapters whose project root markers (`Cargo.toml`, `go.mod`, ...) appear
  above the program preferred. Directories are only accepted by adapters that
  debug packages (`dlv`).

  Callers may pass extra or overriding adapter specs (same shape as the
  built-ins, with a `:command` executable name or path) through the
  `:debug_adapters` tool option.
  """

  @extensionless_order ["gdb", "lldb-dap"]

  @builtin %{
    "gdb" => %{
      commands: ["gdb"],
      args: ["-i", "dap"],
      connect_mode: :stdio,
      file_types: ~w(.c .cc .cpp .cxx .h .hh .hpp .hxx .rs),
      root_markers: ~w(Makefile CMakeLists.txt Cargo.toml compile_commands.json),
      launch_defaults: %{"stopOnEntry" => true, "stopAtBeginningOfMainSubprogram" => true},
      attach_defaults: %{},
      accepts_directory: false,
      install_hint: "install GDB 14 or newer (it provides the `gdb -i dap` interpreter)"
    },
    "lldb-dap" => %{
      commands: ["lldb-dap", {:xcrun, "lldb-dap"}, "lldb-vscode"],
      args: [],
      connect_mode: :stdio,
      file_types: ~w(.c .cc .cpp .cxx .m .mm .swift .rs .zig),
      root_markers: ~w(Package.swift Cargo.toml Makefile CMakeLists.txt build.zig),
      launch_defaults: %{"stopOnEntry" => true},
      attach_defaults: %{},
      accepts_directory: false,
      install_hint:
        "install LLVM's lldb-dap (macOS: `xcode-select --install`; Linux: the lldb package, " <>
          "e.g. `apt install lldb`)"
    },
    "debugpy" => %{
      commands: ["python3", "python"],
      args: ["-m", "debugpy.adapter"],
      connect_mode: :stdio,
      file_types: ~w(.py),
      root_markers: ~w(pyproject.toml setup.py requirements.txt Pipfile),
      launch_defaults: %{
        "justMyCode" => false,
        "stopOnEntry" => true,
        "console" => "internalConsole"
      },
      attach_defaults: %{"justMyCode" => false},
      accepts_directory: false,
      install_hint: "install Python 3 and debugpy (`pip install debugpy`)"
    },
    "dlv" => %{
      commands: ["dlv"],
      args: ["dap"],
      connect_mode: :socket,
      file_types: ~w(.go),
      root_markers: ~w(go.mod go.sum go.work),
      launch_defaults: %{"mode" => "debug", "stopOnEntry" => true},
      attach_defaults: %{"mode" => "local"},
      accepts_directory: true,
      install_hint: "install Delve (`go install github.com/go-delve/delve/cmd/dlv@latest`)"
    }
  }

  # Launch-config keys that request an initial stop before user code runs.
  @entry_stop_keys ["stopOnEntry", "stopAtBeginningOfMainSubprogram"]

  @type resolved :: %{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          connect_mode: :stdio | :socket,
          file_types: [String.t()],
          root_markers: [String.t()],
          launch_defaults: map(),
          attach_defaults: map(),
          accepts_directory: boolean()
        }

  @type program_kind :: :file | :directory | :missing

  @doc "Launch-config keys that request a stop at program entry."
  @spec entry_stop_keys() :: [String.t()]
  def entry_stop_keys, do: @entry_stop_keys

  @doc """
  Select the adapter for launching `program` (absolute path).

  Returns `{:ok, adapter}` or `{:error, message}` with an install hint.
  """
  @spec select_launch(String.t(), String.t(), String.t() | nil, program_kind(), keyword()) ::
          {:ok, resolved()} | {:error, String.t()}
  def select_launch(program, cwd, adapter_name, kind, opts \\ []) do
    configs = configs(opts)

    result =
      if is_binary(adapter_name) and adapter_name != "" do
        resolve_named(adapter_name, configs)
      else
        select_automatic(program, cwd, kind, configs)
      end

    with {:ok, adapter} <- result,
         :ok <- validate_program_kind(adapter, kind) do
      {:ok, adapter}
    end
  end

  @doc "Select the adapter for an attach request."
  @spec select_attach(String.t() | nil, integer() | nil, keyword()) ::
          {:ok, resolved()} | {:error, String.t()}
  def select_attach(adapter_name, port, opts \\ []) do
    configs = configs(opts)

    if is_integer(port) and adapter_name in [nil, "", "debugpy"] do
      {:ok,
       Map.merge(configs["debugpy"], %{name: "debugpy", command: nil, connect_mode: :remote})}
    else
      if is_binary(adapter_name) and adapter_name != "" do
        resolve_named(adapter_name, configs)
      else
        available =
          configs
          |> Map.keys()
          |> Enum.sort()
          |> Enum.flat_map(fn name ->
            case resolve_config(name, configs) do
              {:ok, adapter} -> [adapter]
              _ -> []
            end
          end)

        preferred =
          if is_integer(port), do: ["debugpy" | @extensionless_order], else: @extensionless_order

        found =
          Enum.find_value(preferred, fn name -> Enum.find(available, &(&1.name == name)) end) ||
            List.first(available)

        if found, do: {:ok, found}, else: {:error, no_adapter_message(configs)}
      end
    end
  end

  @doc """
  Adapter-specific launch arguments derived from the program.

  Delve debugs `.go` files and package directories as source (`mode=debug`)
  and anything else as a compiled binary (`mode=exec`).
  """
  @spec launch_overrides(resolved(), String.t(), program_kind()) :: map()
  def launch_overrides(%{name: "dlv"}, program, kind) do
    cond do
      kind == :directory or String.downcase(Path.extname(program)) == ".go" ->
        %{"mode" => "debug"}

      kind == :file ->
        %{"mode" => "exec"}

      true ->
        %{}
    end
  end

  def launch_overrides(_adapter, _program, _kind), do: %{}

  # ── Selection ────────────────────────────────────────────────────────────

  defp select_automatic(program, cwd, kind, configs) do
    extension = String.downcase(Path.extname(program))

    by_extension =
      if extension != "" and kind != :directory do
        configs
        |> Enum.filter(fn {_name, config} -> extension in config.file_types end)
        |> Enum.map(fn {name, config} ->
          {name, root_dir(program, cwd, config.root_markers, kind)}
        end)
      else
        []
      end

    case pick_available(Enum.map(by_extension, &elem(&1, 0)), program, cwd, kind, configs) do
      {:ok, adapter} ->
        {:ok, adapter}

      :none when by_extension != [] ->
        {name, _root} =
          Enum.find(by_extension, fn {_name, root} -> root end) ||
            Enum.min_by(by_extension, &elem(&1, 0))

        unavailable(name, configs)

      :none ->
        select_extensionless(program, cwd, kind, configs)
    end
  end

  defp select_extensionless(program, cwd, kind, configs) do
    rooted =
      configs
      |> Enum.filter(fn {_name, config} -> root_dir(program, cwd, config.root_markers, kind) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    candidates =
      if kind == :directory do
        Enum.filter(rooted, &configs[&1].accepts_directory)
      else
        Enum.uniq(@extensionless_order ++ rooted)
      end

    case pick_available(candidates, program, cwd, kind, configs) do
      {:ok, adapter} -> {:ok, adapter}
      :none when candidates != [] and kind == :directory -> unavailable(hd(candidates), configs)
      :none when rooted != [] -> unavailable(hd(rooted), configs)
      :none -> {:error, no_adapter_message(configs)}
    end
  end

  defp pick_available(names, program, cwd, kind, configs) do
    extension = String.downcase(Path.extname(program))

    names
    |> Enum.flat_map(fn name ->
      case resolve_config(name, configs) do
        {:ok, adapter} -> [adapter]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn adapter ->
      rank = Enum.find_index(@extensionless_order, &(&1 == adapter.name)) || 1_000

      {extension == "" or extension not in adapter.file_types,
       is_nil(root_dir(program, cwd, adapter.root_markers, kind)), rank, adapter.name}
    end)
    |> case do
      [adapter | _] -> {:ok, adapter}
      [] -> :none
    end
  end

  defp validate_program_kind(%{accepts_directory: true}, _kind), do: :ok

  defp validate_program_kind(_adapter, :directory),
    do:
      {:error,
       "launch program is a directory. Pass an executable file path or choose an adapter " <>
         "that debugs package directories (dlv)."}

  defp validate_program_kind(_adapter, _kind), do: :ok

  defp root_dir(_program, _cwd, [], _kind), do: nil

  defp root_dir(program, cwd, markers, kind) do
    absolute = Path.expand(program, cwd)
    start = if kind == :directory, do: absolute, else: Path.dirname(absolute)
    find_root(start, markers)
  end

  defp find_root(dir, markers) do
    cond do
      Enum.any?(markers, &File.exists?(Path.join(dir, &1))) -> dir
      Path.dirname(dir) == dir -> nil
      true -> find_root(Path.dirname(dir), markers)
    end
  end

  # ── Resolution ───────────────────────────────────────────────────────────

  defp resolve_named(name, configs) do
    case Map.fetch(configs, name) do
      {:ok, _config} ->
        case resolve_config(name, configs) do
          {:ok, adapter} -> {:ok, adapter}
          :unavailable -> unavailable(name, configs)
        end

      :error ->
        {:error,
         "unknown debug adapter '#{name}'. Known adapters: #{Enum.join(Enum.sort(Map.keys(configs)), ", ")}"}
    end
  end

  defp resolve_config(name, configs) do
    config = Map.fetch!(configs, name)

    case Enum.find_value(config.commands, &find_command/1) do
      nil ->
        :unavailable

      command ->
        {:ok,
         config
         |> Map.take([
           :args,
           :connect_mode,
           :file_types,
           :root_markers,
           :launch_defaults,
           :attach_defaults,
           :accepts_directory
         ])
         |> Map.merge(%{name: name, command: command})}
    end
  end

  defp find_command({:xcrun, tool}) do
    with {:unix, :darwin} <- :os.type(),
         xcrun when is_binary(xcrun) <- System.find_executable("xcrun"),
         {path, 0} <- System.cmd(xcrun, ["-f", tool], stderr_to_stdout: true),
         path = String.trim(path),
         true <- File.regular?(path) do
      path
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp find_command(command) when is_binary(command) do
    if String.contains?(command, "/") do
      if File.regular?(command), do: command
    else
      System.find_executable(command)
    end
  end

  defp unavailable(name, configs) do
    hint = Map.get(configs[name], :install_hint)
    suffix = if hint, do: ": #{hint}", else: ""
    {:error, "debug adapter '#{name}' is not available#{suffix}"}
  end

  defp no_adapter_message(configs) do
    case available_from(configs) do
      [] ->
        "No debug adapter is installed. Install lldb-dap, gdb, debugpy or dlv."

      names ->
        "No debug adapter matches this program. Installed adapters: #{Enum.join(names, ", ")}"
    end
  end

  defp available_from(configs) do
    configs
    |> Map.keys()
    |> Enum.filter(&match?({:ok, _}, resolve_config(&1, configs)))
    |> Enum.sort()
  end

  # ── Configuration ────────────────────────────────────────────────────────

  defp configs(opts) do
    extra =
      opts
      |> Keyword.get(:debug_adapters, %{})
      |> Map.new(fn {name, spec} -> {to_string(name), normalize_spec(spec)} end)

    Map.merge(@builtin, extra)
  end

  defp normalize_spec(spec) when is_map(spec) do
    command = Map.get(spec, :command)

    %{
      commands: List.wrap(Map.get(spec, :commands, command)),
      args: Map.get(spec, :args, []),
      connect_mode: Map.get(spec, :connect_mode, :stdio),
      file_types: Enum.map(Map.get(spec, :file_types, []), &String.downcase/1),
      root_markers: Map.get(spec, :root_markers, []),
      launch_defaults: Map.get(spec, :launch_defaults, %{}),
      attach_defaults: Map.get(spec, :attach_defaults, %{}),
      accepts_directory: Map.get(spec, :accepts_directory, false),
      install_hint: Map.get(spec, :install_hint)
    }
  end
end
