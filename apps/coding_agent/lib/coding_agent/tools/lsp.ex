defmodule CodingAgent.Tools.Lsp do
  @moduledoc """
  Model-facing language-server tool: diagnostics, navigation, symbols, rename,
  code actions and raw requests over supervised `LemonLsp` sessions.

  A server is chosen by file extension from `LemonLsp.Servers`; its workspace
  root is the nearest ancestor of the file (within the cwd) holding one of the
  server's root markers, else the cwd. Session-scoped
  `CodingAgent.Tools.Lsp.Client` leases share one initialized server per
  (server, root, configuration) through `LemonLsp.ServerManager`.

  Positions are `line` (1-based) plus `symbol` (text located on that line) or
  `column` (1-based); they are converted to LSP UTF-16 offsets. Results are
  reported as `path:line:col` relative to the cwd. `rename` and
  `code_actions` only write files with `apply: true`, through
  `CodingAgent.Tools.Lsp.WorkspaceEdit`.
  """

  alias CodingAgent.Artifacts
  alias CodingAgent.Tools.{CheckpointGuard, PathHelpers}
  alias CodingAgent.Tools.Lsp.{Client, Text, WorkspaceEdit}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Tools.AbortHelpers
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonLsp.ServerManager

  @actions ~w(diagnostics definition type_definition implementation references hover symbols rename rename_file reload capabilities code_actions status request)
  @position_actions ~w(definition type_definition implementation references hover rename code_actions)
  @default_timeout_s 20
  @reference_context_limit 50
  @reference_limit 500
  @workspace_symbol_limit 200
  @diagnostic_limit 100
  @max_output_bytes 48_000
  @excerpt_chars 200
  @diagnostics_settle_ms 250
  @code_action_diagnostics_wait_ms 5_000
  @symbol_kinds ~w(File Module Namespace Package Class Method Property Field Constructor Enum
                   Interface Function Variable Constant String Number Boolean Array Object Key
                   Null EnumMember Struct Event Operator TypeParameter)

  @description """
  Symbol-aware code intelligence from language servers: navigation, refactors and diagnostics where text search misses callsites.

  Actions:
  - Position-based (`definition`, `type_definition`, `implementation`, `references`, `hover`, `rename`, `code_actions`): `file` + `line` (1-indexed) + `symbol` (text on that line; `name#N` picks the Nth occurrence) or `column` (1-indexed).
  - `rename`: previews the edits by default; pass `apply: true` with `new_name` to write them.
  - `code_actions`: lists actions at the position (whole line without `symbol`/`column`); apply ONE with `apply: true` + `query` (index or title substring).
  - `diagnostics`: errors and warnings for `file`.
  - `rename_file`: `file` + `new_name` destination path; previews server edits and the move, writes only with `apply: true`.
  - `reload`: restart the server for `file`, or all running servers in the scope without `file`.
  - `capabilities`: advertised capabilities for the server selected by `file`.
  - `diagnostics` with `file: "*"`: bounded published diagnostics across running workspace clients.
  - `symbols`: `file` lists that file's symbols; `query` without `file` searches the workspace.
  - `status`: language servers known, installed and running for this session.
  - `request`: raw LSP call; `query` = method, `payload` = JSON params (else built from file/line/symbol).

  Use `lsp` rename/references/definition for symbol-aware work when a server is available; text replacement silently misses shadowed or cross-file usages.
  """

  @doc "Returns the `lsp` tool definition."
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "lsp",
      description: String.trim(@description),
      label: "LSP",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => @actions, "description" => "LSP operation"},
          "file" => %{
            "type" => "string",
            "description" => "File path relative to cwd or absolute"
          },
          "line" => %{"type" => "integer", "description" => "1-indexed line for position actions"},
          "symbol" => %{
            "type" => "string",
            "description" => "Text on `line` to position at; `name#N` for the Nth occurrence"
          },
          "column" => %{
            "type" => "integer",
            "description" => "1-indexed column when `symbol` is not given"
          },
          "query" => %{
            "type" => "string",
            "description" =>
              "Workspace symbol query, code action index/title to apply, or method for `request`"
          },
          "new_name" => %{
            "type" => "string",
            "description" => "New symbol name for `rename` or destination path for `rename_file`"
          },
          "apply" => %{
            "type" => "boolean",
            "description" =>
              "Write `rename`/`rename_file`/`code_actions` edits to disk (default false: preview)"
          },
          "timeout" => %{
            "type" => "number",
            "description" => "Timeout in seconds (default 20, clamped to 5..300)"
          },
          "payload" => %{
            "type" => "string",
            "description" => "JSON params for `request`"
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc "Execute an `lsp` action."
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with :ok <- check_abort(signal),
         {:ok, req} <- validate(params) do
      cwd = Path.expand(cwd)
      timeout_ms = req.timeout * 1_000

      ctx = %{
        cwd: cwd,
        opts: opts,
        signal: signal,
        req: req,
        timeout_ms: timeout_ms,
        deadline: System.monotonic_time(:millisecond) + timeout_ms,
        scope: scope(cwd, opts)
      }

      case run(req.action, ctx) do
        {:ok, text, details} ->
          text
          |> result(Map.merge(%{action: req.action, success: true}, details), ctx)
          |> ToolResultTrust.untrusted(:local_search)

        {:error, :session_lost} ->
          {:error, "The language server exited unexpectedly; retry the request"}

        {:partial_error, reason, details} ->
          reason
          |> result(Map.merge(%{action: req.action, success: false}, details), ctx)
          |> ToolResultTrust.untrusted(:local_search)

        {:error, reason} when is_binary(reason) ->
          {:error, reason}
      end
    end
  end

  # -- Parameters -------------------------------------------------------------

  defp validate(params) when is_map(params) do
    with {:ok, action} <- action(params["action"]),
         {:ok, file} <- optional_string(params, "file"),
         {:ok, line} <- optional_positive(params, "line"),
         {:ok, column} <- optional_positive(params, "column"),
         {:ok, symbol} <- optional_string(params, "symbol"),
         {:ok, query} <- optional_string(params, "query"),
         {:ok, new_name} <- optional_string(params, "new_name"),
         {:ok, apply?} <- boolean(params, "apply"),
         {:ok, timeout} <- timeout(params["timeout"]),
         {:ok, payload} <- payload(params["payload"]) do
      req = %{
        action: action,
        file: file,
        line: line,
        column: column,
        symbol: symbol,
        query: query,
        new_name: new_name,
        apply: apply?,
        timeout: timeout,
        payload: payload
      }

      check_required(req)
    end
  end

  defp validate(_params), do: {:error, "Parameters must be an object"}

  defp action(action) when is_binary(action) do
    action = action |> String.trim() |> String.downcase()

    if action in @actions,
      do: {:ok, action},
      else:
        {:error,
         "Unknown action #{inspect(action)}; expected one of: #{Enum.join(@actions, ", ")}"}
  end

  defp action(_action), do: {:error, "action is required (one of: #{Enum.join(@actions, ", ")})"}

  defp optional_string(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, if(String.trim(value) == "", do: nil, else: value)}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp optional_positive(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_float(value) and value >= 1 and trunc(value) == value ->
        {:ok, trunc(value)}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, ""} when n > 0 -> {:ok, n}
          _ -> {:error, "#{key} must be a positive integer"}
        end

      _ ->
        {:error, "#{key} must be a positive integer"}
    end
  end

  defp boolean(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a boolean"}
    end
  end

  defp timeout(nil), do: {:ok, @default_timeout_s}
  defp timeout(value) when is_number(value), do: {:ok, value |> round() |> max(5) |> min(300)}

  defp timeout(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> timeout(number)
      _ -> {:error, "timeout must be a number of seconds"}
    end
  end

  defp timeout(_value), do: {:error, "timeout must be a number of seconds"}

  defp payload(nil), do: {:ok, nil}
  defp payload(value) when is_map(value) or is_list(value), do: {:ok, value}

  defp payload(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) or is_nil(decoded) -> {:ok, decoded}
      {:ok, _scalar} -> {:error, "payload must be a JSON object or array"}
      {:error, error} -> {:error, "Invalid JSON in payload: #{Exception.message(error)}"}
    end
  end

  defp payload(_value), do: {:error, "payload must be a JSON string"}

  defp check_required(%{action: action} = req) when action in @position_actions do
    cond do
      is_nil(req.file) ->
        {:error, "#{action} requires `file`"}

      is_nil(req.line) ->
        {:error, "#{action} requires `line` (1-indexed)"}

      action == "rename" and is_nil(req.new_name) ->
        {:error, "rename requires `new_name`"}

      action == "code_actions" and req.apply and is_nil(req.query) ->
        {:error, "Applying a code action requires `query` (action index or title substring)"}

      true ->
        {:ok, req}
    end
  end

  defp check_required(%{action: "diagnostics", file: nil}),
    do: {:error, "diagnostics requires `file` (use `*` for the workspace)"}

  defp check_required(%{action: action, file: nil})
       when action in ["rename_file", "capabilities"],
       do: {:error, "#{action} requires `file`"}

  defp check_required(%{action: "rename_file", new_name: nil}),
    do: {:error, "rename_file requires `new_name` (destination path)"}

  defp check_required(%{action: "symbols", file: nil, query: nil}),
    do: {:error, "symbols requires `file` (document symbols) or `query` (workspace symbols)"}

  defp check_required(%{action: "request", query: nil}),
    do: {:error, "request requires `query` with the LSP method name (e.g. textDocument/hover)"}

  defp check_required(req), do: {:ok, req}

  # -- Actions ----------------------------------------------------------------

  defp run("status", ctx), do: status(ctx)
  defp run("rename_file", ctx), do: rename_file(ctx)
  defp run("reload", ctx), do: reload(ctx)
  defp run("capabilities", ctx), do: capabilities(ctx)
  defp run("diagnostics", ctx), do: diagnostics(ctx)
  defp run("definition", ctx), do: locations(ctx, "textDocument/definition", "definition")

  defp run("type_definition", ctx),
    do: locations(ctx, "textDocument/typeDefinition", "type definition")

  defp run("implementation", ctx),
    do: locations(ctx, "textDocument/implementation", "implementation")

  defp run("references", ctx), do: references(ctx)
  defp run("hover", ctx), do: hover(ctx)
  defp run("symbols", %{req: %{file: nil}} = ctx), do: workspace_symbols(ctx)
  defp run("symbols", ctx), do: document_symbols(ctx)
  defp run("rename", ctx), do: rename(ctx)
  defp run("code_actions", ctx), do: code_actions(ctx)
  defp run("request", ctx), do: raw_request(ctx)

  defp status(ctx) do
    running = Enum.group_by(current_clients(ctx), & &1.server_id)

    lines =
      Enum.map(LemonLsp.Servers.list(ctx.cwd), fn server ->
        exts = Enum.join(server.extensions, " ")

        state =
          cond do
            roots = running[server.id] ->
              "running (workspace: #{Enum.map_join(roots, ", ", &Text.display_path(&1.root, ctx.cwd))})"

            server.available ->
              "installed, not started"

            true ->
              "not installed: #{server.install_hint} (or set #{server.command_env})"
          end

        "  #{server.id} — #{server.label} [#{exts}]: #{state}"
      end)

    text =
      "Language servers for this session:\n" <>
        Enum.join(lines, "\n") <>
        "\n  note: servers start on first use for a matching file and stop when the session ends."

    {:ok, text,
     %{
       servers:
         Enum.map(LemonLsp.Servers.list(ctx.cwd), fn server ->
           %{
             id: server.id,
             available: server.available,
             running: Map.has_key?(running, server.id)
           }
         end)
     }}
  end

  defp locations(ctx, method, noun) do
    with_position(ctx, fn conn, position, _content ->
      with {:ok, result} <- request(ctx, conn, method, position_params(conn, position)) do
        locations = normalize_locations(result)

        text =
          if locations == [] do
            "No #{noun} found"
          else
            "Found #{length(locations)} #{noun}(s):\n" <>
              Enum.join(format_locations(locations, ctx.cwd, true), "\n")
          end

        {:ok, text, %{server: to_string(conn.server.id), count: length(locations)}}
      end
    end)
  end

  defp references(ctx) do
    with_position(ctx, fn conn, position, _content ->
      params =
        conn
        |> position_params(position)
        |> Map.put("context", %{"includeDeclaration" => true})

      with {:ok, result} <- request(ctx, conn, "textDocument/references", params) do
        locations = normalize_locations(result)
        total = length(locations)
        {contextual, rest} = Enum.split(locations, @reference_context_limit)
        {plain, hidden} = Enum.split(rest, @reference_limit - @reference_context_limit)

        text =
          cond do
            total == 0 ->
              "No references found"

            true ->
              [
                "Found #{total} reference(s):",
                format_locations(contextual, ctx.cwd, true),
                if(plain != [],
                  do: "  ... #{length(plain)} additional reference(s) shown without context"
                ),
                format_locations(plain, ctx.cwd, false),
                if(hidden != [], do: "  ... #{length(hidden)} more reference(s) not shown")
              ]
              |> List.flatten()
              |> Enum.reject(&is_nil/1)
              |> Enum.join("\n")
          end

        {:ok, text, %{server: to_string(conn.server.id), count: total}}
      end
    end)
  end

  defp hover(ctx) do
    with_position(ctx, fn conn, position, _content ->
      with {:ok, result} <-
             request(ctx, conn, "textDocument/hover", position_params(conn, position)) do
        text =
          case result do
            %{"contents" => contents} ->
              case hover_text(contents) |> String.trim() do
                "" -> "No hover information"
                text -> text
              end

            _ ->
              "No hover information"
          end

        {:ok, text, %{server: to_string(conn.server.id)}}
      end
    end)
  end

  defp hover_text(contents) when is_binary(contents), do: contents
  defp hover_text(%{"value" => value}) when is_binary(value), do: value
  defp hover_text(list) when is_list(list), do: Enum.map_join(list, "\n\n", &hover_text/1)
  defp hover_text(_contents), do: ""

  defp document_symbols(ctx) do
    with_file(ctx, fn conn ->
      params = %{"textDocument" => %{"uri" => conn.uri}}

      with {:ok, result} <- request(ctx, conn, "textDocument/documentSymbol", params) do
        symbols = if is_list(result), do: result, else: []
        rel = Text.display_path(conn.path, ctx.cwd)

        text =
          case symbols do
            [] ->
              "No symbols found in #{rel}"

            [%{"selectionRange" => _} | _] ->
              "Symbols in #{rel}:\n" <>
                Enum.join(Enum.flat_map(symbols, &document_symbol_lines(&1, 1)), "\n")

            _ ->
              "Symbols in #{rel}:\n" <>
                Enum.map_join(symbols, "\n", fn symbol ->
                  line = get_in(symbol, ["location", "range", "start", "line"]) || 0
                  "  #{kind_name(symbol["kind"])} #{symbol["name"]} @ line #{line + 1}"
                end)
          end

        {:ok, text, %{server: to_string(conn.server.id), count: length(symbols)}}
      end
    end)
  end

  defp document_symbol_lines(symbol, depth) do
    line = (get_in(symbol, ["range", "start", "line"]) || 0) + 1
    detail = if is_binary(symbol["detail"]) and symbol["detail"] != "", do: " #{symbol["detail"]}"

    [
      "#{String.duplicate("  ", depth)}#{kind_name(symbol["kind"])} #{symbol["name"]}#{detail} @ line #{line}"
      | Enum.flat_map(List.wrap(symbol["children"]), &document_symbol_lines(&1, depth + 1))
    ]
  end

  defp workspace_symbols(ctx) do
    query = String.trim(ctx.req.query)

    case workspace_clients(ctx) do
      [] ->
        {:error,
         "No language server is running for this session and none matches a project root marker in the working directory. Run an lsp action on a source file first."}

      clients ->
        {symbols, failures, servers} =
          Enum.reduce(clients, {[], [], []}, fn {server, pid}, {symbols, failures, servers} ->
            result =
              with {:ok, conn} <- connect_existing(ctx, server, pid) do
                request(ctx, conn, "workspace/symbol", %{"query" => query})
              end

            case result do
              {:ok, list} when is_list(list) ->
                {symbols ++ list, failures, [to_string(server.id) | servers]}

              {:ok, _none} ->
                {symbols, failures, [to_string(server.id) | servers]}

              {:error, reason} ->
                {symbols, ["  #{server.id}: #{error_text(reason)}" | failures], servers}
            end
          end)

        matched =
          symbols
          |> Enum.filter(&symbol_matches?(&1, query))
          |> Enum.uniq_by(fn symbol ->
            {symbol["name"], symbol["containerName"], symbol["kind"],
             get_in(symbol, ["location", "uri"]), get_in(symbol, ["location", "range", "start"])}
          end)

        failure_text =
          if failures == [], do: "", else: "\nServer failures:\n" <> Enum.join(failures, "\n")

        cond do
          servers == [] ->
            {:error, "Workspace symbol search failed:" <> failure_text}

          matched == [] ->
            {:ok, "No symbols matching #{inspect(query)}" <> failure_text,
             %{server: Enum.join(servers, ", "), count: 0}}

          true ->
            shown = Enum.take(matched, @workspace_symbol_limit)
            {lines, _cache} = Enum.map_reduce(shown, %{}, &workspace_symbol_line(&1, ctx.cwd, &2))

            more =
              if length(matched) > @workspace_symbol_limit,
                do:
                  "\n  ... #{length(matched) - @workspace_symbol_limit} more symbol(s) not shown",
                else: ""

            {:ok,
             "Found #{length(matched)} symbol(s) matching #{inspect(query)}:\n" <>
               Enum.join(lines, "\n") <> more <> failure_text,
             %{server: Enum.join(servers, ", "), count: length(matched)}}
        end
    end
  end

  defp symbol_matches?(symbol, query) do
    needle = String.downcase(query)

    path =
      with uri when is_binary(uri) <- get_in(symbol, ["location", "uri"]),
           {:ok, path} <- Text.uri_to_path(uri) do
        path
      else
        _ -> ""
      end

    Enum.any?([symbol["name"], symbol["containerName"], path], fn field ->
      is_binary(field) and String.contains?(String.downcase(field), needle)
    end)
  end

  defp workspace_symbol_line(symbol, cwd, cache) do
    container =
      if is_binary(symbol["containerName"]) and symbol["containerName"] != "",
        do: " (#{symbol["containerName"]})",
        else: ""

    location = symbol["location"] || %{}
    {where, cache} = location_label(location, cwd, cache)
    {"  #{kind_name(symbol["kind"])} #{symbol["name"]}#{container} @ #{where}", cache}
  end

  defp rename(ctx) do
    with_position(ctx, fn conn, position, _content ->
      params = position_params(conn, position)

      with :ok <- prepare_rename(ctx, conn, params),
           {:ok, edit} <-
             request(
               ctx,
               conn,
               "textDocument/rename",
               Map.put(params, "newName", ctx.req.new_name)
             ),
           {:ok, ops} <- WorkspaceEdit.plan(edit) do
        cond do
          ops == [] ->
            {:ok, "Rename returned no edits",
             %{server: to_string(conn.server.id), applied: false}}

          ctx.req.apply ->
            apply_ops(ctx, conn, ops, "rename", "Applied rename to #{ctx.req.new_name}")

          true ->
            {:ok,
             "Rename preview (#{length(ops)} change(s); pass apply: true to write them):\n" <>
               Enum.map_join(WorkspaceEdit.describe(ops, ctx.cwd), "\n", &("  " <> &1)),
             %{server: to_string(conn.server.id), applied: false, change_count: length(ops)}}
        end
      end
    end)
  end

  defp prepare_rename(ctx, conn, params) do
    case get_in(conn.capabilities, ["renameProvider"]) do
      %{"prepareProvider" => true} ->
        case request(ctx, conn, "textDocument/prepareRename", params) do
          {:ok, nil} ->
            {:error,
             "Cannot rename at line #{ctx.req.line}: the server reports no renameable symbol there"}

          {:ok, _range} ->
            :ok

          error ->
            error
        end

      _ ->
        :ok
    end
  end

  defp apply_ops(ctx, conn, ops, action, heading) do
    opts =
      ctx.opts
      |> Keyword.put(:lsp_documents, conn.documents)
      |> Keyword.put(:mutation_deadline, ctx.deadline)

    case WorkspaceEdit.apply(ops, ctx.cwd, opts, ctx.signal, %{tool: "lsp", action: action}) do
      {:ok, %{changed: changed, applied: applied, checkpoint: checkpoint}} ->
        Client.refresh(conn.pid, changed)

        details =
          %{
            server: to_string(conn.server.id),
            applied: true,
            changed_files: Enum.map(Enum.uniq(changed), &Text.display_path(&1, ctx.cwd))
          }
          |> CheckpointGuard.put_details(checkpoint)

        {:ok, heading <> ":\n" <> Enum.map_join(applied, "\n", &("  " <> &1)), details}

      {:error, reason, %{changed: changed, checkpoint: checkpoint}} ->
        Client.refresh(conn.pid, changed)

        details =
          %{
            success: false,
            applied: changed != [],
            changed_files: Enum.map(Enum.uniq(changed), &Text.display_path(&1, ctx.cwd))
          }
          |> CheckpointGuard.put_details(checkpoint)

        {:partial_error, "Failed to apply #{action} edits: #{reason}", details}

      {:error, reason} ->
        {:error, "Failed to apply #{action} edits: #{reason}"}
    end
  end

  defp code_actions(ctx) do
    with_position(ctx, fn conn, position, content ->
      range = action_range(ctx, content, position)
      diagnostics = action_diagnostics(ctx, conn, range)

      context =
        %{"diagnostics" => diagnostics, "triggerKind" => 1}
        |> then(fn context ->
          if not ctx.req.apply and is_binary(ctx.req.query),
            do: Map.put(context, "only", [ctx.req.query]),
            else: context
        end)

      params = %{"textDocument" => %{"uri" => conn.uri}, "range" => range, "context" => context}

      with {:ok, result} <- request(ctx, conn, "textDocument/codeAction", params) do
        actions = if is_list(result), do: Enum.filter(result, &is_map/1), else: []

        listing =
          Enum.with_index(actions, fn action, index ->
            "  " <> format_code_action(action, index)
          end)

        cond do
          actions == [] ->
            {:ok, "No code actions available", %{server: to_string(conn.server.id), count: 0}}

          ctx.req.apply ->
            case select_action(actions, ctx.req.query) do
              nil ->
                {:ok,
                 "No code action matches #{inspect(ctx.req.query)}. Available actions:\n" <>
                   Enum.join(listing, "\n"),
                 %{server: to_string(conn.server.id), applied: false, success: false}}

              action ->
                apply_code_action(ctx, conn, action)
            end

          true ->
            {:ok, "#{length(actions)} code action(s):\n" <> Enum.join(listing, "\n"),
             %{server: to_string(conn.server.id), count: length(actions)}}
        end
      end
    end)
  end

  # With a symbol the range covers it, with a column it is that point, and
  # otherwise the whole line, so line-level quick fixes are offered.
  defp action_range(ctx, content, %{"line" => line, "character" => character} = position) do
    {:ok, text} = Text.line_at(content, line)

    finish =
      cond do
        is_binary(ctx.req.symbol) ->
          [symbol | _] = String.split(ctx.req.symbol, ~r/#\d+$/)
          %{"line" => line, "character" => character + Text.utf16_length(symbol)}

        is_integer(ctx.req.column) ->
          position

        true ->
          %{"line" => line, "character" => Text.utf16_length(text)}
      end

    start =
      if is_nil(ctx.req.symbol) and is_nil(ctx.req.column),
        do: %{"line" => line, "character" => 0},
        else: position

    %{"start" => start, "end" => finish}
  end

  defp action_diagnostics(ctx, conn, range) do
    wait_ms = min(remaining(ctx), @code_action_diagnostics_wait_ms)

    diagnostics =
      case await_published(ctx, conn, wait_ms) do
        {:ok, list} -> list
        {:timeout, list} -> list
        {:error, _reason} -> []
      end

    first = range["start"]["line"]
    last = range["end"]["line"]

    Enum.filter(diagnostics, fn diagnostic ->
      start_line = get_in(diagnostic, ["range", "start", "line"]) || -1
      end_line = get_in(diagnostic, ["range", "end", "line"]) || start_line
      start_line <= last and end_line >= first
    end)
  end

  defp select_action(actions, query) do
    query = String.trim(query)

    case Integer.parse(query) do
      {index, ""} ->
        Enum.at(actions, index)

      _ ->
        needle = String.downcase(query)
        Enum.find(actions, &String.contains?(String.downcase(&1["title"] || ""), needle))
    end
  end

  defp format_code_action(action, index) do
    kind =
      cond do
        is_binary(action["command"]) -> "command"
        is_binary(action["kind"]) and action["kind"] != "" -> action["kind"]
        true -> "action"
      end

    preferred = if action["isPreferred"] == true, do: " (preferred)", else: ""

    disabled =
      case action["disabled"] do
        %{"reason" => reason} -> " (disabled: #{reason})"
        _ -> ""
      end

    "#{index}: [#{kind}] #{action["title"]}#{preferred}#{disabled}"
  end

  defp apply_code_action(ctx, conn, %{"command" => command} = action) when is_binary(command) do
    with {:ok, applied, details} <- execute_command(ctx, conn, action) do
      {:ok, action_heading(action, details) <> applied, details}
    end
  end

  defp apply_code_action(ctx, conn, action) do
    action = maybe_resolve(ctx, conn, action)

    with {:ok, ops} <- WorkspaceEdit.plan(action["edit"]) do
      case maybe_apply(ctx, conn, ops) do
        {:ok, edit_text, edit_details} ->
          {:ok, command_text, command_details} = maybe_command(ctx, conn, action["command"])

          if ops == [] and is_nil(action["command"]) do
            {:ok, "Action #{inspect(action["title"])} has no workspace edit or command to apply",
             %{server: to_string(conn.server.id), applied: false, success: false}}
          else
            details = merge_apply_details(edit_details, command_details)

            {:ok, action_heading(action, details) <> edit_text <> command_text,
             Map.put(details, :server, to_string(conn.server.id))}
          end

        error ->
          error
      end
    end
  end

  defp action_heading(action, details) do
    verb = if details[:success] == false, do: "Failed", else: "Applied"
    "#{verb} #{inspect(action["title"])}:\n"
  end

  defp maybe_resolve(ctx, conn, action) do
    resolvable? = match?(%{"resolveProvider" => true}, conn.capabilities["codeActionProvider"])

    if is_nil(action["edit"]) and resolvable? do
      case request(ctx, conn, "codeAction/resolve", action) do
        {:ok, resolved} when is_map(resolved) -> resolved
        _ -> action
      end
    else
      action
    end
  end

  defp maybe_apply(_ctx, _conn, []), do: {:ok, "", %{}}

  defp maybe_apply(ctx, conn, ops) do
    with {:ok, text, details} <- apply_ops(ctx, conn, ops, "code_action", "Workspace edit") do
      {:ok, (text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))) <> "\n", details}
    end
  end

  defp maybe_command(ctx, conn, %{"command" => name} = command) when is_binary(name) do
    execute_command(ctx, conn, command)
  end

  defp maybe_command(_ctx, _conn, _command), do: {:ok, "", %{}}

  # Commands may send `workspace/applyEdit` before answering. Apply each edit
  # before acknowledging it, so server commands can observe their actual writes.
  defp execute_command(ctx, conn, command) do
    params = %{"command" => command["command"], "arguments" => command["arguments"] || []}

    {:ok, receipts} = Agent.start_link(fn -> [] end)
    on_checkpoint = Keyword.get(ctx.opts, :on_checkpoint)

    # A published checkpoint precedes the batch's writes; until that batch
    # reports its outcome, every captured path may have changed.
    opts =
      Keyword.put(ctx.opts, :on_checkpoint, fn checkpoint ->
        if checkpoint, do: Agent.update(receipts, &[{:checkpoint, checkpoint} | &1])
        if on_checkpoint, do: on_checkpoint.(checkpoint)
      end)

    ctx = %{ctx | opts: opts}

    try do
      result =
        run_abortable(ctx, fn ->
          ServerManager.request_with_edits(conn.session_id, "workspace/executeCommand", params,
            timeout_ms: remaining(ctx),
            on_timeout: :cancel,
            apply_edit: fn edit ->
              conn = Map.put(conn, :documents, Client.documents(conn.pid))

              outcome =
                case WorkspaceEdit.plan(edit) do
                  {:ok, ops} ->
                    case maybe_apply(ctx, conn, ops) do
                      {:ok, text, details} -> {:ok, {text, details}}
                      {:partial_error, reason, details} -> {:partial_error, reason, details}
                      {:error, _} = error -> error
                    end

                  {:error, _} = error ->
                    error
                end

              Agent.update(receipts, &[outcome | &1])

              case outcome do
                {:partial_error, reason, _details} -> {:error, reason}
                other -> other
              end
            end
          )
        end)

      {text, details, failures} =
        receipts |> Agent.get(&Enum.reverse/1) |> apply_receipts(ctx.cwd)

      response =
        case result do
          {:ok, message, _receipts} ->
            response({:ok, message}, ctx, conn, "workspace/executeCommand")

          other ->
            response(other, ctx, conn, "workspace/executeCommand")
        end

      failures =
        case response do
          {:ok, _} -> failures
          {:error, reason} -> failures ++ [error_text(reason)]
        end

      callback_failures =
        case result do
          {:ok, _message, outcomes} -> for {:error, reason} <- outcomes, do: reason
          _ -> []
        end

      failures = Enum.uniq(failures ++ callback_failures)

      if failures == [] do
        {:ok, text <> "  Executed command: #{command["command"]}", details}
      else
        {:ok, text <> Enum.join(failures, "\n"), Map.put(details, :success, false)}
      end
    after
      Agent.stop(receipts)
    end
  end

  defp apply_receipts(receipts, cwd) do
    reported =
      receipts
      |> Enum.flat_map(fn
        {:ok, {_text, details}} -> checkpoint_ids(details)
        {:partial_error, _reason, details} -> checkpoint_ids(details)
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(receipts, {"", %{}, []}, fn
      {:checkpoint, checkpoint}, {text, details, failures} ->
        details = merge_apply_details(details, CheckpointGuard.put_details(%{}, checkpoint))

        if MapSet.member?(reported, checkpoint.id) do
          {text, details, failures}
        else
          paths =
            checkpoint
            |> get_in([:state, :filesystem, :files])
            |> List.wrap()
            |> Enum.map(&Text.display_path(&1.path, cwd))

          unreported = %{success: false, affected_paths: paths}

          {text, merge_apply_details(details, unreported),
           failures ++
             [
               "Workspace edit after checkpoint #{checkpoint.id} did not report its outcome; " <>
                 "these paths may have changed: #{Enum.join(paths, ", ")}"
             ]}
        end

      {:ok, {more, more_details}}, {text, details, failures} ->
        {text <> more, merge_apply_details(details, more_details), failures}

      {:partial_error, reason, more_details}, {text, details, failures} ->
        {text, merge_apply_details(details, more_details), failures ++ [reason]}

      {:error, reason}, {text, details, failures} ->
        {text, details, failures ++ [reason]}
    end)
  end

  defp merge_apply_details(left, right) do
    checkpoints = Enum.uniq(checkpoint_ids(left) ++ checkpoint_ids(right))

    Map.merge(left, right, fn
      key, a, b when key in [:changed_files, :affected_paths] -> Enum.uniq(a ++ b)
      :applied, a, b -> a or b
      :success, a, b -> a and b
      _key, _a, b -> b
    end)
    |> then(fn details ->
      case checkpoints do
        [] -> details
        [id] -> details |> Map.put(:checkpoint_ids, [id]) |> Map.put(:checkpoint_id, id)
        ids -> details |> Map.put(:checkpoint_ids, ids) |> Map.delete(:checkpoint_id)
      end
    end)
  end

  defp checkpoint_ids(details),
    do: Map.get(details, :checkpoint_ids, List.wrap(Map.get(details, :checkpoint_id)))

  defp capabilities(ctx) do
    with_file(ctx, fn conn ->
      {:ok, "#{conn.server.id} capabilities:\n" <> Jason.encode!(conn.capabilities, pretty: true),
       %{server: to_string(conn.server.id), capabilities: conn.capabilities}}
    end)
  end

  defp reload(%{req: %{file: file}} = ctx) when file in [nil, "*"] do
    clients = current_clients(ctx)
    servers = Map.new(LemonLsp.Servers.list(ctx.cwd), &{&1.id, &1})

    Enum.reduce_while(
      clients,
      {:ok, "Reloaded #{length(clients)} language server(s)", %{count: length(clients)}},
      fn client, result ->
        Client.stop(client.pid, restart: true)

        case attempt(
               ctx,
               servers[client.server_id],
               client.root,
               nil,
               fn _ ->
                 {:ok, "", %{}}
               end,
               0
             ) do
          {:ok, _, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end
    )
  end

  defp reload(ctx) do
    with_file(ctx, fn conn ->
      Client.stop(conn.pid, restart: true)

      attempt(
        ctx,
        conn.server,
        conn.root,
        conn.path,
        fn _ ->
          {:ok, "Reloaded #{conn.server.id}", %{server: to_string(conn.server.id)}}
        end,
        0
      )
    end)
  end

  defp rename_file(ctx) do
    with_file(ctx, fn conn ->
      destination = PathHelpers.resolve_path(ctx.req.new_name, ctx.cwd)
      files = [%{"oldUri" => conn.uri, "newUri" => Text.path_to_uri(destination)}]
      operations = get_in(conn.capabilities, ["workspace", "fileOperations"]) || %{}

      edit =
        if operations["willRename"],
          do: request(ctx, conn, "workspace/willRenameFiles", %{"files" => files}),
          else: {:ok, nil}

      with {:ok, edit} <- edit,
           {:ok, ops} <- WorkspaceEdit.plan(edit) do
        ops = ops ++ [%{kind: :rename, from: conn.path, to: destination, options: %{}}]

        if ctx.req.apply do
          case apply_ops(ctx, conn, ops, "rename_file", "Renamed file") do
            {:ok, text, details} ->
              if operations["didRename"] do
                case ServerManager.notify_session(conn.session_id, "workspace/didRenameFiles", %{
                       "files" => files
                     }) do
                  :ok ->
                    {:ok, text, details}

                  {:error, _} ->
                    {:partial_error,
                     text <> "\nFile moved, but didRenameFiles notification failed", details}
                end
              else
                {:ok, text, details}
              end

            other ->
              other
          end
        else
          {:ok,
           "File rename preview (pass apply: true to write):\n" <>
             Enum.join(WorkspaceEdit.describe(ops, ctx.cwd), "\n"),
           %{applied: false, change_count: length(ops)}}
        end
      end
    end)
  end

  defp diagnostics(%{req: %{file: "*"}} = ctx) do
    entries =
      ctx
      |> current_clients()
      |> Enum.take(32)
      |> Enum.flat_map(fn client ->
        with {:ok, conn} <- Client.sync(client.pid, nil, remaining(ctx)),
             {:ok, entries} <- ServerManager.workspace_diagnostics(conn.session_id) do
          entries
        else
          _ -> []
        end
      end)
      |> Enum.flat_map(fn {uri, diagnostics} ->
        case Text.uri_to_path(uri) do
          {:ok, path} ->
            if path == ctx.cwd or String.starts_with?(path, ctx.cwd <> "/"),
              do: Enum.map(diagnostics, &{path, &1}),
              else: []

          _ ->
            []
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(@diagnostic_limit)

    text =
      entries
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort()
      |> Enum.map_join("\n", fn {path, list} ->
        format_diagnostics(list, path, Text.display_path(path, ctx.cwd))
      end)

    {:ok, if(text == "", do: "No published workspace diagnostics", else: text),
     %{count: length(entries), limit: @diagnostic_limit}}
  end

  defp diagnostics(ctx) do
    with_file(ctx, fn conn ->
      rel = Text.display_path(conn.path, ctx.cwd)

      result =
        if conn.capabilities["diagnosticProvider"],
          do: pull_diagnostics(ctx, conn),
          else: await_published(ctx, conn, remaining(ctx))

      case result do
        {:ok, list} ->
          {:ok, format_diagnostics(list, conn.path, rel),
           %{server: to_string(conn.server.id), count: length(list)}}

        {:timeout, []} ->
          {:ok,
           "No diagnostics received from #{conn.server.label} for #{rel} within #{ctx.req.timeout}s; the server may still be analyzing the file.",
           %{server: to_string(conn.server.id), count: 0, timed_out: true}}

        {:timeout, list} ->
          {:ok, format_diagnostics(list, conn.path, rel),
           %{server: to_string(conn.server.id), count: length(list), settled: false}}

        {:error, _} = error ->
          error
      end
    end)
  end

  defp pull_diagnostics(ctx, conn) do
    params = %{"textDocument" => %{"uri" => conn.uri}}

    case request(ctx, conn, "textDocument/diagnostic", params) do
      {:ok, %{"kind" => "full", "items" => items}} when is_list(items) -> {:ok, items}
      {:error, :session_lost} = error -> error
      _unchanged_or_failed -> await_published(ctx, conn, remaining(ctx))
    end
  end

  # Push diagnostics: accept a publish for this document that arrived after we
  # synced it. A publish for our exact document version is final; otherwise
  # wait until the stream for the document has been quiet for a moment.
  defp await_published(ctx, conn, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    poll_published(ctx, conn, deadline, nil)
  end

  defp poll_published(ctx, conn, deadline, settled) do
    now = System.monotonic_time(:millisecond)

    case ServerManager.document_diagnostics(conn.session_id, conn.uri) do
      # Unchanged document: a publish for the current version (or an
      # unversioned one) is still authoritative.
      {:ok, %{entry: %{version: version} = entry}}
      when conn.synced == :unchanged and (version == conn.version or is_nil(version)) ->
        {:ok, entry.diagnostics}

      {:ok, %{entry: %{seq: seq} = entry}} when seq > conn.diagnostics_seq ->
        cond do
          entry.version == conn.version ->
            {:ok, entry.diagnostics}

          match?({^seq, _}, settled) and now - elem(settled, 1) >= @diagnostics_settle_ms ->
            {:ok, entry.diagnostics}

          now >= deadline ->
            {:timeout, entry.diagnostics}

          true ->
            settled = if match?({^seq, _}, settled), do: settled, else: {seq, now}
            sleep_poll(ctx, conn, deadline, settled)
        end

      {:ok, _no_fresh_entry} ->
        if now >= deadline, do: {:timeout, []}, else: sleep_poll(ctx, conn, deadline, settled)

      {:error, _reason} ->
        {:error, :session_lost}
    end
  catch
    :exit, _reason -> {:error, :session_lost}
  end

  defp sleep_poll(ctx, conn, deadline, settled) do
    if AbortHelpers.aborted?(ctx.signal) do
      {:error, "Operation aborted"}
    else
      Process.sleep(50)
      poll_published(ctx, conn, deadline, settled)
    end
  end

  defp format_diagnostics([], _path, rel), do: "No diagnostics reported for #{rel}"

  defp format_diagnostics(diagnostics, path, rel) do
    sorted =
      Enum.sort_by(diagnostics, fn diagnostic ->
        start = get_in(diagnostic, ["range", "start"]) || %{}

        {diagnostic["severity"] || 1, start["line"] || 0, start["character"] || 0,
         diagnostic["message"] || ""}
      end)

    lines = file_lines(path)

    formatted =
      sorted
      |> Enum.take(@diagnostic_limit)
      |> Enum.map(fn diagnostic ->
        start = get_in(diagnostic, ["range", "start"]) || %{}
        line = start["line"] || 0
        col = column_for(lines, line, start["character"] || 0)
        source = if is_binary(diagnostic["source"]), do: "[#{diagnostic["source"]}] ", else: ""

        code =
          case diagnostic["code"] do
            nil -> ""
            code -> " (#{code})"
          end

        message = diagnostic["message"] |> to_string() |> String.trim()

        "  #{rel}:#{line + 1}:#{col} [#{severity(diagnostic["severity"])}] #{source}#{message}#{code}"
      end)

    more =
      if length(sorted) > @diagnostic_limit,
        do: ["  ... #{length(sorted) - @diagnostic_limit} more diagnostic(s) not shown"],
        else: []

    "#{rel}: #{severity_summary(sorted)}:\n" <> Enum.join(formatted ++ more, "\n")
  end

  defp severity(2), do: "warning"
  defp severity(3), do: "info"
  defp severity(4), do: "hint"
  defp severity(_), do: "error"

  defp severity_summary(diagnostics) do
    counts = Enum.frequencies_by(diagnostics, &severity(&1["severity"]))

    ~w(error warning info hint)
    |> Enum.filter(&Map.has_key?(counts, &1))
    |> Enum.map_join(", ", &"#{counts[&1]} #{&1}(s)")
  end

  defp raw_request(ctx) do
    method = String.trim(ctx.req.query)

    run_request = fn conn, position ->
      params =
        cond do
          not is_nil(ctx.req.payload) -> ctx.req.payload
          position -> position_params(conn, position)
          Map.has_key?(conn, :uri) -> %{"textDocument" => %{"uri" => conn.uri}}
          true -> %{}
        end

      with {:ok, result} <- request(ctx, conn, method, params) do
        body = if is_binary(result), do: result, else: Jason.encode!(result, pretty: true)
        {:ok, "#{conn.server.id} ← #{method}:\n#{body}", %{server: to_string(conn.server.id)}}
      end
    end

    cond do
      ctx.req.file && ctx.req.line ->
        with_position(ctx, fn conn, position, _content -> run_request.(conn, position) end)

      ctx.req.file ->
        with_file(ctx, fn conn -> run_request.(conn, nil) end)

      true ->
        case workspace_clients(ctx) do
          [] ->
            {:error, "No language server is running for this session; pass `file` to choose one"}

          [{server, pid} | _] ->
            with {:ok, conn} <- connect_existing(ctx, server, pid), do: run_request.(conn, nil)
        end
    end
  end

  # -- Connections ------------------------------------------------------------

  defp with_position(ctx, fun) do
    with_file(ctx, fn conn ->
      with {:ok, content} <- read_file(conn.path),
           {:ok, character} <-
             Text.resolve_character(content, ctx.req.line, ctx.req.symbol, ctx.req.column) do
        fun.(conn, %{"line" => ctx.req.line - 1, "character" => character}, content)
      end
    end)
  end

  defp with_file(ctx, fun) do
    path = PathHelpers.resolve_path(ctx.req.file, ctx.cwd)

    with :ok <- regular_file(path),
         {:ok, server} <- server_for(path, ctx.cwd) do
      root = workspace_root(path, ctx.cwd, server.root_markers)
      attempt(ctx, server, root, path, fun, 1)
    end
  end

  defp attempt(ctx, server, root, path, fun, retries) do
    key = {ctx.scope, server.id, root}

    result =
      with {:ok, pid} <-
             Client.ensure(
               key,
               server,
               Keyword.get(ctx.opts, :session_pid),
               Keyword.get(ctx.opts, :session_key),
               ctx.cwd
             ),
           {:ok, conn} <- Client.sync(pid, path, remaining(ctx)) do
        case fun.(Map.merge(conn, %{pid: pid, root: root, path: path})) do
          {:error, :session_lost} = lost ->
            Client.stop(pid)
            lost

          other ->
            other
        end
      end

    case result do
      {:error, :session_lost} when retries > 0 ->
        attempt(ctx, server, root, path, fun, retries - 1)

      {:error, reason} when not is_binary(reason) ->
        {:error, connection_error(reason, server)}

      other ->
        other
    end
  end

  defp connect_existing(ctx, server, pid) do
    case Client.sync(pid, nil, remaining(ctx)) do
      {:ok, conn} -> {:ok, Map.merge(conn, %{pid: pid})}
      {:error, reason} -> {:error, connection_error(reason, server)}
    end
  end

  defp current_clients(ctx) do
    servers = Map.new(LemonLsp.Servers.list(ctx.cwd), &{&1.id, &1.config_hash})

    Enum.filter(Client.list(ctx.scope), fn client ->
      case {servers[client.server_id], Client.info(client.pid)} do
        {hash, {:ok, %{config_hash: hash}}} when is_binary(hash) ->
          true

        _ ->
          Client.stop(client.pid)
          false
      end
    end)
  end

  # Running clients for this scope, else servers whose root marker sits in
  # the working directory itself (started on demand at the cwd). Both bind the
  # client to the calling session process before any workspace request runs.
  defp workspace_clients(ctx) do
    servers = Map.new(LemonLsp.Servers.list(ctx.cwd), &{&1.id, &1})

    candidates =
      case current_clients(ctx) do
        [] ->
          servers
          |> Map.values()
          |> Enum.filter(fn server ->
            server.available and
              Enum.any?(server.root_markers, &File.exists?(Path.join(ctx.cwd, &1)))
          end)
          |> Enum.sort_by(& &1.id)
          |> Enum.map(&{&1, ctx.cwd})

        running ->
          Enum.flat_map(running, fn %{server_id: id, root: root} ->
            case servers[id] do
              nil -> []
              server -> [{server, root}]
            end
          end)
      end

    Enum.flat_map(candidates, fn {server, root} ->
      case Client.ensure(
             {ctx.scope, server.id, root},
             server,
             Keyword.get(ctx.opts, :session_pid),
             Keyword.get(ctx.opts, :session_key),
             ctx.cwd
           ) do
        {:ok, pid} -> [{server, pid}]
        {:error, _} -> []
      end
    end)
  end

  defp server_for(path, cwd) do
    ext = path |> Path.extname() |> String.downcase()
    servers = LemonLsp.Servers.list(cwd)

    case Enum.find(servers, &(ext in &1.extensions)) do
      nil ->
        supported = servers |> Enum.flat_map(& &1.extensions) |> Enum.uniq() |> Enum.join(" ")

        {:error,
         "No language server is registered for #{if ext == "", do: "extensionless", else: ext} files (supported: #{supported})"}

      %{available: false} = server ->
        {:error,
         "#{server.label} (#{server.command}) is not installed. #{server.install_hint} Set #{server.command_env} to use another executable."}

      server ->
        {:ok, server}
    end
  end

  defp workspace_root(path, cwd, markers) do
    dir = Path.dirname(path)
    inside? = dir == cwd or String.starts_with?(dir, cwd <> "/")
    find_root(dir, if(inside?, do: cwd, else: "/"), markers) || if(inside?, do: cwd, else: dir)
  end

  defp find_root(dir, stop, markers) do
    cond do
      Enum.any?(markers, &File.exists?(Path.join(dir, &1))) -> dir
      dir == stop or Path.dirname(dir) == dir -> nil
      true -> find_root(Path.dirname(dir), stop, markers)
    end
  end

  defp regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, "Not a regular file (#{type}): #{path}"}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, reason} -> {:error, "Cannot access #{path}: #{reason}"}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  defp connection_error({:file, reason, path}, _server), do: "Cannot read #{path}: #{reason}"

  defp connection_error(:command_unavailable, server),
    do: "#{server.label} is not installed. #{server.install_hint}"

  defp connection_error(:initialize_timeout, server),
    do: "#{server.label} did not finish initializing in time; retry or pass a larger timeout"

  defp connection_error({:initialize_failed, message}, server),
    do: "#{server.label} failed to initialize: #{message}"

  defp connection_error(:session_lost, server),
    do: "#{server.label} exited unexpectedly; retry the request"

  defp connection_error(reason, server),
    do: "#{server.label} is unavailable: #{inspect(reason)}"

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  # -- Requests ---------------------------------------------------------------

  defp request(ctx, conn, method, params) do
    ctx
    |> run_abortable(fn ->
      ServerManager.request_session(conn.session_id, method, params,
        timeout_ms: remaining(ctx),
        on_timeout: :cancel
      )
    end)
    |> response(ctx, conn, method)
  end

  defp response({:ok, %{"error" => error}}, _ctx, conn, method),
    do: {:error, lsp_error(conn, method, error)}

  defp response({:ok, %{"error" => error}, _edits}, _ctx, conn, method),
    do: {:error, lsp_error(conn, method, error)}

  defp response({:ok, message}, _ctx, _conn, _method), do: {:ok, Map.get(message, "result")}

  defp response({:ok, message, edits}, _ctx, _conn, _method),
    do: {:ok, Map.get(message, "result"), edits}

  defp response({:error, :request_timeout}, ctx, conn, method) do
    {:error,
     "LSP #{method} timed out after #{ctx.req.timeout}s on #{conn.server.label}. The server may still be indexing; retry or pass a larger timeout."}
  end

  defp response({:error, reason}, _ctx, _conn, _method)
       when reason in [:session_exited, :session_stopped],
       do: {:error, "Language server exited while this request was in flight; retry the request"}

  defp response({:error, reason}, _ctx, _conn, _method)
       when reason in [:unknown_lsp_session, :session_lost],
       do: {:error, :session_lost}

  defp response({:error, reason}, _ctx, _conn, method) when is_binary(reason),
    do: {:error, "LSP #{method}: #{reason}"}

  defp response({:error, reason}, _ctx, _conn, method),
    do: {:error, "LSP #{method} failed: #{inspect(reason)}"}

  defp lsp_error(conn, method, error) do
    message = if is_map(error), do: error["message"] || inspect(error), else: inspect(error)
    code = if is_map(error) and error["code"], do: " (code #{error["code"]})", else: ""
    "#{conn.server.label} returned an error for #{method}: #{message}#{code}"
  end

  defp run_abortable(ctx, fun) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          :exit, _reason -> {:error, :session_lost}
        end
      end)

    await_task(task, ctx.signal)
  end

  defp await_task(task, signal) do
    case Task.yield(task, 100) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, :session_lost}

      nil ->
        if AbortHelpers.aborted?(signal) do
          _ = Task.shutdown(task, :brutal_kill)
          {:error, "Operation aborted"}
        else
          await_task(task, signal)
        end
    end
  end

  defp remaining(ctx) do
    (ctx.deadline - System.monotonic_time(:millisecond))
    |> max(50)
    |> min(300_000)
  end

  defp position_params(conn, position),
    do: %{"textDocument" => %{"uri" => conn.uri}, "position" => position}

  # -- Formatting -------------------------------------------------------------

  defp normalize_locations(nil), do: []
  defp normalize_locations(result) when is_map(result), do: normalize_locations([result])

  # Servers may report one location under both a symlinked and a canonical
  # path (clangd with /tmp vs /private/tmp on macOS); keep the first of each.
  defp normalize_locations(results) when is_list(results) do
    results
    |> Enum.flat_map(fn
      %{"targetUri" => uri} = link ->
        [%{"uri" => uri, "range" => link["targetSelectionRange"] || link["targetRange"]}]

      %{"uri" => _uri} = location ->
        [location]

      _ ->
        []
    end)
    |> Enum.uniq_by(fn location ->
      canonical =
        case Text.uri_to_path(location["uri"]) do
          {:ok, path} -> Text.realpath(path)
          _ -> location["uri"]
        end

      {canonical, get_in(location, ["range", "start"])}
    end)
  end

  defp normalize_locations(_result), do: []

  defp format_locations(locations, cwd, context?) do
    {lines, _cache} =
      Enum.map_reduce(locations, %{}, fn location, cache ->
        {label, cache} = location_label(location, cwd, cache)

        if context? do
          {excerpt, cache} = excerpt(location, cache)
          {Enum.join(["  " <> label | excerpt], "\n"), cache}
        else
          {"  " <> label, cache}
        end
      end)

    lines
  end

  defp location_label(location, cwd, cache) do
    with uri when is_binary(uri) <- location["uri"],
         {:ok, path} <- Text.uri_to_path(uri) do
      start = get_in(location, ["range", "start"]) || %{"line" => 0, "character" => 0}
      {lines, cache} = cached_lines(path, cache)
      line = start["line"] || 0
      col = column_for(lines, line, start["character"] || 0)
      {"#{Text.display_path(path, cwd)}:#{line + 1}:#{col}", cache}
    else
      _ -> {to_string(location["uri"]), cache}
    end
  end

  defp excerpt(location, cache) do
    with {:ok, path} <- Text.uri_to_path(location["uri"]),
         line when is_integer(line) <- get_in(location, ["range", "start", "line"]) do
      {lines, cache} = cached_lines(path, cache)

      excerpt =
        if lines do
          max(line - 1, 0)..min(line + 1, tuple_size(lines) - 1)//1
          |> Enum.map(fn index ->
            "    #{index + 1}: #{lines |> elem(index) |> String.slice(0, @excerpt_chars)}"
          end)
        else
          []
        end

      {excerpt, cache}
    else
      _ -> {[], cache}
    end
  end

  defp cached_lines(path, cache) do
    case Map.fetch(cache, path) do
      {:ok, lines} ->
        {lines, cache}

      :error ->
        lines = file_lines(path)
        {lines, Map.put(cache, path, lines)}
    end
  end

  defp file_lines(path) do
    case File.read(path) do
      {:ok, content} -> content |> Text.lines() |> List.to_tuple()
      {:error, _} -> nil
    end
  end

  defp column_for(lines, line, character) when is_tuple(lines) and line < tuple_size(lines),
    do: Text.display_column(elem(lines, line), character)

  defp column_for(_lines, _line, character), do: character + 1

  defp kind_name(kind) when is_integer(kind) and kind >= 1 and kind <= 26,
    do: Enum.at(@symbol_kinds, kind - 1)

  defp kind_name(_kind), do: "Symbol"

  defp result(text, details, ctx) do
    result =
      if byte_size(text) <= @max_output_bytes do
        %AgentToolResult{content: [%TextContent{text: text}], details: details}
      else
        spill(text, details, ctx)
      end

    %{result | is_error: details[:success] == false}
  end

  defp spill(text, details, ctx) do
    dir =
      case Artifacts.spill_dir(ctx.cwd, ctx.opts) do
        {:ok, dir} -> dir
        {:error, _} -> System.tmp_dir!()
      end

    path = Path.join(dir, "lemon-lsp-#{System.unique_integer([:positive, :monotonic])}.txt")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, text, [:exclusive]) do
      note = "\n\n[Full output saved to: #{path}. Use read with offset/limit to retrieve it.]"
      head = String.slice(text, 0, @max_output_bytes - byte_size(note))

      %AgentToolResult{
        content: [%TextContent{text: head <> note}],
        details: Map.merge(details, %{truncated: true, full_output_path: path})
      }
      |> Artifacts.attach(ctx.cwd, ctx.opts)
    else
      _ ->
        %AgentToolResult{
          content: [
            %TextContent{text: String.slice(text, 0, @max_output_bytes) <> "\n[output truncated]"}
          ],
          details: Map.put(details, :truncated, true)
        }
    end
  end

  defp scope(cwd, opts) do
    case Keyword.get(opts, :session_id) do
      id when is_binary(id) and id != "" -> id
      _ -> "cwd:" <> cwd
    end
  end

  defp check_abort(signal) do
    if AbortHelpers.aborted?(signal), do: {:error, "Operation aborted"}, else: :ok
  end
end
