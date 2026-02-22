defmodule LemonControlPlane.Methods.ConfigReload do
  @moduledoc """
  Handler for the `config.reload` control plane method.

  Triggers a runtime config reload and returns a summary of changes.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @allowed_reasons %{
    "manual" => :manual,
    "watcher" => :watcher,
    "poll" => :poll,
    "secrets_event" => :secrets_event
  }

  @impl true
  def name, do: "config.reload"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    opts =
      []
      |> maybe_put_sources(params["sources"])
      |> maybe_put_force(params["force"])
      |> maybe_put_reason(params["reason"])

    case LemonCore.ConfigReloader.reload(opts) do
      {:ok, result} ->
        {:ok,
         %{
           "reloadId" => result.reload_id,
           "changedSources" => Enum.map(result.changed_sources, &to_string/1),
           "changedPaths" => result.changed_paths,
           "appliedAtMs" => result.applied_at_ms,
           "actions" => result.actions,
           "warnings" => []
         }}

      {:error, :reload_in_progress} ->
        {:error, Errors.invalid_request("A reload is already in progress")}

      {:error, {:reload_failed, message}} ->
        {:error, Errors.internal_error("Config reload failed", message)}

      {:error, reason} ->
        {:error, Errors.internal_error("Config reload failed", inspect(reason))}
    end
  end

  defp maybe_put_sources(opts, nil), do: opts

  defp maybe_put_sources(opts, sources) when is_list(sources) do
    parsed =
      sources
      |> Enum.map(fn
        "files" -> :files
        "env" -> :env
        "secrets" -> :secrets
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if parsed == [], do: opts, else: Keyword.put(opts, :sources, parsed)
  end

  defp maybe_put_sources(opts, _), do: opts

  defp maybe_put_force(opts, true), do: Keyword.put(opts, :force, true)
  defp maybe_put_force(opts, _), do: opts

  defp maybe_put_reason(opts, reason) when is_binary(reason) do
    case Map.get(@allowed_reasons, String.trim(reason)) do
      nil -> opts
      parsed -> Keyword.put(opts, :reason, parsed)
    end
  end

  defp maybe_put_reason(opts, _), do: opts
end
