defmodule LemonLsp.Servers do
  @moduledoc """
  Registry for BEAM-owned language-server capability metadata.
  """

  @servers [
    %{
      id: :elixir_ls,
      label: "ElixirLS",
      language: :elixir,
      command: "elixir-ls",
      args: [],
      env: %{"ELS_MODE" => "language_server"},
      alternatives: ["elixir-ls-language-server", "language_server.sh", "launch.sh"],
      command_env: "LEMON_LSP_ELIXIR_LS_COMMAND",
      extensions: [".ex", ".exs", ".heex"],
      root_markers: ["mix.exs"],
      install_hint: "Install ElixirLS and put elixir-ls or launch.sh on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :typescript_language_server,
      label: "TypeScript Language Server",
      language: :typescript,
      command: "typescript-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_TYPESCRIPT_COMMAND",
      extensions: [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"],
      root_markers: ["tsconfig.json", "package.json"],
      install_hint: "Install with npm install -g typescript typescript-language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :pyright,
      label: "Pyright",
      language: :python,
      command: "pyright-langserver",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_PYRIGHT_COMMAND",
      extensions: [".py"],
      root_markers: ["pyproject.toml", "setup.py", "requirements.txt"],
      install_hint: "Install with npm install -g pyright.",
      protocol: :lsp_stdio
    },
    %{
      id: :rust_analyzer,
      label: "rust-analyzer",
      language: :rust,
      command: "rust-analyzer",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_RUST_ANALYZER_COMMAND",
      extensions: [".rs"],
      root_markers: ["Cargo.toml"],
      install_hint: "Install rust-analyzer and put it on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :gopls,
      label: "gopls",
      language: :go,
      command: "gopls",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_GOPLS_COMMAND",
      extensions: [".go"],
      root_markers: ["go.mod"],
      install_hint: "Install with go install golang.org/x/tools/gopls@latest.",
      protocol: :lsp_stdio
    },
    %{
      id: :clangd,
      label: "clangd",
      language: :c_cpp,
      command: "clangd",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_CLANGD_COMMAND",
      extensions: [".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx"],
      root_markers: ["compile_commands.json", "compile_flags.txt"],
      install_hint: "Install clangd and put it on PATH.",
      protocol: :lsp_stdio
    }
  ]

  @doc """
  List registered language-server metadata with redacted availability.
  """
  @spec list() :: [map()]
  def list do
    Enum.map(@servers, &server_info/1)
  end

  @doc """
  Resolve registered language-server metadata by id.
  """
  @spec get(atom() | String.t()) :: {:ok, map()} | {:error, :unknown_lsp_server}
  def get(id) do
    normalized = normalize_id(id)

    case get_raw(normalized) do
      nil -> {:error, :unknown_lsp_server}
      server -> {:ok, server_info(server)}
    end
  end

  @doc """
  Validate and normalize a language-server id without creating atoms.
  """
  @spec validate(atom() | String.t()) :: {:ok, atom()} | {:error, :unknown_lsp_server}
  def validate(id) do
    normalized = normalize_id(id)

    case get(normalized) do
      {:ok, _server} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return redacted registry diagnostics for support surfaces.
  """
  @spec diagnostics() :: map()
  def diagnostics do
    servers = list()

    %{
      servers: servers,
      count: length(servers),
      available_count: Enum.count(servers, & &1.available),
      missing_count: Enum.count(servers, &(not &1.available)),
      protocol: :lsp_stdio,
      mode: :registry_only,
      cleanup: %{
        includes_executable_paths: false,
        includes_workspace_roots: false,
        includes_file_contents: false,
        includes_diagnostics_output: false
      }
    }
  end

  @doc false
  @spec resolve_command(atom() | String.t()) ::
          {:ok, map()} | {:error, :unknown_lsp_server | :command_unavailable}
  def resolve_command(id) do
    normalized = normalize_id(id)

    with server when is_map(server) <- get_raw(normalized),
         {:ok, executable} <- resolve_executable(server) do
      {:ok,
       %{
         server: server_info(server),
         executable: executable,
         args: Map.get(server, :args, []),
         env: Map.get(server, :env, %{}),
         command: command_label(executable)
       }}
    else
      nil -> {:error, :unknown_lsp_server}
      {:error, reason} -> {:error, reason}
    end
  end

  defp server_info(server) do
    configured_command = configured_command(server)
    available? = executable_available?(configured_command, server)

    %{
      id: server.id,
      label: server.label,
      language: server.language,
      command: command_label(configured_command || server.command),
      command_env: server.command_env,
      args_count: length(Map.get(server, :args, [])),
      configured: configured_command != nil,
      available: available?,
      extensions: server.extensions,
      root_markers: server.root_markers,
      install_hint: server.install_hint,
      protocol: server.protocol,
      supervised: true,
      running: false,
      status: if(available?, do: :available, else: :missing)
    }
  end

  defp get_raw(id) do
    Enum.find(@servers, &(&1.id == id))
  end

  defp resolve_executable(server) do
    configured_command = configured_command(server)

    candidates =
      case configured_command do
        command when is_binary(command) -> [command]
        _ -> [server.command | server.alternatives]
      end

    case Enum.find_value(candidates, &find_executable/1) do
      nil -> {:error, :command_unavailable}
      executable -> {:ok, executable}
    end
  end

  defp find_executable(command) when is_binary(command) do
    cond do
      String.contains?(command, "/") ->
        expanded = Path.expand(command)
        if File.exists?(expanded), do: expanded, else: nil

      true ->
        System.find_executable(command)
    end
  end

  defp configured_command(%{command_env: env}) do
    case System.get_env(env) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp executable_available?(configured_command, _server) when is_binary(configured_command) do
    System.find_executable(configured_command) != nil or
      File.exists?(Path.expand(configured_command))
  end

  defp executable_available?(nil, server) do
    Enum.any?([server.command | server.alternatives], &(System.find_executable(&1) != nil))
  end

  defp command_label(command) when is_binary(command) do
    command
    |> Path.basename()
    |> case do
      "" -> "[configured]"
      label -> label
    end
  end

  defp normalize_id(id) when is_atom(id), do: id

  defp normalize_id(id) when is_binary(id) do
    normalized =
      id
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    @servers
    |> Enum.map(& &1.id)
    |> Enum.find(:unknown, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_id(_), do: :unknown
end
