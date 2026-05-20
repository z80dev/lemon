Application.ensure_all_started(:lemon_core)

defmodule LemonScripts.LiveLspServerSmoke do
  alias LemonCore.LspServerManager
  alias LemonCore.LspServers

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          out: :string,
          servers: :string,
          timeout_ms: :integer,
          editor_flow: :boolean,
          fixture_profile: :string,
          project_fixtures: :boolean,
          real_repo_fixtures: :boolean
        ]
      )

    project_dir = File.cwd!()

    proof_path =
      opts[:out] || Path.join([project_dir, ".lemon", "proofs", "lsp-server-smoke-latest.json"])

    archive_path = archive_path(proof_path)
    timeout_ms = opts[:timeout_ms] || 10_000
    server_ids = server_ids(opts[:servers])
    editor_flow? = Keyword.get(opts, :editor_flow, false)
    fixture_profile = fixture_profile(opts)

    results = Enum.map(server_ids, &run_server(&1, timeout_ms, editor_flow?, fixture_profile))
    completed_count = Enum.count(results, &(&1.status == "completed"))
    skipped_count = Enum.count(results, &(&1.status == "skipped"))
    failed_count = Enum.count(results, &(&1.status == "failed"))
    proof_scope = proof_scope(fixture_profile)

    proof = %{
      status: proof_status(completed_count, skipped_count, failed_count),
      proof: proof_scope,
      proof_scope: proof_scope,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      registry: registry_summary(),
      requested_servers: server_ids,
      editor_flow: editor_flow?,
      fixture_profile: fixture_profile,
      results: results,
      checks: proof_checks(results, proof_scope, editor_flow?),
      completed_count: completed_count,
      skipped_count: skipped_count,
      failed_count: failed_count,
      cleanup: %{
        includes_raw_paths: false,
        includes_file_contents: false,
        includes_diagnostics_output: false,
        includes_raw_session_ids: false,
        includes_server_io: false
      }
    }

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)

    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0 do
      System.halt(1)
    end
  end

  defp run_server(server_id, timeout_ms, editor_flow?, fixture_profile) do
    case LspServers.resolve_command(server_id) do
      {:ok, command} ->
        run_resolved_server(
          command,
          server_fixture(command.server.id, fixture_profile),
          timeout_ms,
          editor_flow?
        )

      {:error, :command_unavailable} ->
        %{server_id: server_id, status: "skipped", reason: "language server unavailable"}

      {:error, reason} ->
        failed(server_id, reason)
    end
  end

  defp run_resolved_server(command, fixture, timeout_ms, editor_flow?) do
    root =
      Path.join(
        System.tmp_dir!(),
        "lemon_lsp_#{command.server.id}_smoke_#{System.unique_integer([:positive])}"
      )

    session_id = "lsp-smoke-#{command.server.id}-#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)

    fixture_meta = fixture.prepare.(root)
    path = Path.join(root, fixture.path)
    File.write!(path, fixture.text)

    uri = "file://" <> path
    root_uri = "file://" <> root

    try do
      with {:ok, session} <-
             LspServerManager.start_session(command.server.id, cwd: root, session_id: session_id),
           {:ok, _response} <- initialize(session_id, root_uri, timeout_ms),
           {:ok, document} <-
             LspServerManager.open_document(
               session_id,
               uri,
               fixture.language_id,
               File.read!(path),
               version: 1
             ),
           {:ok, active} <-
             wait_for_diagnostics(session_id, session.session_hash, uri, timeout_ms),
           {:ok, changed} <-
             LspServerManager.change_document(session_id, uri, fixture.fixed_text, version: 2),
           {:ok, clean} <-
             wait_for_clean_diagnostics(session_id, session.session_hash, uri, active, timeout_ms),
           {:ok, editor_flow} <-
             maybe_run_editor_flow(
               editor_flow?,
               session_id,
               session.session_hash,
               uri,
               fixture,
               clean,
               timeout_ms
             ) do
        latest = clean.last_diagnostics |> List.first(%{})

        %{
          server_id: command.server.id,
          status: "completed",
          command: command.command,
          session_hash: session.session_hash,
          cwd_hash: session.cwd_hash,
          document_uri_hash: document.uri_hash,
          initialized: active.initialized,
          request_count: clean.request_count,
          response_count: clean.response_count,
          notification_count: clean.notification_count,
          diagnostic_count: clean.diagnostic_count,
          diagnostic_batch_count: clean.diagnostic_batch_count,
          initial_diagnostic_count:
            active.last_diagnostics |> List.first(%{}) |> Map.get(:diagnostic_count, 0),
          latest_diagnostic_count: Map.get(latest, :diagnostic_count, 0),
          clean_after_change: Map.get(latest, :diagnostic_count, 0) == 0,
          document_change_count: Map.get(changed, :change_count, 0),
          severities: Map.get(latest, :severities, %{}),
          fixture: fixture_meta
        }
        |> Map.merge(editor_flow)
      else
        {:error, reason} -> failed(command.server.id, reason)
      end
    after
      _ = LspServerManager.stop_session(session_id)
      File.rm_rf!(root)
    end
  rescue
    error ->
      failed(command.server.id, Exception.message(error))
  end

  defp server_fixture(:pyright, :basic) do
    %{
      path: "bad.py",
      language_id: "python",
      text: "def broken(:\n",
      fixed_text: "def fixed():\n    return 1\n",
      prepare: fn _root -> %{file_count: 1, root_marker_count: 0, companion_file_count: 0} end
    }
  end

  defp server_fixture(:pyright, :project) do
    %{
      path: "src/app.py",
      language_id: "python",
      text: "from helper import value\n\ndef broken(:\n",
      fixed_text: "from helper import value\n\ndef fixed():\n    return value()\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))

        File.write!(
          Path.join(root, "pyproject.toml"),
          "[project]\nname = \"lemon-lsp-smoke\"\nversion = \"0.1.0\"\n"
        )

        File.write!(Path.join([root, "src", "helper.py"]), "def value():\n    return 1\n")
        %{file_count: 3, root_marker_count: 1, companion_file_count: 1}
      end
    }
  end

  defp server_fixture(:pyright, :real_repo) do
    source_file = "clients/lemon-cli/src/lemon_cli/theme.py"
    fixed_text = repo_file!(source_file)

    %{
      path: "lemon_cli/theme.py",
      language_id: "python",
      text:
        String.replace(
          fixed_text,
          "def get_theme(name: str) -> ThemeColors | None:\n",
          "def get_theme(name: str -> ThemeColors | None:\n",
          global: false
        ),
      fixed_text: fixed_text,
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "lemon_cli"))

        File.write!(
          Path.join(root, "pyproject.toml"),
          "[project]\nname = \"lemon-lsp-real-repo-python\"\nversion = \"0.1.0\"\n"
        )

        %{
          file_count: 2,
          root_marker_count: 1,
          companion_file_count: 0,
          real_repo_fixture: true,
          source_file: source_file,
          source_hash: content_hash(fixed_text)
        }
      end
    }
  end

  defp server_fixture(:typescript_language_server, :basic) do
    %{
      path: "src/bad.ts",
      language_id: "typescript",
      text: "function broken( {\n",
      fixed_text: "function fixed(): number { return 1; }\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))
        File.write!(Path.join(root, "package.json"), ~s({"private":true}\n))
        File.write!(Path.join(root, "tsconfig.json"), ~s({"compilerOptions":{"strict":true}}\n))
        %{file_count: 3, root_marker_count: 2, companion_file_count: 0}
      end
    }
  end

  defp server_fixture(:typescript_language_server, :project) do
    %{
      path: "src/app.ts",
      language_id: "typescript",
      text:
        "import { value } from './helper';\nconst result: number = value();\nfunction broken( {\n",
      fixed_text:
        "import { value } from './helper';\nconst result: number = value();\nexport function fixed(): number { return result; }\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))
        File.write!(Path.join(root, "package.json"), ~s({"private":true,"type":"module"}\n))

        File.write!(
          Path.join(root, "tsconfig.json"),
          ~s({"compilerOptions":{"strict":true,"moduleResolution":"node","target":"es2022"},"include":["src/**/*.ts"]}\n)
        )

        File.write!(
          Path.join([root, "src", "helper.ts"]),
          "export function value(): number { return 1; }\n"
        )

        %{file_count: 4, root_marker_count: 2, companion_file_count: 1}
      end
    }
  end

  defp server_fixture(:typescript_language_server, :real_repo) do
    fixed_text = repo_file!("clients/lemon-tui/src/theme.ts")

    %{
      path: "src/theme.ts",
      language_id: "typescript",
      text: "export const brokenTheme = ;\n" <> fixed_text,
      fixed_text: fixed_text,
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))
        File.write!(Path.join(root, "package.json"), ~s({"private":true,"type":"module"}\n))

        File.write!(
          Path.join(root, "tsconfig.json"),
          ~s({"compilerOptions":{"strict":true,"target":"es2022","module":"esnext"},"include":["src/**/*.ts"]}\n)
        )

        %{
          file_count: 3,
          root_marker_count: 2,
          companion_file_count: 0,
          real_repo_fixture: true,
          source_file: "clients/lemon-tui/src/theme.ts",
          source_hash: content_hash(fixed_text)
        }
      end
    }
  end

  defp server_fixture(:gopls, :basic) do
    %{
      path: "main.go",
      language_id: "go",
      text: "package main\nfunc main() { var x string = 42 }\n",
      fixed_text: "package main\nfunc main() { var x string = \"ok\"; _ = x }\n",
      prepare: fn root ->
        File.write!(Path.join(root, "go.mod"), "module lemonlspsmoke\n\ngo 1.22\n")
        %{file_count: 2, root_marker_count: 1, companion_file_count: 0}
      end
    }
  end

  defp server_fixture(:gopls, :project) do
    %{
      path: "main.go",
      language_id: "go",
      text: "package main\nfunc main() { var x int = helperValue() }\n",
      fixed_text: "package main\nfunc main() { var x string = helperValue(); _ = x }\n",
      prepare: fn root ->
        File.write!(Path.join(root, "go.mod"), "module lemonlspsmoke\n\ngo 1.22\n")

        File.write!(
          Path.join(root, "helper.go"),
          "package main\nfunc helperValue() string { return \"ok\" }\n"
        )

        %{file_count: 3, root_marker_count: 1, companion_file_count: 1}
      end
    }
  end

  defp server_fixture(:gopls, :real_repo) do
    source_file = "scripts/fixtures/lsp/real_repo/go/main.go"
    fixed_text = repo_file!(source_file)

    %{
      path: "main.go",
      language_id: "go",
      text:
        String.replace(
          fixed_text,
          "fmt.Println(lemonStatus())",
          "var status int = lemonStatus()\n\tfmt.Println(status)",
          global: false
        ),
      fixed_text: fixed_text,
      prepare: fn root ->
        File.write!(Path.join(root, "go.mod"), "module lemonlspsmokerealrepo\n\ngo 1.22\n")

        %{
          file_count: 2,
          root_marker_count: 1,
          companion_file_count: 0,
          real_repo_fixture: true,
          source_file: source_file,
          source_hash: content_hash(fixed_text)
        }
      end
    }
  end

  defp server_fixture(:rust_analyzer, :basic) do
    %{
      path: "src/main.rs",
      language_id: "rust",
      text: "fn main() { let value: String = 42; }\n",
      fixed_text: "fn main() { let value: String = \"ok\".to_string(); let _ = value; }\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))

        File.write!(
          Path.join(root, "Cargo.toml"),
          "[package]\nname = \"lemon_lsp_smoke\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"
        )

        %{file_count: 2, root_marker_count: 1, companion_file_count: 0}
      end
    }
  end

  defp server_fixture(:rust_analyzer, :project) do
    %{
      path: "src/main.rs",
      language_id: "rust",
      text: "mod helper;\nfn main() { let value: i32 = helper::value(); let _ = value; }\n",
      fixed_text:
        "mod helper;\nfn main() { let value: String = helper::value(); let _ = value; }\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))

        File.write!(
          Path.join(root, "Cargo.toml"),
          "[package]\nname = \"lemon_lsp_smoke\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"
        )

        File.write!(
          Path.join([root, "src", "helper.rs"]),
          "pub fn value() -> String { \"ok\".to_string() }\n"
        )

        %{file_count: 3, root_marker_count: 1, companion_file_count: 1}
      end
    }
  end

  defp server_fixture(:rust_analyzer, :real_repo) do
    source_file = "native/lemon-wasm-runtime/src/protocol.rs"
    fixed_text = repo_file!(source_file)

    %{
      path: "src/lib.rs",
      language_id: "rust",
      text:
        String.replace(
          fixed_text,
          "pub enum Request {\n",
          "pub enum Request {\n    Broken { value: },\n",
          global: false
        ),
      fixed_text: fixed_text,
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "src"))

        File.write!(
          Path.join(root, "Cargo.toml"),
          """
          [package]
          name = "lemon_lsp_real_repo_rust"
          version = "0.1.0"
          edition = "2024"

          [dependencies]
          serde = { version = "1", features = ["derive"] }
          serde_json = "1"
          """
        )

        %{
          file_count: 2,
          root_marker_count: 1,
          companion_file_count: 0,
          real_repo_fixture: true,
          source_file: source_file,
          source_hash: content_hash(fixed_text)
        }
      end
    }
  end

  defp server_fixture(:clangd, :basic) do
    %{
      path: "bad.c",
      language_id: "c",
      text: "int main(void) { int value = ; return value; }\n",
      fixed_text: "int main(void) { int value = 0; return value; }\n",
      prepare: fn root ->
        File.write!(Path.join(root, "compile_flags.txt"), "-std=c11\n")
        %{file_count: 2, root_marker_count: 1, companion_file_count: 0}
      end
    }
  end

  defp server_fixture(:clangd, :project) do
    %{
      path: "main.c",
      language_id: "c",
      text:
        "#include \"helper.h\"\nint main(void) { int value = helper_value(); return missing; }\n",
      fixed_text:
        "#include \"helper.h\"\nint main(void) { int value = helper_value(); return value; }\n",
      prepare: fn root ->
        File.write!(Path.join(root, "compile_flags.txt"), "-std=c11\n-I.\n")
        File.write!(Path.join(root, "helper.h"), "int helper_value(void);\n")
        File.write!(Path.join(root, "helper.c"), "int helper_value(void) { return 0; }\n")
        %{file_count: 4, root_marker_count: 1, companion_file_count: 2}
      end
    }
  end

  defp server_fixture(:clangd, :real_repo) do
    source_file = "scripts/fixtures/lsp/real_repo/clangd/main.c"
    fixed_text = repo_file!(source_file)

    %{
      path: "main.c",
      language_id: "c",
      text:
        String.replace(
          fixed_text,
          "return value;",
          "return missing;",
          global: false
        ),
      fixed_text: fixed_text,
      prepare: fn root ->
        File.write!(Path.join(root, "compile_flags.txt"), "-std=c11\n-I.\n")
        File.write!(Path.join(root, "helper.h"), "int helper_value(void);\n")
        File.write!(Path.join(root, "helper.c"), "int helper_value(void) { return 0; }\n")

        %{
          file_count: 4,
          root_marker_count: 1,
          companion_file_count: 2,
          real_repo_fixture: true,
          source_file: source_file,
          source_hash: content_hash(fixed_text)
        }
      end
    }
  end

  defp server_fixture(:elixir_ls, :basic) do
    %{
      path: "lib/bad.ex",
      language_id: "elixir",
      text: "defmodule Bad do\n  def broken( do\nend\n",
      fixed_text: "defmodule Bad do\n  def broken do\n    :ok\n  end\nend\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "lib"))

        File.write!(
          Path.join(root, "mix.exs"),
          """
          defmodule Smoke.MixProject do
            use Mix.Project

            def project do
              [
                app: :lemon_lsp_smoke,
                version: "0.1.0",
                elixir: "~> 1.15"
              ]
            end
          end
          """
        )

        %{file_count: 2, root_marker_count: 1, companion_file_count: 0}
      end
    }
  end

  defp server_fixture(:elixir_ls, :project) do
    %{
      path: "lib/app.ex",
      language_id: "elixir",
      text: "defmodule App do\n  def broken( do\n    Helper.value()\n  end\nend\n",
      fixed_text: "defmodule App do\n  def fixed do\n    Helper.value()\n  end\nend\n",
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "lib"))

        File.write!(
          Path.join(root, "mix.exs"),
          """
          defmodule Smoke.MixProject do
            use Mix.Project

            def project do
              [
                app: :lemon_lsp_smoke,
                version: "0.1.0",
                elixir: "~> 1.15"
              ]
            end
          end
          """
        )

        File.write!(
          Path.join([root, "lib", "helper.ex"]),
          "defmodule Helper do\n  def value, do: :ok\nend\n"
        )

        %{file_count: 3, root_marker_count: 1, companion_file_count: 1}
      end
    }
  end

  defp server_fixture(:elixir_ls, :real_repo) do
    fixed_text = repo_file!("apps/lemon_core/lib/lemon_core/event.ex")

    %{
      path: "lib/lemon_core/event.ex",
      language_id: "elixir",
      text:
        String.replace(
          fixed_text,
          "defmodule LemonCore.Event do\n",
          "defmodule LemonCore.Event do\n  def broken( do\n",
          global: false
        ),
      fixed_text: fixed_text,
      prepare: fn root ->
        File.mkdir_p!(Path.join(root, "lib/lemon_core"))

        File.write!(
          Path.join(root, "mix.exs"),
          """
          defmodule LemonRealRepoLspSmoke.MixProject do
            use Mix.Project

            def project do
              [
                app: :lemon_real_repo_lsp_smoke,
                version: "0.1.0",
                elixir: "~> 1.15"
              ]
            end
          end
          """
        )

        %{
          file_count: 2,
          root_marker_count: 1,
          companion_file_count: 0,
          real_repo_fixture: true,
          source_file: "apps/lemon_core/lib/lemon_core/event.ex",
          source_hash: content_hash(fixed_text)
        }
      end
    }
  end

  defp initialize(session_id, root_uri, timeout_ms) do
    LspServerManager.initialize_session(
      session_id,
      %{
        "processId" => nil,
        "rootUri" => root_uri,
        "capabilities" => %{
          "textDocument" => %{
            "publishDiagnostics" => %{}
          }
        },
        "workspaceFolders" => [%{"uri" => root_uri, "name" => "lsp-smoke"}]
      },
      timeout_ms: request_timeout_ms(timeout_ms)
    )
  end

  defp wait_for_diagnostics(session_id, session_hash, uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case poll_for_diagnostics(session_hash, deadline) do
      {:ok, active} ->
        {:ok, active}

      {:error, :diagnostics_timeout} ->
        with {:ok, _response} <- request_pull_diagnostics(session_id, uri, timeout_ms) do
          poll_for_diagnostics(session_hash, System.monotonic_time(:millisecond) + 1_000)
        end
    end
  end

  defp request_pull_diagnostics(session_id, uri, timeout_ms) do
    LspServerManager.request_session(
      session_id,
      "textDocument/diagnostic",
      %{"textDocument" => %{"uri" => uri}},
      timeout_ms: request_timeout_ms(timeout_ms)
    )
  end

  defp request_timeout_ms(timeout_ms), do: min(timeout_ms, 60_000)

  defp wait_for_clean_diagnostics(session_id, session_hash, uri, previous, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case poll_for_clean_diagnostics(session_hash, previous.diagnostic_batch_count, deadline) do
      {:ok, active} ->
        {:ok, active}

      {:error, :diagnostics_timeout} ->
        with {:ok, _response} <- request_pull_diagnostics(session_id, uri, timeout_ms) do
          poll_for_clean_diagnostics(
            session_hash,
            previous.diagnostic_batch_count,
            System.monotonic_time(:millisecond) + 1_000
          )
        end
    end
  end

  defp maybe_run_editor_flow(
         false,
         _session_id,
         _session_hash,
         _uri,
         _fixture,
         _clean,
         _timeout_ms
       ) do
    {:ok, %{editor_flow: false}}
  end

  defp maybe_run_editor_flow(true, session_id, session_hash, uri, fixture, clean, timeout_ms) do
    with {:ok, changed} <-
           LspServerManager.change_document(session_id, uri, fixture.text, version: 3),
         {:ok, reintroduced} <-
           wait_for_new_diagnostics(session_id, session_hash, uri, clean, timeout_ms),
         {:ok, final_changed} <-
           LspServerManager.change_document(session_id, uri, fixture.fixed_text, version: 4),
         {:ok, final_clean} <-
           wait_for_clean_diagnostics(session_id, session_hash, uri, reintroduced, timeout_ms),
         {:ok, closed} <- LspServerManager.close_document(session_id, uri) do
      reintroduced_latest = reintroduced.last_diagnostics |> List.first(%{})
      final_latest = final_clean.last_diagnostics |> List.first(%{})

      {:ok,
       %{
         editor_flow: true,
         reintroduced_diagnostic_count: Map.get(reintroduced_latest, :diagnostic_count, 0),
         final_diagnostic_count: Map.get(final_latest, :diagnostic_count, 0),
         final_clean_after_second_change: Map.get(final_latest, :diagnostic_count, 0) == 0,
         editor_flow_change_count: Map.get(final_changed, :change_count, 0),
         editor_flow_close_status: Map.get(closed, :status),
         editor_flow_document_change_count: Map.get(changed, :change_count, 0)
       }}
    end
  end

  defp wait_for_new_diagnostics(session_id, session_hash, uri, previous, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case poll_for_new_diagnostics(session_hash, previous.diagnostic_batch_count, deadline) do
      {:ok, active} ->
        {:ok, active}

      {:error, :diagnostics_timeout} ->
        with {:ok, _response} <- request_pull_diagnostics(session_id, uri, timeout_ms) do
          poll_for_new_diagnostics(
            session_hash,
            previous.diagnostic_batch_count,
            System.monotonic_time(:millisecond) + 1_000
          )
        end
    end
  end

  defp poll_for_new_diagnostics(session_hash, previous_batch_count, deadline) do
    active =
      LspServerManager.status()
      |> Map.get(:active_servers, [])
      |> Enum.find(&(&1.session_hash == session_hash))

    latest = active && List.first(active.last_diagnostics, %{})
    latest_count = latest && Map.get(latest, :diagnostic_count)

    cond do
      active && active.diagnostic_batch_count > previous_batch_count && latest_count > 0 ->
        {:ok, active}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :diagnostics_timeout}

      true ->
        Process.sleep(100)
        poll_for_new_diagnostics(session_hash, previous_batch_count, deadline)
    end
  end

  defp poll_for_clean_diagnostics(session_hash, previous_batch_count, deadline) do
    active =
      LspServerManager.status()
      |> Map.get(:active_servers, [])
      |> Enum.find(&(&1.session_hash == session_hash))

    latest = active && List.first(active.last_diagnostics, %{})
    latest_count = latest && Map.get(latest, :diagnostic_count)

    cond do
      active && active.diagnostic_batch_count > previous_batch_count && latest_count == 0 ->
        {:ok, active}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :diagnostics_timeout}

      true ->
        Process.sleep(100)
        poll_for_clean_diagnostics(session_hash, previous_batch_count, deadline)
    end
  end

  defp poll_for_diagnostics(session_hash, deadline) do
    active =
      LspServerManager.status()
      |> Map.get(:active_servers, [])
      |> Enum.find(&(&1.session_hash == session_hash))

    cond do
      active && active.diagnostic_count > 0 ->
        {:ok, active}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :diagnostics_timeout}

      true ->
        Process.sleep(100)
        poll_for_diagnostics(session_hash, deadline)
    end
  end

  defp registry_summary do
    diagnostics = LspServers.diagnostics()

    %{
      count: diagnostics.count,
      available_count: diagnostics.available_count,
      missing_count: diagnostics.missing_count,
      servers:
        Enum.map(diagnostics.servers, fn server ->
          %{
            id: server.id,
            command: server.command,
            available: server.available,
            configured: server.configured,
            protocol: server.protocol
          }
        end)
    }
  end

  defp failed(server_id, reason) do
    %{server_id: server_id, status: "failed", reason: inspect(reason)}
  end

  defp server_ids(nil), do: [:pyright]

  defp server_ids(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&normalize_server_id/1)
  end

  defp normalize_server_id(id) do
    case LspServers.validate(id) do
      {:ok, server_id} -> server_id
      {:error, _reason} -> :unknown_lsp_server
    end
  end

  defp proof_scope(:project), do: "lsp_project_fixtures_smoke"
  defp proof_scope(:real_repo), do: "lsp_real_repo_fixtures_smoke"
  defp proof_scope(:basic), do: "lsp_server_smoke"

  defp proof_status(_completed_count, _skipped_count, failed_count) when failed_count > 0,
    do: "failed"

  defp proof_status(0, skipped_count, 0) when skipped_count > 0, do: "skipped"
  defp proof_status(completed_count, _skipped_count, 0) when completed_count > 0, do: "completed"
  defp proof_status(_completed_count, _skipped_count, _failed_count), do: "unknown"

  defp proof_checks(results, proof_scope, editor_flow?) do
    Enum.map(results, fn result ->
      server_id =
        result
        |> Map.get(:server_id, :unknown_lsp_server)
        |> to_string()

      %{
        name: check_name(proof_scope, server_id, editor_flow?),
        proof_scope: proof_scope,
        status: result.status
      }
    end)
  end

  defp check_name(proof_scope, server_id, true), do: "#{proof_scope}_#{server_id}_editor_flow"
  defp check_name(proof_scope, server_id, false), do: "#{proof_scope}_#{server_id}"

  defp fixture_profile(opts) do
    cond do
      Keyword.get(opts, :real_repo_fixtures, false) ->
        :real_repo

      Keyword.get(opts, :fixture_profile) in ["real_repo", "real-repo", "repo"] ->
        :real_repo

      Keyword.get(opts, :project_fixtures, false) ->
        :project

      Keyword.get(opts, :fixture_profile) in ["project", "long"] ->
        :project

      true ->
        :basic
    end
  end

  defp archive_path(proof_path) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9A-Za-z]/, "")

    Path.join(Path.dirname(proof_path), "lsp-server-smoke-#{stamp}.json")
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value, pretty: true))
  end

  defp repo_file!(relative_path) do
    relative_path
    |> Path.expand(File.cwd!())
    |> File.read!()
  end

  defp content_hash(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

LemonScripts.LiveLspServerSmoke.main(System.argv())
