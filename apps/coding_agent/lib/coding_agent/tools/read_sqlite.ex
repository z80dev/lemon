defmodule CodingAgent.Tools.ReadSqlite do
  @moduledoc """
  Read-only SQLite database views for `read`.

  A path whose file part ends in `.sqlite`, `.sqlite3`, `.db` or `.db3` (and
  whose header is the SQLite magic) accepts these selectors:

  * `app.db` lists tables and views with row counts.
  * `app.db:users` shows the table schema plus a few sample rows.
  * `app.db:users?limit=20&offset=40&where=age>30&order=name` pages rows.
  * `app.db:users:42` shows one row by single-column primary key, else rowid.
  * `app.db?q=SELECT ...` runs one read-only query (capped at 1000 rows).

  Databases are opened with `SQLITE_OPEN_READONLY` and `PRAGMA query_only`,
  queries run under a deadline that interrupts the statement, and `where` /
  `order` / `q` fragments reject statement separators, comments and
  attach/pragma-style keywords. Nothing here writes to a database.
  """

  alias CodingAgent.Tools.ReadFormatText
  alias Exqlite.Sqlite3

  @magic "SQLite format 3" <> <<0>>
  @path_regex ~r/\A(?<db>.+?\.(?:sqlite3?|db3?))(?<rest>(?::[^?]*)?(?:\?.*)?)\z/i
  @default_limit 20
  @max_limit 500
  @sample_rows 5
  @max_raw_rows 1000
  @max_cell_chars 200
  @query_timeout_ms 10_000
  @forbidden ~w(attach detach pragma vacuum insert update delete replace create drop alter reindex analyze begin commit rollback savepoint release load_extension)

  @doc """
  Splits a resolved path into `{database_path, sub_path, query}` when it names
  an existing SQLite file, else `nil`.
  """
  @spec split_path(String.t()) :: {String.t(), String.t(), String.t()} | nil
  def split_path(path) when is_binary(path) do
    with %{"db" => db, "rest" => rest} <- Regex.named_captures(@path_regex, path),
         true <- sqlite_file?(db) do
      {sub_path, query} =
        case String.split(rest, "?", parts: 2) do
          [sub_path, query] -> {sub_path, query}
          [sub_path] -> {sub_path, ""}
        end

      {db, String.trim_leading(sub_path, ":"), query}
    else
      _ -> nil
    end
  end

  @doc "Whether `path` has a SQLite extension and header."
  @spec database?(String.t()) :: boolean()
  def database?(path) do
    String.downcase(Path.extname(path)) in ~w(.sqlite .sqlite3 .db .db3) and sqlite_file?(path)
  end

  @doc "Whether `path` is a regular file starting with the SQLite header."
  @spec sqlite_file?(String.t()) :: boolean()
  def sqlite_file?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, byte_size(@magic))) do
      {:ok, @magic} -> File.regular?(path)
      _ -> false
    end
  end

  @spec read(String.t(), String.t(), String.t(), map(), reference() | nil, keyword()) ::
          {:ok, LemonAgent.Types.AgentToolResult.t()} | {:error, String.t()}
  def read(db_path, sub_path, query, params, signal, opts) do
    with {:ok, selector} <- parse_selector(sub_path, URI.decode_query(query)),
         {:ok, text} <- with_connection(db_path, &render(&1, selector)) do
      ReadFormatText.result(text, db_path, params, signal, opts, %{
        format: :sqlite,
        immutable: true,
        selector: selector_kind(selector)
      })
    end
  end

  # ── selectors ──────────────────────────────────────────────────────────────

  defp parse_selector("", %{"q" => sql}) do
    with :ok <- guard_fragment(sql, "q"), do: {:ok, {:raw, sql}}
  end

  defp parse_selector("", _params), do: {:ok, :list}

  defp parse_selector(sub_path, params) do
    case String.split(sub_path, ":", parts: 2) do
      [table, key] when table != "" and key != "" ->
        {:ok, {:row, table, key}}

      [table] when table != "" ->
        if Enum.any?(~w(limit offset where order), &Map.has_key?(params, &1)),
          do: page_selector(table, params),
          else: {:ok, {:schema, table}}

      _ ->
        {:error, "Invalid SQLite selector #{inspect(sub_path)}; use db:table or db:table:key"}
    end
  end

  defp page_selector(table, params) do
    with {:ok, limit} <- int_param(params, "limit", @default_limit),
         {:ok, offset} <- int_param(params, "offset", 0),
         {:ok, where} <- optional_fragment(params, "where"),
         {:ok, order} <- optional_fragment(params, "order") do
      {:ok,
       {:page, table,
        %{limit: min(limit, @max_limit), offset: offset, where: where, order: order}}}
    end
  end

  defp int_param(params, key, default) do
    case Map.get(params, key) do
      nil -> {:ok, default}
      value -> parse_non_negative(value, key)
    end
  end

  defp parse_non_negative(value, key) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, "SQLite #{key} must be a non-negative integer"}
    end
  end

  defp optional_fragment(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value -> with :ok <- guard_fragment(value, key), do: {:ok, value}
    end
  end

  defp guard_fragment(fragment, key) do
    words = ~r/[a-z_]+/i |> Regex.scan(String.downcase(fragment)) |> List.flatten()

    cond do
      String.trim(fragment) == "" ->
        {:error, "SQLite #{key} must not be empty"}

      String.contains?(fragment, ["--", "/*"]) or Regex.match?(~r/;\s*\S/, fragment) ->
        {:error, "SQLite #{key} must be a single statement without comments"}

      word = Enum.find(words, &(&1 in @forbidden)) ->
        {:error, "SQLite #{key} may not use #{String.upcase(word)}; reads are read-only"}

      true ->
        :ok
    end
  end

  defp selector_kind(selector) when is_atom(selector), do: selector
  defp selector_kind(selector), do: elem(selector, 0)

  # ── connection ─────────────────────────────────────────────────────────────

  defp with_connection(db_path, fun) do
    case Sqlite3.open(db_path, mode: :readonly) do
      {:ok, conn} ->
        try do
          :ok = Sqlite3.execute(conn, "PRAGMA query_only = 1")
          run_with_deadline(conn, fn -> fun.(conn) end)
        after
          Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, "Cannot open SQLite database #{db_path}: #{inspect(reason)}"}
    end
  end

  defp run_with_deadline(conn, fun) do
    task = Task.async(fun)

    case Task.yield(task, @query_timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Sqlite3.interrupt(conn)
        _ = Task.shutdown(task, 1_000)
        {:error, "SQLite query exceeded #{div(@query_timeout_ms, 1000)}s and was interrupted"}
    end
  end

  defp query(conn, sql, args \\ [], max_rows \\ :infinity) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, args),
             {:ok, columns} <- Sqlite3.columns(conn, stmt),
             {:ok, rows, truncated?} <- collect(conn, stmt, max_rows, []) do
          {:ok, columns, rows, truncated?}
        end
      after
        Sqlite3.release(conn, stmt)
      end
    end
    |> case do
      {:error, reason} -> {:error, "SQLite error: #{format_error(reason)}"}
      ok -> ok
    end
  end

  defp collect(_conn, _stmt, max, acc) when is_integer(max) and length(acc) >= max,
    do: {:ok, Enum.reverse(acc), true}

  defp collect(conn, stmt, max, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> collect(conn, stmt, max, [row | acc])
      :done -> {:ok, Enum.reverse(acc), false}
      :busy -> {:error, "database is busy"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # ── rendering ──────────────────────────────────────────────────────────────

  defp render(conn, :list) do
    with {:ok, _cols, rows, _} <-
           query(
             conn,
             "SELECT name, type FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
           ) do
      lines =
        Enum.map(rows, fn [name, type] ->
          count =
            case query(conn, "SELECT count(*) FROM #{ident(name)}") do
              {:ok, _, [[n]], _} -> "#{n} rows"
              _ -> "count unavailable"
            end

          "#{name} (#{type}, #{count})"
        end)

      {:ok,
       if(lines == [], do: "(no tables)", else: Enum.join(lines, "\n")) <>
         "\n\nUse <db>:<table> for schema and sample rows, <db>:<table>?limit=&offset=&where=&order= to page, <db>:<table>:<key> for one row, <db>?q=SELECT ... for a query."}
    end
  end

  defp render(conn, {:schema, table}) do
    with {:ok, sql} <- table_sql(conn, table),
         {:ok, columns, rows, _} <-
           query(conn, "SELECT * FROM #{ident(table)} LIMIT #{@sample_rows}"),
         {:ok, _, [[total]], _} <- query(conn, "SELECT count(*) FROM #{ident(table)}") do
      more =
        if total > length(rows),
          do:
            "\n[#{total - length(rows)} more rows; use :#{table}?limit=#{@default_limit}&offset=#{length(rows)} to continue]",
          else: ""

      {:ok, sql <> "\n\n" <> render_table(columns, rows) <> more}
    end
  end

  defp render(conn, {:page, table, page}) do
    where = if page.where, do: " WHERE " <> page.where, else: ""
    order = if page.order, do: " ORDER BY " <> page.order, else: ""

    with {:ok, _} <- table_sql(conn, table),
         {:ok, _, [[total]], _} <- query(conn, "SELECT count(*) FROM #{ident(table)}#{where}"),
         {:ok, columns, rows, _} <-
           query(
             conn,
             "SELECT * FROM #{ident(table)}#{where}#{order} LIMIT ? OFFSET ?",
             [page.limit, page.offset]
           ) do
      shown = length(rows)
      header = "Rows #{page.offset + min(shown, 1)}-#{page.offset + shown} of #{total}"
      next = page.offset + shown

      footer =
        if next < total, do: "\n[Use offset=#{next} for the next page]", else: ""

      {:ok, header <> "\n" <> render_table(columns, rows) <> footer}
    end
  end

  defp render(conn, {:row, table, key}) do
    with {:ok, _} <- table_sql(conn, table),
         {:ok, lookup} <- row_lookup(conn, table),
         {:ok, columns, rows, _} <-
           query(conn, "SELECT * FROM #{ident(table)} WHERE #{lookup} = ? LIMIT 1", [
             coerce_key(key)
           ]) do
      case rows do
        [row] ->
          {:ok,
           Enum.zip_with(columns, row, fn column, value -> "#{column}: #{cell(value, :full)}" end)
           |> Enum.join("\n")}

        [] ->
          {:ok, "No row found in table '#{table}' for key '#{key}'."}
      end
    end
  end

  defp render(conn, {:raw, sql}) do
    with {:ok, columns, rows, truncated?} <- query(conn, sql, [], @max_raw_rows) do
      cap =
        if truncated?,
          do: "\n[Output capped at #{@max_raw_rows} rows; add LIMIT/OFFSET to page]",
          else: ""

      {:ok, "#{length(rows)} row(s)\n" <> render_table(columns, rows) <> cap}
    end
  end

  defp table_sql(conn, table) do
    case query(
           conn,
           "SELECT sql FROM sqlite_schema WHERE name = ? AND type IN ('table','view')",
           [table]
         ) do
      {:ok, _, [[sql]], _} -> {:ok, sql || "(no schema SQL)"}
      {:ok, _, [], _} -> {:error, "No table or view named '#{table}'"}
      {:error, _} = error -> error
    end
  end

  defp row_lookup(conn, table) do
    case query(conn, "SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk", [table]) do
      {:ok, _, [[column]], _} -> {:ok, ident(column)}
      {:ok, _, _, _} -> {:ok, "rowid"}
      {:error, _} = error -> error
    end
  end

  defp coerce_key(key) do
    case Integer.parse(key) do
      {n, ""} -> n
      _ -> key
    end
  end

  defp ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  defp render_table(columns, []), do: Enum.join(columns, " | ") <> "\n(no rows)"

  defp render_table(columns, rows) do
    cells = Enum.map(rows, fn row -> Enum.map(row, &cell(&1, :short)) end)

    widths =
      [columns | cells]
      |> Enum.zip_with(fn column_cells ->
        column_cells |> Enum.map(&String.length/1) |> Enum.max()
      end)
      |> Enum.map(&min(&1, 40))

    line = fn values ->
      values
      |> Enum.zip_with(widths, fn value, width -> String.pad_trailing(value, width) end)
      |> Enum.join(" | ")
      |> String.trim_trailing()
    end

    separator = widths |> Enum.map(&String.duplicate("-", &1)) |> Enum.join("-+-")
    Enum.join([line.(columns), separator | Enum.map(cells, line)], "\n")
  end

  defp cell(nil, _), do: "NULL"
  defp cell(value, _) when is_integer(value) or is_float(value), do: to_string(value)

  defp cell(value, mode) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      text = value |> String.replace(["\r\n", "\n", "\r", "\t"], " ")

      if mode == :short and String.length(text) > @max_cell_chars,
        do: String.slice(text, 0, @max_cell_chars) <> "…",
        else: text
    else
      "<blob #{byte_size(value)} bytes>"
    end
  end

  defp cell(value, _), do: inspect(value)
end
