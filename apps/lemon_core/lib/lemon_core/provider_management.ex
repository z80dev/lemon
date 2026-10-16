defmodule LemonCore.ProviderManagement do
  @moduledoc """
  Bounded destination-local provider management boundary; credentials are write-only.

  The destination supplies `:cwd` locally for project override resolution. Filesystem
  options are never accepted in RPC parameters.
  """
  @setting :provider_management_service
  @operations ~w(list api_key.set disconnect default.set)
  @errors ~w(invalid_provider unsupported_method invalid_api_key invalid_model invalid_target config_read_failed invalid_config config_write_failed secret_read_failed secret_write_failed secret_delete_failed shared_credential rollback_failed reload_failed unavailable busy)a

  def operations, do: @operations

  @doc "Registers the destination-local implementation at application startup."
  def register(service) when is_atom(service) and not is_nil(service) do
    if Code.ensure_loaded?(service) do
      Application.put_env(:lemon_core, @setting, service)
      :ok
    else
      {:error, :unavailable}
    end
  end

  @doc "Returns the registered implementation, or nil on runtimes without setup support."
  def service, do: Application.get_env(:lemon_core, @setting)

  def target(node_id \\ nil) do
    with {:ok, id} <- target_id(node_id),
         {:ok, hostname} <- :inet.gethostname() do
      {:ok, %{id: id, nodeId: node_id, hostname: to_string(hostname)}}
    else
      {:error, :invalid_target} = error -> error
      _ -> {:error, :unavailable}
    end
  end

  defp target_id(nil) do
    case LemonCore.Store.fetch(:provider_management_identity, :controller) do
      {:ok, nil} ->
        id = "controller:" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        case LemonCore.Store.put_new(:provider_management_identity, :controller, id) do
          :ok -> {:ok, id}
          _ -> existing_id()
        end

      {:ok, id} when is_binary(id) ->
        {:ok, id}

      _ ->
        {:error, :unavailable}
    end
  end

  defp target_id(node_id) when is_binary(node_id) and byte_size(node_id) in 1..251 do
    if identity?(node_id, 251), do: {:ok, "node:" <> node_id}, else: {:error, :invalid_target}
  end

  defp target_id(_), do: {:error, :invalid_target}

  defp existing_id do
    case LemonCore.Store.fetch(:provider_management_identity, :controller) do
      {:ok, id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :unavailable}
    end
  end

  def validate(operation, params, node? \\ false) do
    fields =
      case operation do
        "list" -> []
        "api_key.set" -> ["targetId", "providerId", "value"]
        "disconnect" -> ["targetId", "providerId"]
        "default.set" -> ["targetId", "providerId", "modelId"]
        _ -> nil
      end

    required = if node? and fields, do: ["nodeId" | fields], else: fields

    if is_map(params) and is_list(required) and Enum.sort(Map.keys(params)) == Enum.sort(required) and
         Enum.all?(required, fn field ->
           case field do
             "nodeId" -> identity?(params[field], 251)
             "targetId" -> identity?(params[field], 256)
             "value" -> bounded?(params[field], 16_384)
             _ -> bounded?(params[field], 256)
           end
         end) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp bounded?(value, max) when is_binary(value),
    do:
      byte_size(value) in 1..max and String.valid?(value) and String.trim(value) != "" and
        not String.contains?(value, <<0>>)

  defp bounded?(_, _), do: false

  defp identity?(value, max),
    do: bounded?(value, max) and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value)

  def execute(operation, params, opts \\ []) do
    with :ok <- validate(operation, params),
         {:ok, target} <- target(Keyword.get(opts, :node_id)),
         :ok <- exact_target(operation, params, target) do
      call(operation, params, Keyword.put(opts, :target, target))
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp exact_target("list", _, _), do: :ok
  defp exact_target(_, %{"targetId" => id}, %{id: id}), do: :ok
  defp exact_target(_, _, _), do: {:error, :target_mismatch}

  defp call(operation, params, opts) do
    service = Keyword.get(opts, :service, service())

    args =
      case operation do
        "list" -> [[]]
        "api_key.set" -> [params["providerId"], params["value"], []]
        "disconnect" -> [params["providerId"], []]
        "default.set" -> [params["providerId"], params["modelId"], []]
      end

    function =
      case operation do
        "list" -> :list
        "api_key.set" -> :set_api_key
        "disconnect" -> :disconnect
        "default.set" -> :set_default
      end

    args = List.replace_at(args, -1, Keyword.take(opts, [:target, :config_path, :cwd]))

    if is_atom(service) and not is_nil(service) and Code.ensure_loaded?(service) and
         function_exported?(service, function, length(args)) do
      case apply(service, function, args) do
        {:ok, listing} when is_map(listing) -> {:ok, listing}
        {:error, reason} when reason in @errors -> {:error, reason}
        _ -> {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end
end
