defmodule LemonCore.Doctor.LspDiagnostics do
  @moduledoc false

  @default_timeout_ms 20_000

  @languages [
    %{
      language: :elixir,
      extensions: [".ex", ".exs", ".heex"],
      source: "elixir syntax + mix compile",
      executables: ["mix"],
      workspace_markers: ["mix.exs"],
      semantic: true
    },
    %{
      language: :javascript,
      extensions: [".js", ".cjs", ".mjs"],
      source: "node --check",
      executables: ["node"],
      workspace_markers: [],
      semantic: false
    },
    %{
      language: :typescript,
      extensions: [".ts", ".tsx", ".jsx"],
      source: "tsc --noEmit",
      executables: ["npx"],
      workspace_markers: ["tsconfig.json"],
      semantic: true
    },
    %{
      language: :python,
      extensions: [".py"],
      source: "python py_compile",
      executables: ["python3", "python"],
      workspace_markers: [],
      semantic: false
    },
    %{
      language: :rust,
      extensions: [".rs"],
      source: "cargo check",
      executables: ["cargo"],
      workspace_markers: ["Cargo.toml"],
      semantic: true
    },
    %{
      language: :go,
      extensions: [".go"],
      source: "go test",
      executables: ["go"],
      workspace_markers: ["go.mod"],
      semantic: true
    },
    %{
      language: :c_cpp,
      extensions: [".c", ".h", ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"],
      source: "compiler -fsyntax-only",
      executables: ["clang", "gcc", "cc", "clang++", "g++", "c++"],
      workspace_markers: ["compile_commands.json", "compile_flags.txt"],
      semantic: false
    }
  ]

  def status(opts \\ []) do
    timeout_ms = Keyword.get(opts, :diagnostics_timeout_ms, @default_timeout_ms)
    languages = Enum.map(@languages, &language_status/1)
    executable_names = languages |> Enum.flat_map(& &1.executables) |> Enum.map(& &1.name)
    executable_status = executable_summary(executable_names)

    %{
      status: :preview,
      default_timeout_ms: timeout_ms,
      supported_language_count: length(languages),
      supported_languages: languages,
      executable_summary: executable_status,
      server_manager:
        probe(LemonLsp.ServerManager, :status, [], %{
          supervised: false,
          running: false,
          mode: :unavailable,
          error: "lsp runtime not available",
          active_servers: [],
          active_count: 0,
          pending_request_count: 0,
          recent_sessions: []
        }),
      cleanup: %{
        includes_raw_paths: false,
        includes_file_contents: false,
        includes_diagnostics_output: false,
        includes_workspace_roots: false,
        includes_server_io: false,
        includes_raw_session_ids: false
      }
    }
  end

  defp language_status(language) do
    executables = Enum.map(language.executables, &executable_status/1)

    language
    |> Map.put(:executables, executables)
    |> Map.put(:available, Enum.any?(executables, & &1.available))
  end

  defp executable_status(name) do
    %{name: name, available: System.find_executable(name) != nil}
  end

  defp executable_summary(names) do
    statuses =
      names
      |> Enum.uniq()
      |> Enum.map(&executable_status/1)

    %{
      available_count: Enum.count(statuses, & &1.available),
      missing_count: Enum.count(statuses, &(not &1.available)),
      executables: statuses
    }
  end

  defp probe(mod, fun, args, fallback) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      fallback
    end
  end
end
