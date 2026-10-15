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
      language_ids: %{".ex" => "elixir", ".exs" => "elixir", ".heex" => "phoenix-heex"},
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
      language_ids: %{
        ".ts" => "typescript",
        ".tsx" => "typescriptreact",
        ".js" => "javascript",
        ".jsx" => "javascriptreact",
        ".mjs" => "javascript",
        ".cjs" => "javascript"
      },
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
      language_ids: %{".py" => "python"},
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
      language_ids: %{".rs" => "rust"},
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
      language_ids: %{".go" => "go"},
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
      language_ids: %{
        ".c" => "c",
        ".cc" => "cpp",
        ".cpp" => "cpp",
        ".cxx" => "cpp",
        ".h" => "c",
        ".hh" => "cpp",
        ".hpp" => "cpp",
        ".hxx" => "cpp"
      },
      root_markers: ["compile_commands.json", "compile_flags.txt"],
      install_hint: "Install clangd and put it on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :tlaplus,
      label: "TLA+",
      language: :tla,
      command: "tlapm_lsp",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_TLAPLUS_COMMAND",
      extensions: [".tla", ".tlaplus"],
      language_ids: %{".tla" => "tla", ".tlaplus" => "tla"},
      root_markers: [],
      install_hint: "Install TLAPM and put tlapm_lsp on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :zls,
      label: "ZLS",
      language: :zig,
      command: "zls",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_ZLS_COMMAND",
      extensions: [".zig"],
      language_ids: %{".zig" => "zig"},
      root_markers: ["build.zig", "build.zig.zon", "zls.json"],
      install_hint: "Install ZLS and put zls on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :vscode_html_language_server,
      label: "HTML",
      language: :html,
      command: "vscode-html-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_VSCODE_HTML_LANGUAGE_SERVER_COMMAND",
      extensions: [".html", ".htm"],
      language_ids: %{".html" => "html", ".htm" => "html"},
      root_markers: ["package.json", ".git"],
      install_hint: "Install with npm install -g vscode-langservers-extracted.",
      protocol: :lsp_stdio
    },
    %{
      id: :vscode_css_language_server,
      label: "CSS",
      language: :css,
      command: "vscode-css-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_VSCODE_CSS_LANGUAGE_SERVER_COMMAND",
      extensions: [".css", ".scss", ".sass", ".less"],
      language_ids: %{".css" => "css", ".scss" => "scss", ".sass" => "sass", ".less" => "less"},
      root_markers: ["package.json", ".git"],
      install_hint: "Install with npm install -g vscode-langservers-extracted.",
      protocol: :lsp_stdio
    },
    %{
      id: :vscode_json_language_server,
      label: "JSON",
      language: :json,
      command: "vscode-json-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_VSCODE_JSON_LANGUAGE_SERVER_COMMAND",
      extensions: [".json", ".jsonc"],
      language_ids: %{".json" => "json", ".jsonc" => "jsonc"},
      root_markers: ["package.json", ".git"],
      install_hint: "Install with npm install -g vscode-langservers-extracted.",
      protocol: :lsp_stdio
    },
    %{
      id: :svelte,
      label: "Svelte",
      language: :svelte,
      command: "svelteserver",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_SVELTE_COMMAND",
      extensions: [".svelte"],
      language_ids: %{".svelte" => "svelte"},
      root_markers: ["svelte.config.js", "svelte.config.mjs", "package.json"],
      install_hint: "Install with npm install -g svelte-language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :vue_language_server,
      label: "Vue",
      language: :vue,
      command: "vue-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_VUE_LANGUAGE_SERVER_COMMAND",
      extensions: [".vue"],
      language_ids: %{".vue" => "vue"},
      root_markers: ["vue.config.js", "nuxt.config.js", "nuxt.config.ts", "package.json"],
      install_hint: "Install with npm install -g @vue/language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :astro,
      label: "Astro",
      language: :astro,
      command: "astro-ls",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_ASTRO_COMMAND",
      extensions: [".astro"],
      language_ids: %{".astro" => "astro"},
      root_markers: ["astro.config.mjs", "astro.config.js", "astro.config.ts"],
      install_hint: "Install with npm install -g @astrojs/language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :jdtls,
      label: "Eclipse JDT LS",
      language: :java,
      command: "jdtls",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_JDTLS_COMMAND",
      extensions: [".java"],
      language_ids: %{".java" => "java"},
      root_markers: ["pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", ".project"],
      install_hint: "Install Eclipse JDT LS and put jdtls on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :kotlin_lsp,
      label: "Kotlin LSP",
      language: :kotlin,
      command: "kotlin-lsp",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_KOTLIN_LSP_COMMAND",
      extensions: [".kt", ".kts"],
      language_ids: %{".kt" => "kotlin", ".kts" => "kotlin"},
      root_markers: [
        "build.gradle",
        "build.gradle.kts",
        "pom.xml",
        "settings.gradle",
        "settings.gradle.kts"
      ],
      install_hint: "Install JetBrains kotlin-lsp and put kotlin-lsp on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :metals,
      label: "Metals",
      language: :scala,
      command: "metals",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_METALS_COMMAND",
      extensions: [".scala", ".sbt", ".sc"],
      language_ids: %{".scala" => "scala", ".sbt" => "scala", ".sc" => "scala"},
      root_markers: ["build.sbt", "build.sc", "build.gradle", "pom.xml"],
      install_hint: "Install Metals with Coursier: cs install metals.",
      protocol: :lsp_stdio
    },
    %{
      id: :hls,
      label: "Haskell Language Server",
      language: :haskell,
      command: "haskell-language-server-wrapper",
      args: ["--lsp"],
      alternatives: [],
      command_env: "LEMON_LSP_HLS_COMMAND",
      extensions: [".hs", ".lhs"],
      language_ids: %{".hs" => "haskell", ".lhs" => "literate haskell"},
      root_markers: ["stack.yaml", "cabal.project", "hie.yaml", "package.yaml"],
      install_hint: "Install Haskell Language Server with ghcup install hls.",
      protocol: :lsp_stdio
    },
    %{
      id: :ocamllsp,
      label: "OCaml LSP",
      language: :ocaml,
      command: "ocamllsp",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_OCAMLLSP_COMMAND",
      extensions: [".ml", ".mli", ".mll", ".mly"],
      language_ids: %{
        ".ml" => "ocaml",
        ".mli" => "ocaml",
        ".mll" => "ocamllex",
        ".mly" => "menhir"
      },
      root_markers: ["dune-project", "dune-workspace", ".ocamlformat"],
      install_hint: "Install with opam install ocaml-lsp-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :erlangls,
      label: "Erlang LS",
      language: :erlang,
      command: "erlang_ls",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_ERLANGLS_COMMAND",
      extensions: [".erl", ".hrl"],
      language_ids: %{".erl" => "erlang", ".hrl" => "erlang"},
      root_markers: ["rebar.config", "erlang.mk", "rebar.lock"],
      install_hint: "Install Erlang LS and put erlang_ls on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :gleam,
      label: "Gleam",
      language: :gleam,
      command: "gleam",
      args: ["lsp"],
      alternatives: [],
      command_env: "LEMON_LSP_GLEAM_COMMAND",
      extensions: [".gleam"],
      language_ids: %{".gleam" => "gleam"},
      root_markers: ["gleam.toml"],
      install_hint: "Install Gleam and put gleam on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :ruby_lsp,
      label: "Ruby LSP",
      language: :ruby,
      command: "ruby-lsp",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_RUBY_LSP_COMMAND",
      extensions: [".rb", ".rake", ".gemspec", ".erb"],
      language_ids: %{".rb" => "ruby", ".rake" => "ruby", ".gemspec" => "ruby", ".erb" => "erb"},
      root_markers: ["Gemfile", ".ruby-version", ".ruby-gemset"],
      install_hint: "Install with gem install ruby-lsp.",
      protocol: :lsp_stdio
    },
    %{
      id: :bashls,
      label: "Bash Language Server",
      language: :shellscript,
      command: "bash-language-server",
      args: ["start"],
      alternatives: [],
      command_env: "LEMON_LSP_BASHLS_COMMAND",
      extensions: [".sh", ".bash", ".zsh"],
      language_ids: %{".sh" => "shellscript", ".bash" => "shellscript", ".zsh" => "shellscript"},
      root_markers: [".git"],
      install_hint: "Install with npm install -g bash-language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :lua_language_server,
      label: "Lua Language Server",
      language: :lua,
      command: "lua-language-server",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_LUA_LANGUAGE_SERVER_COMMAND",
      extensions: [".lua"],
      language_ids: %{".lua" => "lua"},
      root_markers: [".luarc.json", ".luarc.jsonc", ".luacheckrc", ".stylua.toml", "stylua.toml"],
      install_hint: "Install lua-language-server and put it on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :intelephense,
      label: "Intelephense",
      language: :php,
      command: "intelephense",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_INTELEPHENSE_COMMAND",
      extensions: [".php", ".phtml"],
      language_ids: %{".php" => "php", ".phtml" => "php"},
      root_markers: ["composer.json", "composer.lock", ".git"],
      install_hint: "Install with npm install -g intelephense.",
      protocol: :lsp_stdio
    },
    %{
      id: :yamlls,
      label: "YAML Language Server",
      language: :yaml,
      command: "yaml-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_YAMLLS_COMMAND",
      extensions: [".yaml", ".yml"],
      language_ids: %{".yaml" => "yaml", ".yml" => "yaml"},
      root_markers: [".git"],
      install_hint: "Install with npm install -g yaml-language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :terraformls,
      label: "Terraform LS",
      language: :terraform,
      command: "terraform-ls",
      args: ["serve"],
      alternatives: [],
      command_env: "LEMON_LSP_TERRAFORMLS_COMMAND",
      extensions: [".tf", ".tfvars"],
      language_ids: %{".tf" => "terraform", ".tfvars" => "terraform-vars"},
      root_markers: [".terraform", "terraform.tfstate"],
      install_hint: "Install HashiCorp terraform-ls and put it on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :dockerls,
      label: "Dockerfile Language Server",
      language: :dockerfile,
      command: "docker-langserver",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_DOCKERLS_COMMAND",
      extensions: [".dockerfile"],
      language_ids: %{".dockerfile" => "dockerfile"},
      root_markers: ["Dockerfile", "docker-compose.yml", "docker-compose.yaml", ".dockerignore"],
      install_hint: "Install with npm install -g dockerfile-language-server-nodejs.",
      protocol: :lsp_stdio
    },
    %{
      id: :nixd,
      label: "nixd",
      language: :nix,
      command: "nixd",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_NIXD_COMMAND",
      extensions: [".nix"],
      language_ids: %{".nix" => "nix"},
      root_markers: ["flake.nix", "default.nix", "shell.nix"],
      install_hint: "Install with nix profile install nixpkgs#nixd.",
      protocol: :lsp_stdio
    },
    %{
      id: :ols,
      label: "Odin Language Server",
      language: :odin,
      command: "ols",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_OLS_COMMAND",
      extensions: [".odin"],
      language_ids: %{".odin" => "odin"},
      root_markers: ["ols.json", ".git"],
      install_hint: "Install OLS and put ols on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :dartls,
      label: "Dart Analysis Server",
      language: :dart,
      command: "dart",
      args: ["language-server", "--protocol=lsp"],
      alternatives: [],
      command_env: "LEMON_LSP_DARTLS_COMMAND",
      extensions: [".dart"],
      language_ids: %{".dart" => "dart"},
      root_markers: ["pubspec.yaml", "pubspec.lock"],
      install_hint: "Install the Dart SDK and put dart on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :marksman,
      label: "Marksman",
      language: :markdown,
      command: "marksman",
      args: ["server"],
      alternatives: [],
      command_env: "LEMON_LSP_MARKSMAN_COMMAND",
      extensions: [".md", ".markdown"],
      language_ids: %{".md" => "markdown", ".markdown" => "markdown"},
      root_markers: [".marksman.toml", ".git"],
      install_hint: "Install Marksman and put marksman on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :texlab,
      label: "Texlab",
      language: :latex,
      command: "texlab",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_TEXLAB_COMMAND",
      extensions: [".tex", ".bib", ".sty", ".cls"],
      language_ids: %{".tex" => "latex", ".bib" => "bibtex", ".sty" => "latex", ".cls" => "latex"},
      root_markers: [".latexmkrc", "latexmkrc", ".texlabroot", "texlabroot", "Tectonic.toml"],
      install_hint: "Install Texlab and put texlab on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :graphql,
      label: "GraphQL Language Server",
      language: :graphql,
      command: "graphql-lsp",
      args: ["server", "-m", "stream"],
      alternatives: [],
      command_env: "LEMON_LSP_GRAPHQL_COMMAND",
      extensions: [".graphql", ".gql"],
      language_ids: %{".graphql" => "graphql", ".gql" => "graphql"},
      root_markers: [
        ".graphqlrc",
        ".graphqlrc.json",
        ".graphqlrc.yml",
        ".graphqlrc.yaml",
        "graphql.config.js"
      ],
      install_hint: "Install with npm install -g graphql-language-service-cli.",
      protocol: :lsp_stdio
    },
    %{
      id: :prismals,
      label: "Prisma Language Server",
      language: :prisma,
      command: "prisma-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_PRISMALS_COMMAND",
      extensions: [".prisma"],
      language_ids: %{".prisma" => "prisma"},
      root_markers: ["schema.prisma", "prisma/schema.prisma"],
      install_hint: "Install with npm install -g @prisma/language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :vimls,
      label: "Vim Language Server",
      language: :vim,
      command: "vim-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_VIMLS_COMMAND",
      extensions: [".vim", ".vimrc"],
      language_ids: %{".vim" => "vim", ".vimrc" => "vim"},
      root_markers: [".git"],
      install_hint: "Install with npm install -g vim-language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :sourcekit_lsp,
      label: "SourceKit-LSP",
      language: :swift,
      command: "sourcekit-lsp",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_SOURCEKIT_LSP_COMMAND",
      extensions: [".swift"],
      language_ids: %{".swift" => "swift"},
      root_markers: ["Package.swift", "project.yml", ".swiftpm"],
      install_hint: "Install the Swift toolchain and put sourcekit-lsp on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :csharp_ls,
      label: "C# Language Server",
      language: :csharp,
      command: "csharp-ls",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_CSHARP_LS_COMMAND",
      extensions: [".cs", ".csx"],
      language_ids: %{".cs" => "csharp", ".csx" => "csharp"},
      root_markers: [".git"],
      install_hint: "Install with dotnet tool install --global csharp-ls.",
      protocol: :lsp_stdio
    },
    %{
      id: :taplo,
      label: "Taplo",
      language: :toml,
      command: "taplo",
      args: ["lsp", "stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_TAPLO_COMMAND",
      extensions: [".toml"],
      language_ids: %{".toml" => "toml"},
      root_markers: ["taplo.toml", ".taplo.toml", ".git"],
      install_hint: "Install with cargo install taplo-cli --locked --features lsp.",
      protocol: :lsp_stdio
    },
    %{
      id: :elm,
      label: "Elm Language Server",
      language: :elm,
      command: "elm-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_ELM_COMMAND",
      extensions: [".elm"],
      language_ids: %{".elm" => "elm"},
      root_markers: ["elm.json"],
      install_hint: "Install with npm install -g @elm-tooling/elm-language-server.",
      protocol: :lsp_stdio
    },
    %{
      id: :clojure_lsp,
      label: "Clojure LSP",
      language: :clojure,
      command: "clojure-lsp",
      args: [],
      alternatives: [],
      command_env: "LEMON_LSP_CLOJURE_LSP_COMMAND",
      extensions: [".clj", ".cljs", ".cljc", ".edn"],
      language_ids: %{
        ".clj" => "clojure",
        ".cljs" => "clojure",
        ".cljc" => "clojure",
        ".edn" => "clojure"
      },
      root_markers: ["deps.edn", "project.clj", "bb.edn"],
      install_hint: "Install clojure-lsp and put it on PATH.",
      protocol: :lsp_stdio
    },
    %{
      id: :solidity,
      label: "Solidity Language Server",
      language: :solidity,
      command: "nomicfoundation-solidity-language-server",
      args: ["--stdio"],
      alternatives: [],
      command_env: "LEMON_LSP_SOLIDITY_COMMAND",
      extensions: [".sol"],
      language_ids: %{".sol" => "solidity"},
      root_markers: ["foundry.toml", "hardhat.config.js", "hardhat.config.ts"],
      install_hint: "Install with npm install -g @nomicfoundation/solidity-language-server.",
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
  Return the owning server's LSP language id, or "plaintext" for unknown extensions.
  """
  @spec language_id(String.t()) :: String.t()
  def language_id(path) do
    extension = path |> Path.extname() |> String.downcase()

    Enum.find_value(@servers, "plaintext", &Map.get(&1.language_ids, extension))
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
      language_ids: server.language_ids,
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
