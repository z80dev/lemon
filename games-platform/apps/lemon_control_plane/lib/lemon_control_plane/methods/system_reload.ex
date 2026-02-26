defmodule LemonControlPlane.Methods.SystemReload do
  @moduledoc """
  Handler for the `system.reload` control plane method.

  Supports scoped runtime reloads for modules, apps, extension files, or a
  unified system workflow.
  """

  @behaviour LemonControlPlane.Method

  alias Lemon.Reload
  alias LemonControlPlane.Protocol.Errors

  @allowed_scopes ~w(module app extension all)

  @default_reload_apps [
    :agent_core,
    :ai,
    :coding_agent,
    :coding_agent_ui,
    :lemon_core,
    :lemon_gateway,
    :lemon_router,
    :lemon_channels,
    :lemon_control_plane,
    :lemon_automation,
    :lemon_skills,
    :market_intel
  ]

  @impl true
  def name, do: "system.reload"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    scope = normalize_scope(params["scope"])

    if scope in @allowed_scopes do
      opts = reload_opts_from_params(params)

      case execute_reload(scope, params, opts) do
        {:ok, result} ->
          {:ok, to_payload(result)}

        {:error, :reload_in_progress} ->
          {:error, Errors.conflict("A reload is already in progress")}

        {:error, {code, _message} = error} when is_atom(code) ->
          {:error, error}

        {:error, {code, _message, _details} = error} when is_atom(code) ->
          {:error, error}

        {:error, reason} ->
          {:error, Errors.internal_error("Reload failed", inspect(reason))}
      end
    else
      scope_value = Map.get(params, "scope")

      {:error,
       Errors.invalid_request(
         "Invalid scope '#{inspect(scope_value)}'. Expected one of: #{Enum.join(@allowed_scopes, ", ")}"
       )}
    end
  end

  defp execute_reload("module", params, opts) do
    with {:ok, module} <- parse_module(params["module"] || params["moduleName"]) do
      Reload.reload_module(module, opts)
    end
  end

  defp execute_reload("app", params, opts) do
    with {:ok, app} <- parse_app(params["app"]) do
      Reload.reload_app(app, opts)
    end
  end

  defp execute_reload("extension", params, opts) do
    with {:ok, path} <- parse_path(params["path"]) do
      Reload.reload_extension(path, opts)
    end
  end

  defp execute_reload("all", params, opts) do
    apps =
      case parse_apps_list(params["apps"]) do
        [] -> loaded_apps()
        parsed -> parsed
      end

    extensions = parse_extensions_list(params["extensions"])

    code_change_targets =
      [
        %{server: LemonAutomation.CronManager, module: LemonAutomation.CronManager}
      ]

    opts =
      opts
      |> Keyword.put(:apps, apps)
      |> Keyword.put(:extensions, extensions)
      |> Keyword.put(:code_change_targets, code_change_targets)

    Reload.reload_system(opts)
  end

  defp loaded_apps do
    loaded =
      Application.loaded_applications()
      |> Enum.map(fn {app, _desc, _vsn} -> app end)
      |> MapSet.new()

    Enum.filter(@default_reload_apps, &MapSet.member?(loaded, &1))
  end

  defp parse_module(module_name) when is_binary(module_name) do
    module_name = String.trim(module_name)

    full_name =
      if String.starts_with?(module_name, "Elixir."),
        do: module_name,
        else: "Elixir." <> module_name

    module = :erlang.binary_to_existing_atom(full_name, :utf8)

    {:ok, module}
  rescue
    _ -> {:error, Errors.invalid_request("Invalid or unloaded module name")}
  end

  defp parse_module(_),
    do: {:error, Errors.invalid_request("module is required for scope=module")}

  defp parse_app(app) when is_binary(app) and app != "" do
    {:ok, :erlang.binary_to_existing_atom(app, :utf8)}
  rescue
    _ -> {:error, Errors.invalid_request("Invalid or unloaded app name")}
  end

  defp parse_app(_), do: {:error, Errors.invalid_request("app is required for scope=app")}

  defp parse_path(path) when is_binary(path) and path != "" do
    {:ok, Path.expand(path)}
  end

  defp parse_path(_), do: {:error, Errors.invalid_request("path is required for scope=extension")}

  defp parse_apps_list(apps) when is_list(apps) do
    apps
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn app ->
      try do
        :erlang.binary_to_existing_atom(app, :utf8)
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_apps_list(_), do: []

  defp parse_extensions_list(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
  end

  defp parse_extensions_list(_), do: []

  defp normalize_scope(scope) when is_binary(scope), do: String.trim(scope)
  defp normalize_scope(_), do: "all"

  defp reload_opts_from_params(params) do
    opts = []

    opts = if params["force"] == true, do: Keyword.put(opts, :force, true), else: opts

    opts
  end

  defp to_payload(result) do
    base = %{
      "status" => to_string(result.status),
      "kind" => to_string(result.kind),
      "target" => inspect(result.target),
      "reloaded" => Enum.map(result.reloaded, &inspect/1),
      "skipped" => Enum.map(result.skipped, &to_payload_item/1),
      "errors" => Enum.map(result.errors, &to_payload_item/1),
      "duration_ms" => result.duration_ms
    }

    case result.metadata do
      %{results: results} = metadata ->
        Map.merge(base, %{
          "results" => Enum.map(results, &result_to_map/1),
          "metadata" => Map.delete(metadata, :results)
        })

      metadata when is_map(metadata) ->
        base
        |> Map.put("results", [result_to_map(result)])
        |> Map.put("metadata", metadata)

      _ ->
        Map.put(base, "results", [result_to_map(result)])
    end
  end

  defp result_to_map(result) do
    %{
      "kind" => to_string(result.kind),
      "target" => inspect(result.target),
      "status" => to_string(result.status),
      "reloaded" => Enum.map(result.reloaded, &inspect/1),
      "skipped" => Enum.map(result.skipped, &to_payload_item/1),
      "errors" => Enum.map(result.errors, &to_payload_item/1),
      "duration_ms" => result.duration_ms,
      "metadata" => result.metadata
    }
  end

  defp to_payload_item(%{target: target, reason: reason}) do
    %{"target" => inspect(target), "reason" => inspect(reason)}
  end

  defp to_payload_item(other), do: %{"value" => inspect(other)}
end
