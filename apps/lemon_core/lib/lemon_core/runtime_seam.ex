defmodule LemonCore.RuntimeSeam do
  @moduledoc """
  Shared registration and dispatch for optional runtime consumers.

  Domain bridges retain their behaviours, acknowledgements and failure policies;
  this module owns configuration, implementation validation and protected calls.
  Configuration uses the existing `:lemon_core` application keys, so runtime
  registration and application configuration have the same source of truth.

  A missing callback is distinct from a callback that raises, exits or throws.
  Mutating bridges must select `{:error, :outcome_unknown}` for all reached-call
  failures; this helper never retries a callback. Failure logging includes only
  the callback MFA and a fixed failure class, never arguments or exception terms.
  """

  require Logger

  @doc "Reads a single implementation registration."
  def provider(key) do
    case Application.get_env(:lemon_core, key) do
      %{impl: module} when is_atom(module) -> module
      module when is_atom(module) -> module
      _ -> nil
    end
  end

  @doc "Reads only the declared roles from a multi-role registration."
  def config(key, roles) do
    case Application.get_env(:lemon_core, key, %{}) do
      config when is_map(config) -> Map.take(config, roles)
      _ -> %{}
    end
  end

  @doc "Whether an implementation module is present and loadable."
  def available?(module),
    do: is_atom(module) and not is_nil(module) and Code.ensure_loaded?(module)

  @doc "Validates a complete behaviour implementation."
  def validate(module, behaviour), do: LemonCore.Contract.validate(module, behaviour)

  @doc "Registers a loadable module, optionally requiring a complete behaviour."
  def register(key, module, behaviour \\ nil) do
    result =
      if is_nil(behaviour), do: validate_loadable(module), else: validate(module, behaviour)

    with :ok <- result do
      Application.put_env(:lemon_core, key, module)
      :ok
    end
  end

  @doc "Removes a single implementation registration."
  def unregister(key) do
    Application.delete_env(:lemon_core, key)
    :ok
  end

  @doc "Configures a single optional implementation with replacement protection."
  def configure_provider(key, module, mode) do
    case {mode, provider(key)} do
      {:replace, _} -> put_provider(key, module)
      {:if_unset, nil} -> put_provider(key, module)
      {:if_unset, ^module} -> :ok
      {:if_unset, _existing} when is_nil(module) -> {:error, :already_configured}
      {:if_unset, existing} -> {:error, {:already_configured, existing}}
      {other, _} -> {:error, {:invalid_mode, other}}
    end
  end

  @doc """
  Configures declared roles atomically after validating all incoming modules.

  A role's validator is its behaviour module, `:module` for atom-only legacy
  registrations, or `:loadable`. Modes are `:replace`, `:merge`, `:safe_merge`.
  """
  def configure(key, incoming, roles, mode) do
    keys = Keyword.keys(roles)
    incoming = incoming |> Map.new() |> Map.take(keys)

    with :ok <- validate_config(incoming, roles),
         {:ok, merged} <- merge_config(config(key, keys), incoming, keys, mode) do
      Application.put_env(:lemon_core, key, merged)
      :ok
    end
  end

  @doc """
  Calls an optional implementation with explicit per-failure return values.

  Options are `:unavailable`, `:missing`, `:exception`, `:exit`, `:throw` and an optional
  `:log` label. Unspecified failure values default to `:unavailable`'s value.
  Callback results are returned unchanged for domain-level acknowledgement checks.
  """
  def invoke(module, function, args, opts) do
    cond do
      is_nil(module) ->
        Keyword.get(opts, :unavailable)

      available?(module) and function_exported?(module, function, length(args)) ->
        apply(module, function, args)

      true ->
        Keyword.get(opts, :missing, Keyword.get(opts, :unavailable))
    end
  rescue
    _ -> failed(module, function, args, opts, :exception, :exception)
  catch
    :exit, reason -> failed(module, function, args, opts, :exit, exit_class(reason))
    :throw, _ -> failed(module, function, args, opts, :throw, :throw)
  end

  defp failed(module, function, args, opts, kind, failure_class) do
    case Keyword.get(opts, :log) do
      nil -> :ok
      label -> log_failure(label, module, function, args, kind, failure_class)
    end

    Keyword.get(opts, kind, Keyword.get(opts, :unavailable))
  end

  defp log_failure(label, module, function, args, kind, failure_class) do
    message =
      "#{label} callback failed callback=#{Exception.format_mfa(module, function, length(args))} " <>
        "failure_class=#{failure_class}"

    if kind == :exit, do: Logger.warning(message), else: Logger.error(message)
  end

  defp exit_class(:noproc), do: :no_process
  defp exit_class({:noproc, _}), do: :no_process
  defp exit_class(:timeout), do: :timeout
  defp exit_class({:timeout, _}), do: :timeout
  defp exit_class(_), do: :exit

  defp validate_loadable(module) do
    if available?(module), do: :ok, else: {:error, {:not_loadable, module}}
  end

  defp put_provider(key, nil), do: unregister(key)

  defp put_provider(key, module) do
    Application.put_env(:lemon_core, key, %{impl: module})
    :ok
  end

  defp validate_config(incoming, roles) do
    Enum.reduce_while(incoming, :ok, fn {role, module}, :ok ->
      case validate_role(module, Keyword.fetch!(roles, role)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_implementation, role, reason}}}
      end
    end)
  end

  defp validate_role(nil, _), do: :ok
  defp validate_role(module, :module) when is_atom(module), do: :ok
  defp validate_role(module, :module), do: {:error, {:not_a_module, module}}
  defp validate_role(module, :loadable), do: validate_loadable(module)
  defp validate_role(module, behaviour), do: validate(module, behaviour)

  defp merge_config(_current, incoming, _keys, :replace), do: {:ok, compact(incoming)}

  defp merge_config(current, incoming, _keys, :merge),
    do: {:ok, current |> Map.merge(incoming) |> compact()}

  defp merge_config(current, incoming, keys, :safe_merge) do
    conflict =
      Enum.find(keys, fn key ->
        existing = Map.get(current, key)
        candidate = Map.get(incoming, key)
        not is_nil(existing) and not is_nil(candidate) and existing != candidate
      end)

    case conflict do
      nil -> merge_config(current, incoming, keys, :merge)
      key -> {:error, {:already_configured, key, Map.get(current, key), Map.get(incoming, key)}}
    end
  end

  defp merge_config(_current, _incoming, _keys, mode), do: {:error, {:invalid_mode, mode}}

  defp compact(config), do: Map.reject(config, fn {_key, value} -> is_nil(value) end)
end
