defmodule LemonCore.ProviderManagement do
  @moduledoc """
  Bounded destination-local provider management boundary; credentials are write-only.

  The destination supplies `:cwd` locally for project override resolution. Filesystem
  options are never accepted in RPC parameters.

  Device operations bind the fixed product login ID to its target, provider, owner
  and session. Only the allowlisted device projection crosses this boundary;
  provider state and credentials stay with the destination-local implementation.

  `device.challenge` is internal: it adds an ephemeral destination-generated nonce
  to the public status only when credentials are ready. Its five-second lifetime
  is measured solely by the destination's monotonic clock and is never extended.
  `device.complete` consumes that exact nonce and one fixed completion ID, or
  settles the ID without writing. The destination checks its own nonce deadline
  again immediately before credential persistence. Challenges are never persisted;
  restart invalidates them. Settlement never requires the original node session
  and durably consumes delayed authorization, including after expiry or re-pair.
  Revocation never waits for completion. Unknown outcomes retain their fixed
  completion identity for non-writing settlement, never write retries.
  """
  @setting :provider_management_service
  @device_operations ~w(device.start device.poll device.challenge device.cancel device.complete)
  @operations ~w(list api_key.set disconnect default.set) ++ @device_operations
  @device_statuses ~w(starting pending completed denied expired cancelled lost failed)
  @device_fields Enum.map(
                   ~w(loginId targetId providerId status verificationUrl userCode expiresAtMs pollIntervalMs)a,
                   &{Atom.to_string(&1), &1}
                 )
  @verification_url "https://auth.openai.com/codex/device"
  @errors ~w(invalid_provider unsupported_method invalid_api_key invalid_model invalid_target invalid_request forbidden provider_binding_rejected config_read_failed invalid_config config_write_failed secret_read_failed secret_write_failed secret_delete_failed shared_credential rollback_failed reload_failed unavailable busy)a

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
        "list" ->
          []

        "api_key.set" ->
          ["targetId", "providerId", "value"]

        "disconnect" ->
          ["targetId", "providerId"]

        "default.set" ->
          ["targetId", "providerId", "modelId"]

        "device.complete" ->
          [
            "targetId",
            "providerId",
            "loginId",
            "ownerId",
            "sessionId",
            "completionId",
            "challengeNonce",
            "commit"
          ]

        operation when operation in @device_operations ->
          ["targetId", "providerId", "loginId", "ownerId", "sessionId"]

        _ ->
          nil
      end

    required = if node? and fields, do: ["nodeId" | fields], else: fields

    if is_map(params) and is_list(required) and Enum.sort(Map.keys(params)) == Enum.sort(required) and
         Enum.all?(required, fn field ->
           case field do
             "commit" ->
               is_boolean(params[field])

             "challengeNonce" ->
               challenge_nonce?(params[field]) or
                 (params["commit"] == false and params[field] == "")

             "nodeId" ->
               identity?(params[field], 251)

             "targetId" ->
               identity?(params[field], 256)

             field when field in ["loginId", "ownerId", "sessionId", "completionId"] ->
               identity?(params[field], 256)

             "value" ->
               bounded?(params[field], 16_384)

             _ ->
               bounded?(params[field], 256)
           end
         end) and
         (operation not in @device_operations or params["providerId"] == "openai_codex") do
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

  defp challenge_nonce?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, value)

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

  @doc "Projects a destination device result without exposing private runtime state."
  def device_result(result, params) when is_map(result) and is_map(params) do
    projection =
      Map.new(@device_fields, fn {field, key} ->
        {field, Map.get(result, field, Map.get(result, key))}
      end)

    if projection["loginId"] == params["loginId"] and
         projection["targetId"] == params["targetId"] and
         projection["providerId"] == "openai_codex" and
         projection["status"] in @device_statuses and
         projection["verificationUrl"] in [nil, @verification_url] and
         (is_nil(projection["userCode"]) or
            (bounded?(projection["userCode"], 64) and
               Regex.match?(~r/\A[A-Za-z0-9-]+\z/, projection["userCode"]))) and
         nullable_integer?(projection["expiresAtMs"], 0, 9_007_199_254_740_991) and
         nullable_integer?(projection["pollIntervalMs"], 1_000, 60_000) and
         available_device_fields?(projection) do
      {:ok, projection}
    else
      {:error, :unavailable}
    end
  end

  def device_result(_, _), do: {:error, :unavailable}

  @doc "Projects an internal challenge; never use this projection for public clients."
  def device_challenge_result(result, params) when is_map(result) do
    nonce = Map.get(result, "challengeNonce", Map.get(result, :challengeNonce))

    with {:ok, public} <- device_result(result, params),
         true <- Map.has_key?(result, "challengeNonce") or Map.has_key?(result, :challengeNonce),
         true <- is_nil(nonce) or (public["status"] == "pending" and challenge_nonce?(nonce)) do
      {:ok, Map.put(public, "challengeNonce", nonce)}
    else
      _ -> {:error, :unavailable}
    end
  end

  def device_challenge_result(_, _), do: {:error, :unavailable}

  defp available_device_fields?(%{"status" => "pending"} = result),
    do:
      Enum.all?(
        ~w(verificationUrl userCode expiresAtMs pollIntervalMs),
        &(not is_nil(result[&1]))
      )

  defp available_device_fields?(result),
    do: Enum.all?(~w(verificationUrl userCode expiresAtMs pollIntervalMs), &is_nil(result[&1]))

  defp nullable_integer?(nil, _, _), do: true
  defp nullable_integer?(value, min, max), do: is_integer(value) and value >= min and value <= max

  defp call(operation, params, opts) do
    service = Keyword.get(opts, :service, service())

    args =
      case operation do
        "list" -> [[]]
        "api_key.set" -> [params["providerId"], params["value"], []]
        "disconnect" -> [params["providerId"], []]
        "default.set" -> [params["providerId"], params["modelId"], []]
        operation when operation in @device_operations -> [params, []]
      end

    function =
      case operation do
        "list" -> :list
        "api_key.set" -> :set_api_key
        "disconnect" -> :disconnect
        "default.set" -> :set_default
        "device.start" -> :device_start
        "device.poll" -> :device_poll
        "device.challenge" -> :device_challenge
        "device.cancel" -> :device_cancel
        "device.complete" -> :device_complete
      end

    args =
      List.replace_at(args, -1, Keyword.take(opts, [:target, :config_path, :cwd, :authority]))

    if is_atom(service) and not is_nil(service) and Code.ensure_loaded?(service) and
         function_exported?(service, function, length(args)) do
      case apply(service, function, args) do
        {:ok, result} when operation == "device.challenge" ->
          device_challenge_result(result, params)

        {:ok, result} when operation in @device_operations ->
          device_result(result, params)

        {:ok, listing} when is_map(listing) ->
          {:ok, listing}

        {:error, reason} when reason in @errors ->
          {:error, reason}

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end
end
