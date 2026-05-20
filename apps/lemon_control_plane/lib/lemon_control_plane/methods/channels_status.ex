defmodule LemonControlPlane.Methods.ChannelsStatus do
  @moduledoc """
  Handler for the channels.status method.

  Returns the status of all configured channel adapters.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "channels.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    channels = get_channels_status()
    diagnostics = channel_diagnostics(params || %{}) |> stringify_keys()
    proofs = channel_proofs(params || %{}) |> stringify_keys()
    readiness = channel_readiness(params || %{}) |> stringify_keys()

    {:ok,
     %{
       "channels" => channels,
       "diagnostics" => diagnostics,
       "proofs" => proofs,
       "readiness" => readiness,
       "summary" => summary(channels, diagnostics, proofs, readiness)
     }}
  end

  defp get_channels_status do
    if Code.ensure_loaded?(LemonChannels.Registry) do
      case LemonChannels.Registry.list() do
        adapters when is_list(adapters) ->
          Enum.map(adapters, &format_channel_status/1)

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp format_channel_status({channel_id, adapter_info}) do
    %{
      "channelId" => channel_id,
      "type" => to_string(adapter_info[:type] || :unknown),
      "status" => to_string(adapter_info[:status] || :unknown),
      "accountId" => adapter_info[:account_id],
      "capabilities" => adapter_info[:capabilities] || %{}
    }
  end

  defp format_channel_status(adapter) when is_map(adapter) do
    %{
      "channelId" => adapter[:channel_id] || adapter[:id],
      "type" => to_string(adapter[:type] || :unknown),
      "status" => to_string(adapter[:status] || :unknown),
      "accountId" => adapter[:account_id],
      "capabilities" => adapter[:capabilities] || %{}
    }
  end

  defp channel_diagnostics(params) do
    opts =
      []
      |> maybe_put(:project_dir, get_param(params, "projectDir"))

    LemonCore.Doctor.ChannelDiagnostics.status(opts)
  rescue
    _ ->
      %{
        transports: [],
        binding_count: 0,
        unsupported_binding_count: 0,
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_secret_names: false,
          includes_chat_ids: false,
          includes_channel_ids: false,
          includes_guild_ids: false,
          includes_message_bodies: false
        }
      }
  end

  defp channel_proofs(params) do
    project_dir = get_param(params, "projectDir") || File.cwd!()

    status = LemonCore.Doctor.ProofDiagnostics.status(project_dir: project_dir, limit: 1_000)
    proofs = Map.get(status, :recent_proofs, [])
    checks = Map.get(status, :latest_checks, [])
    matching_proofs = Enum.filter(proofs, &channel_proof?/1)
    matching_checks = Enum.filter(checks, &channel_check?/1)

    %{
      recent_proofs: Enum.take(matching_proofs, 6),
      latest_checks: Enum.take(matching_checks, 12),
      proof_count: length(matching_proofs),
      check_count: length(matching_checks),
      cleanup: %{
        includes_raw_paths: false,
        includes_raw_filenames: false,
        includes_raw_proof_details: false,
        includes_raw_prompts: false,
        includes_raw_provider_responses: false,
        embeds_proof_file_contents: false
      }
    }
  rescue
    error ->
      %{
        recent_proofs: [],
        latest_checks: [],
        proof_count: 0,
        check_count: 0,
        cleanup: %{
          includes_raw_paths: false,
          includes_raw_filenames: false,
          includes_raw_proof_details: false,
          includes_raw_prompts: false,
          includes_raw_provider_responses: false,
          embeds_proof_file_contents: false
        },
        error: Exception.message(error)
      }
  end

  defp channel_readiness(params) do
    opts =
      []
      |> maybe_put(:project_dir, get_param(params, "projectDir"))

    LemonCore.Doctor.ChannelReadiness.status(opts)
  rescue
    error ->
      %{
        status: "unavailable",
        promoted_platforms: ["telegram", "discord"],
        gates: [],
        gate_count: 0,
        passed_count: 0,
        blocked_count: 0,
        warning_count: 0,
        skipped_count: 0,
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_secret_names: false,
          includes_chat_ids: false,
          includes_channel_ids: false,
          includes_guild_ids: false,
          includes_message_bodies: false,
          includes_raw_proof_paths: false,
          includes_raw_proof_details: false
        },
        error: Exception.message(error)
      }
  end

  defp channel_proof?(proof) do
    proof
    |> proof_text()
    |> channel_text?()
  end

  defp channel_check?(check) do
    [
      Map.get(check, :name),
      Map.get(check, :proof_object),
      Map.get(check, :reason_kind)
    ]
    |> safe_join()
    |> channel_text?()
  end

  defp proof_text(proof) do
    [
      Map.get(proof, :proof_object),
      Map.get(proof, :reason_kind),
      Map.get(proof, :provider),
      Map.get(proof, :proof_scopes, []) |> safe_join()
    ]
    |> safe_join()
  end

  defp safe_join(values) do
    values
    |> List.wrap()
    |> Enum.filter(&(not is_nil(&1)))
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
  end

  defp channel_text?(text) when is_binary(text) do
    text = String.downcase(text)

    String.contains?(text, "telegram") or
      String.contains?(text, "discord") or
      String.contains?(text, "channel")
  end

  defp channel_text?(_), do: false

  defp get_param(params, key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp summary(channels, diagnostics, proofs, readiness) do
    %{
      "channelCount" => length(channels),
      "diagnosticTransportCount" => length(Map.get(diagnostics, "transports", [])),
      "bindingCount" => Map.get(diagnostics, "binding_count", 0),
      "unsupportedBindingCount" => Map.get(diagnostics, "unsupported_binding_count", 0),
      "proofCount" => Map.get(proofs, "proof_count", 0),
      "checkCount" => Map.get(proofs, "check_count", 0),
      "launchGateStatus" => Map.get(readiness, "status", "unavailable"),
      "launchGateCount" => Map.get(readiness, "gate_count", 0),
      "launchGatePassedCount" => Map.get(readiness, "passed_count", 0),
      "launchGateBlockedCount" => Map.get(readiness, "blocked_count", 0),
      "launchGateWarningCount" => Map.get(readiness, "warning_count", 0),
      "launchGateStatuses" => launch_gate_statuses(readiness),
      "launchGateReasonKinds" => launch_gate_reason_kinds(readiness),
      "promotedPlatforms" => ["telegram", "discord"],
      "cleanup" => %{
        "includesRawBotTokens" => false,
        "includesSecretNames" => false,
        "includesChatIds" => false,
        "includesChannelIds" => false,
        "includesGuildIds" => false,
        "includesMessageBodies" => false,
        "includesRawProofPaths" => false,
        "includesRawProofDetails" => false,
        "includesRawPrompts" => false,
        "includesRawProviderResponses" => false
      }
    }
  end

  defp launch_gate_statuses(readiness) when is_map(readiness) do
    readiness
    |> Map.get("gates", [])
    |> Enum.flat_map(fn
      %{"id" => id, "status" => status} when is_binary(id) and is_binary(status) -> [{id, status}]
      _ -> []
    end)
    |> Map.new()
  end

  defp launch_gate_statuses(_), do: %{}

  defp launch_gate_reason_kinds(readiness) when is_map(readiness) do
    readiness
    |> Map.get("gates", [])
    |> Enum.flat_map(fn
      %{"id" => id, "reason_kind" => reason_kind}
      when is_binary(id) and is_binary(reason_kind) ->
        [{id, reason_kind}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp launch_gate_reason_kinds(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(nil), do: nil
  defp stringify_keys(value) when is_boolean(value), do: value
  defp stringify_keys(value) when is_atom(value), do: to_string(value)
  defp stringify_keys(value), do: value
end
