defmodule LemonCore.Doctor.Redaction do
  @moduledoc """
  The one sharing policy for everything doctor emits: support bundle entries,
  the `lemon doctor` / `mix lemon.doctor` text and JSON renderers, and the
  control plane's `doctor.run` and `doctor.bundle` projections.

  Producers (often owned by other apps) are not trusted to have removed
  private data, so every value passes through here before it is written.

  Structured data (`data/1`):

    * values under credential-named keys (`LemonCore.Redact.sensitive_key?/1`)
      become `"[redacted]"`; under a structured value the leaves recurse;
    * chat, guild, channel, thread, peer, user and session id fields are
      dropped (key and value) unless they are boolean flags such as
      `includes_chat_ids: false`;
    * personal or user-chosen labels (owners, kanban columns, accounts,
      names, file names, emails, phone numbers, senders, hosts) become a
      `"sha:<hash>"` string or, for lists, `%{"count" => n}`;
    * map keys that look like numeric ids or paths are hashed;
    * a string that is wholly a path becomes
      `%{"path_hash" => ..., "exists" => boolean}`; other strings go through
      `text/1`;
    * terms with no JSON form (pids, refs, tuples, functions) become
      `"[term]"`.

  Free text (`text/1`): credentials masked by `LemonCore.Redact`, every URL
  collapsed to `scheme://[host:<hash>]` (no userinfo, path or query), quoted
  paths (spaces allowed) and unquoted absolute or
  home-relative paths (any number of components) become `[path]`, emails
  `[email]`, `+`-prefixed phone numbers `[phone]`, and runs of six or more
  digits, including after a colon (`chat:987654321`), `[id]`. Lemon slash
  commands named in remediation text (`/checkpoint`, `/login`) are kept.
  Producers interpolate known paths as `path_label/1` (or pass text through
  `replace_paths/2`) so paths with spaces never reach the text pass.

  `includes_raw_paths: false` in a section's cleanup block is therefore true
  by construction rather than by each producer's convention.
  """

  alias LemonCore.Doctor.Check

  @slash_commands ~w(checkpoint login)
  @slash_command_text ~r/\A\/(?:checkpoint|login)(?:\s|\z)/

  @quoted_path ~r/(["'`])(?:~|\.\.?)?\/[^"'`\n]*\1/u
  @path_token ~r/(?<![\w~.:\/-])(?:~|\.\.?)?\/[^\s"'`<>()\[\],;]+/u
  @whole_path ~r/\A(?:~|\.\.?)?\/[^\n"'`<>]*\z/u
  @url ~r/\b([a-z][a-z0-9+.-]*):\/\/(?:[^\/\s@"'<>]*@)?([^\/\s"'<>?#]*)[^\s"'<>]*/i
  @email ~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/
  @phone ~r/(?<![\w+])\+\d[\d\s().-]{6,}\d/
  @long_number ~r/(?<![\w.])-?\d{6,}(?![\w.])/

  @id_key ~r/(?:chat|guild|channel|thread|peer|user|session)ids?\z/
  @numeric_id ~r/\A-?\d{5,}\z/
  @label_keys ~w(
    owner owners column columns account accounts name names
    filename file_name artifact_name email emails sender senders allowed_senders
    phone phone_number inbox_number twilio_phone_number host hostname title
  )

  @doc "Redacts a JSON-ready term for sharing. Map keys become strings."
  @spec data(term()) :: term()
  def data(%{__struct__: _} = struct) do
    case Jason.encode(struct) do
      {:ok, json} -> json |> Jason.decode!() |> data()
      {:error, _} -> "[term]"
    end
  rescue
    _ -> "[term]"
  end

  def data(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      name = key_name(key)

      cond do
        name == nil ->
          acc

        id_key?(name) and not is_boolean(value) ->
          acc

        LemonCore.Redact.sensitive_key?(name) and not is_boolean(value) and
            not structured?(value) ->
          Map.put(acc, name, "[redacted]")

        label_key?(name) ->
          Map.put(acc, name, label(value))

        true ->
          Map.put(acc, name, data(value))
      end
    end)
  end

  def data(list) when is_list(list), do: Enum.map(list, &data/1)
  def data(value) when is_binary(value), do: string(value)
  def data(value) when is_boolean(value) or is_nil(value) or is_number(value), do: value
  def data(value) when is_atom(value), do: value |> Atom.to_string() |> string()
  def data(_other), do: "[term]"

  @doc "Redacts free text for sharing (see the module documentation)."
  @spec text(term()) :: String.t() | nil
  def text(nil), do: nil

  def text(value) when is_binary(value) do
    value
    |> LemonCore.Redact.text()
    |> then(&Regex.replace(@url, &1, fn _url, scheme, host -> url_summary(scheme, host) end))
    |> then(&Regex.replace(@quoted_path, &1, "\\1[path]\\1"))
    |> then(&Regex.replace(@path_token, &1, fn token -> path_token(token) end))
    |> then(&Regex.replace(@email, &1, "[email]"))
    |> then(&Regex.replace(@phone, &1, "[phone]"))
    |> then(&Regex.replace(@long_number, &1, "[id]"))
  end

  def text(value) when is_atom(value), do: value |> Atom.to_string() |> text()
  def text(_other), do: "[term]"

  @doc "A check with its name, message and remediation passed through `text/1`."
  @spec check(Check.t()) :: Check.t()
  def check(%Check{} = check) do
    %{
      check
      | name: text(check.name),
        message: text(check.message),
        remediation: text(check.remediation)
    }
  end

  @doc "A path's shareable form: a short hash and whether it exists."
  @spec path_ref(String.t()) :: map()
  def path_ref(path) when is_binary(path) do
    expanded = Path.expand(path)
    %{"path_hash" => hash(expanded), "exists" => File.exists?(expanded)}
  end

  @doc """
  The label a producer interpolates instead of a known path, so check text
  never carries path components (including ones with spaces) for `text/1` to
  miss.
  """
  @spec path_label(Path.t()) :: String.t()
  def path_label(path), do: "[path:#{hash(Path.expand(to_string(path)))}]"

  @doc "Replaces every occurrence of the given known paths in `text` by `path_label/1`."
  @spec replace_paths(String.t(), [Path.t()]) :: String.t()
  def replace_paths(text, paths) when is_binary(text) do
    paths
    |> Enum.flat_map(&[to_string(&1), Path.expand(to_string(&1))])
    |> Enum.uniq()
    |> Enum.reject(&(&1 in ["", "/"]))
    |> Enum.sort_by(&byte_size/1, :desc)
    |> Enum.reduce(text, &String.replace(&2, &1, path_label(&1)))
  end

  # A URL in shared text keeps only its scheme and a host hash: paths can carry
  # credentials (`/bot<token>/getMe`) and hosts can be private.
  defp url_summary(scheme, host),
    do: "#{String.downcase(scheme)}://[host:#{hash(String.downcase(host))}]"

  @doc "A short hash for values that must stay comparable but unreadable."
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value) do
    :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # A whole-string path may contain spaces; a slash command followed by
  # arguments (`/checkpoint diff <id>`) is text.
  defp string(value) do
    if value != "/" and Regex.match?(@whole_path, value) and
         not Regex.match?(@slash_command_text, value),
       do: path_ref(value),
       else: text(value)
  end

  defp path_token("/" <> command = token) do
    if command in @slash_commands, do: token, else: "[path]"
  end

  defp path_token(_token), do: "[path]"

  defp label(value) when is_binary(value), do: "sha:" <> hash(value)
  defp label(value) when is_list(value), do: %{"count" => length(value)}
  defp label(value) when is_map(value), do: data(value)
  defp label(value) when is_atom(value) or is_number(value), do: data(value)
  defp label(_value), do: "[term]"

  defp key_name(key) when is_binary(key), do: safe_key(key)

  defp key_name(key) when is_atom(key) and not is_nil(key),
    do: key |> Atom.to_string() |> safe_key()

  defp key_name(key) when is_integer(key), do: key |> Integer.to_string() |> safe_key()
  defp key_name(_key), do: nil

  # Keys can carry the private value themselves (a map keyed by chat id, by
  # email or by directory), so they get the same treatment as values.
  defp safe_key(key) do
    cond do
      Regex.match?(@numeric_id, key) -> "[id:#{hash(key)}]"
      String.contains?(key, "/") -> "[path:#{hash(Path.expand(key))}]"
      String.contains?(key, "@") -> "[label:#{hash(key)}]"
      true -> key
    end
  end

  defp structured?(value) when is_map(value), do: true
  defp structured?(value) when is_list(value), do: Enum.any?(value, &is_map/1)
  defp structured?(_value), do: false

  defp label_key?(name) do
    name = String.downcase(name)
    name in @label_keys or String.ends_with?(name, "_account")
  end

  defp id_key?(name) do
    normalized = name |> String.downcase() |> String.replace(["_", "-"], "")
    Regex.match?(@id_key, normalized)
  end
end
