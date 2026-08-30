defmodule LemonCore.Config.Secrets do
  @moduledoc """
  Canonical, fail-closed configuration for external secret sources.

  External sources are read-only adapters. They never replace the encrypted
  Lemon secret store and are disabled unless their source table contains the
  exact boolean `enabled = true`.
  """

  defmodule Source do
    @moduledoc "A validated external secret-source definition."

    @enforce_keys [:id, :type]
    defstruct id: nil,
              type: nil,
              enabled: false,
              priority: 100,
              executable: nil,
              timeout_ms: 3_000,
              max_output_bytes: 65_536,
              cache_ttl_ms: 0,
              refs: %{},
              account: nil,
              auth_secret: nil,
              auth_env: "OP_SERVICE_ACCOUNT_TOKEN",
              project_id: nil,
              access_token_secret: "BWS_ACCESS_TOKEN",
              access_token_env: "BWS_ACCESS_TOKEN",
              server_url: nil,
              argv: [],
              pass_env: [],
              secret_env: %{},
              valid?: true,
              errors: []

    @type source_type :: :onepassword | :bitwarden | :command | :invalid

    @type t :: %__MODULE__{
            id: String.t(),
            type: source_type(),
            enabled: boolean(),
            priority: non_neg_integer(),
            executable: String.t() | nil,
            timeout_ms: pos_integer(),
            max_output_bytes: pos_integer(),
            cache_ttl_ms: non_neg_integer(),
            refs: %{optional(String.t()) => String.t()},
            account: String.t() | nil,
            auth_secret: String.t() | nil,
            auth_env: String.t(),
            project_id: String.t() | nil,
            access_token_secret: String.t(),
            access_token_env: String.t(),
            server_url: String.t() | nil,
            argv: [String.t()],
            pass_env: [String.t()],
            secret_env: %{optional(String.t()) => String.t()},
            valid?: boolean(),
            errors: [String.t()]
          }
  end

  defstruct sources: [], errors: []

  @type t :: %__MODULE__{sources: [Source.t()], errors: [String.t()]}

  @top_keys ~w(sources)
  @common_keys ~w(type enabled priority executable timeout_ms max_output_bytes cache_ttl_ms)
  @type_keys %{
    onepassword: ~w(refs account auth_secret auth_env),
    bitwarden: ~w(project_id access_token_secret access_token_env server_url),
    command: ~w(argv pass_env secret_env)
  }
  @source_types Map.keys(@type_keys)
  @source_id ~r/^[a-z][a-z0-9_-]{0,63}$/
  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @safe_name ~r/^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$/
  @project_id ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/

  @doc "Resolves `[secrets.sources.<id>]` without executing any source."
  @spec resolve(map()) :: t()
  def resolve(settings) when is_map(settings) do
    raw = Map.get(settings, "secrets", %{})

    cond do
      is_nil(raw) ->
        %__MODULE__{}

      not is_map(raw) ->
        %__MODULE__{errors: ["secrets: must be a map"]}

      true ->
        top_errors = unknown_key_errors(raw, @top_keys, "secrets")
        {sources, source_errors} = resolve_sources(Map.get(raw, "sources", %{}))
        %__MODULE__{sources: sources, errors: top_errors ++ source_errors}
    end
  end

  def resolve(_), do: %__MODULE__{errors: ["configuration: must be a map"]}

  defp resolve_sources(nil), do: {[], []}

  defp resolve_sources(raw) when is_map(raw) do
    raw
    |> Enum.sort_by(fn {id, _value} -> to_string(id) end)
    |> Enum.map(fn {id, value} -> resolve_source(to_string(id), value) end)
    |> then(fn sources ->
      errors = Enum.flat_map(sources, & &1.errors)
      {Enum.sort_by(sources, &{&1.priority, &1.id}), errors}
    end)
  end

  defp resolve_sources(_), do: {[], ["secrets.sources: must be a map"]}

  defp resolve_source(id, raw) when is_map(raw) do
    type = parse_type(Map.get(raw, "type"))
    path = "secrets.sources.#{id}"
    allowed_keys = @common_keys ++ Map.get(@type_keys, type, [])

    source = %Source{
      id: id,
      type: type,
      enabled: Map.get(raw, "enabled") === true,
      priority: integer_or_default(Map.get(raw, "priority"), 100),
      executable: optional_string(Map.get(raw, "executable")),
      timeout_ms: integer_or_default(Map.get(raw, "timeout_ms"), 3_000),
      max_output_bytes: integer_or_default(Map.get(raw, "max_output_bytes"), 65_536),
      cache_ttl_ms: integer_or_default(Map.get(raw, "cache_ttl_ms"), 0),
      refs: string_map(Map.get(raw, "refs")),
      account: optional_string(Map.get(raw, "account")),
      auth_secret: optional_string(Map.get(raw, "auth_secret")),
      auth_env: optional_string(Map.get(raw, "auth_env")) || "OP_SERVICE_ACCOUNT_TOKEN",
      project_id: optional_string(Map.get(raw, "project_id")),
      access_token_secret:
        optional_string(Map.get(raw, "access_token_secret")) || "BWS_ACCESS_TOKEN",
      access_token_env: optional_string(Map.get(raw, "access_token_env")) || "BWS_ACCESS_TOKEN",
      server_url: optional_string(Map.get(raw, "server_url")),
      argv: string_list(Map.get(raw, "argv")),
      pass_env: string_list(Map.get(raw, "pass_env")),
      secret_env: string_map(Map.get(raw, "secret_env"))
    }

    errors =
      []
      |> append_errors(unknown_key_errors(raw, allowed_keys, path))
      |> validate_source_id(id, path)
      |> validate_type(type, path)
      |> validate_boolean_field(raw, "enabled", path)
      |> validate_integer_field(raw, "priority", 0, 1_000, path)
      |> validate_integer_field(raw, "timeout_ms", 100, 30_000, path)
      |> validate_integer_field(raw, "max_output_bytes", 1, 1_048_576, path)
      |> validate_integer_field(raw, "cache_ttl_ms", 0, 300_000, path)
      |> validate_optional_executable(raw, path)
      |> validate_type_specific(source, raw, path)

    %{source | valid?: errors == [], errors: errors}
  end

  defp resolve_source(id, _raw) do
    path = "secrets.sources.#{id}"

    %Source{
      id: id,
      type: :invalid,
      valid?: false,
      errors: ["#{path}: must be a map"]
    }
  end

  defp validate_type_specific(errors, %Source{type: :onepassword} = source, raw, path) do
    errors
    |> validate_string_map_field(raw, "refs", path)
    |> validate_non_empty_map(source.refs, "#{path}.refs")
    |> validate_names(source.refs, "#{path}.refs", :reference)
    |> validate_op_refs(source.refs, "#{path}.refs")
    |> validate_optional_string_field(raw, "account", path)
    |> validate_safe_name(source.auth_secret, "#{path}.auth_secret")
    |> validate_env_name(source.auth_env, "#{path}.auth_env")
  end

  defp validate_type_specific(errors, %Source{type: :bitwarden} = source, raw, path) do
    errors
    |> validate_optional_string_field(raw, "server_url", path)
    |> validate_required_project_id(source.project_id, "#{path}.project_id")
    |> validate_safe_name(source.access_token_secret, "#{path}.access_token_secret")
    |> validate_env_name(source.access_token_env, "#{path}.access_token_env")
    |> validate_server_url(source.server_url, "#{path}.server_url")
  end

  defp validate_type_specific(errors, %Source{type: :command} = source, raw, path) do
    errors
    |> validate_string_list_field(raw, "argv", path)
    |> validate_argv(source.argv, "#{path}.argv")
    |> validate_string_list_field(raw, "pass_env", path)
    |> validate_env_names(source.pass_env, "#{path}.pass_env")
    |> validate_string_map_field(raw, "secret_env", path)
    |> validate_secret_env(source.secret_env, "#{path}.secret_env")
  end

  defp validate_type_specific(errors, _source, _raw, _path), do: errors

  defp validate_source_id(errors, id, path) do
    if Regex.match?(@source_id, id), do: errors, else: errors ++ ["#{path}: invalid source id"]
  end

  defp validate_type(errors, type, _path) when type in @source_types, do: errors
  defp validate_type(errors, _type, path), do: errors ++ ["#{path}.type: unsupported source type"]

  defp validate_boolean_field(errors, raw, key, path) do
    case Map.fetch(raw, key) do
      :error -> errors
      {:ok, value} when is_boolean(value) -> errors
      {:ok, _value} -> errors ++ ["#{path}.#{key}: must be a boolean"]
    end
  end

  defp validate_integer_field(errors, raw, key, min, max, path) do
    case Map.fetch(raw, key) do
      :error -> errors
      {:ok, value} when is_integer(value) and value >= min and value <= max -> errors
      {:ok, _value} -> errors ++ ["#{path}.#{key}: must be an integer in #{min}..#{max}"]
    end
  end

  defp validate_optional_executable(errors, raw, path) do
    case Map.fetch(raw, "executable") do
      :error ->
        errors

      {:ok, value} when is_binary(value) ->
        validate_executable(errors, value, "#{path}.executable")

      {:ok, _value} ->
        errors ++ ["#{path}.executable: must be a string"]
    end
  end

  defp validate_executable(errors, value, path) do
    value = String.trim(value)

    cond do
      value == "" ->
        errors ++ ["#{path}: cannot be empty"]

      byte_size(value) > 4_096 ->
        errors ++ ["#{path}: is too long"]

      contains_control?(value) ->
        errors ++ ["#{path}: contains control characters"]

      String.contains?(value, ["/", "\\"]) and Path.type(value) != :absolute ->
        errors ++ ["#{path}: must be an absolute path or a bare executable name"]

      true ->
        errors
    end
  end

  defp validate_string_map_field(errors, raw, key, path) do
    case Map.fetch(raw, key) do
      :error ->
        errors

      {:ok, value} when is_map(value) ->
        if Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end),
          do: errors,
          else: errors ++ ["#{path}.#{key}: keys and values must be strings"]

      {:ok, _value} ->
        errors ++ ["#{path}.#{key}: must be a map"]
    end
  end

  defp validate_string_list_field(errors, raw, key, path) do
    case Map.fetch(raw, key) do
      :error ->
        errors

      {:ok, value} when is_list(value) ->
        if Enum.all?(value, &is_binary/1),
          do: errors,
          else: errors ++ ["#{path}.#{key}: entries must be strings"]

      {:ok, _value} ->
        errors ++ ["#{path}.#{key}: must be an array"]
    end
  end

  defp validate_optional_string_field(errors, raw, key, path) do
    case Map.fetch(raw, key) do
      :error -> errors
      {:ok, value} when is_binary(value) -> errors
      {:ok, _value} -> errors ++ ["#{path}.#{key}: must be a string"]
    end
  end

  defp validate_non_empty_map(errors, map, path) do
    if map_size(map) > 0, do: errors, else: errors ++ ["#{path}: must not be empty"]
  end

  defp validate_names(errors, map, path, _kind) do
    Enum.reduce(map, errors, fn {name, _value}, acc ->
      validate_safe_name(acc, name, "#{path} key")
    end)
  end

  defp validate_op_refs(errors, refs, path) do
    Enum.reduce(refs, errors, fn {_name, ref}, acc ->
      if String.starts_with?(ref, "op://") and byte_size(ref) <= 4_096 and
           not contains_control?(ref) do
        acc
      else
        acc ++ ["#{path}: every reference must be a bounded op:// reference"]
      end
    end)
  end

  defp validate_required_project_id(errors, value, path) do
    if is_binary(value) and Regex.match?(@project_id, value),
      do: errors,
      else: errors ++ ["#{path}: must be a non-option project id"]
  end

  defp validate_server_url(errors, nil, _path), do: errors

  defp validate_server_url(errors, value, path) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" ->
        errors

      _ ->
        errors ++ ["#{path}: must be an HTTPS URL without credentials, query, or fragment"]
    end
  end

  defp validate_argv(errors, [], path), do: errors ++ ["#{path}: must contain an executable"]

  defp validate_argv(errors, argv, path) when length(argv) > 32,
    do: errors ++ ["#{path}: must contain at most 32 entries"]

  defp validate_argv(errors, [executable | args], path) do
    errors = validate_executable(errors, executable, "#{path}[0]")

    Enum.reduce(args, errors, fn arg, acc ->
      cond do
        arg == "" -> acc
        byte_size(arg) > 4_096 -> acc ++ ["#{path}: entries must be at most 4096 bytes"]
        contains_control?(arg) -> acc ++ ["#{path}: entries may not contain control characters"]
        true -> acc
      end
    end)
  end

  defp validate_env_names(errors, names, path) do
    Enum.reduce(names, errors, fn name, acc -> validate_env_name(acc, name, path) end)
  end

  defp validate_secret_env(errors, mapping, path) do
    Enum.reduce(mapping, errors, fn {env_name, secret_name}, acc ->
      acc
      |> validate_env_name(env_name, "#{path} key")
      |> validate_safe_name(secret_name, "#{path} secret reference")
    end)
  end

  defp validate_env_name(errors, value, path) do
    if is_binary(value) and Regex.match?(@env_name, value),
      do: errors,
      else: errors ++ ["#{path}: must be an environment variable name"]
  end

  defp validate_safe_name(errors, nil, _path), do: errors

  defp validate_safe_name(errors, value, path) do
    if is_binary(value) and Regex.match?(@safe_name, value),
      do: errors,
      else: errors ++ ["#{path}: must be a bounded secret name"]
  end

  defp unknown_key_errors(map, allowed, path) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&"#{path}.#{&1}: unknown setting")
  end

  defp append_errors(errors, more), do: errors ++ more

  defp parse_type(value) when is_binary(value) do
    case String.trim(value) do
      "onepassword" -> :onepassword
      "bitwarden" -> :bitwarden
      "command" -> :command
      _ -> :invalid
    end
  end

  defp parse_type(_), do: :invalid

  defp integer_or_default(value, _default) when is_integer(value), do: value
  defp integer_or_default(_value, default), do: default

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_), do: nil

  defp string_list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp string_list(_), do: []

  defp string_map(value) when is_map(value) do
    value
    |> Enum.filter(fn {k, v} -> is_binary(k) and is_binary(v) end)
    |> Map.new()
  end

  defp string_map(_), do: %{}

  defp contains_control?(value) do
    String.contains?(value, ["\0", "\n", "\r"])
  end
end
