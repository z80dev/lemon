defmodule LemonControlPlane.Methods.BlueprintsSupport do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors

  @bundle_id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  def opts do
    Application.get_env(:lemon_control_plane, :blueprint_opts, [])
  end

  def catalog_root do
    LemonCore.Paths.home_path(["bundles"], Keyword.get(opts(), :profile_opts, []))
  end

  def bundle_path(bundle_id) when is_binary(bundle_id) do
    root = Path.expand(catalog_root())
    candidate = Path.expand(bundle_id, root)

    with true <-
           Regex.match?(@bundle_id_regex, bundle_id) ||
             safe_error(:invalid_bundle_id, "Bundle ID is invalid"),
         true <-
           Path.dirname(candidate) == root ||
             safe_error(:invalid_bundle_id, "Bundle ID is invalid"),
         :ok <- require_directory(root, :invalid_catalog),
         :ok <- require_directory(candidate, :bundle_not_found) do
      {:ok, candidate}
    end
  end

  def bundle_path(_), do: safe_error(:invalid_bundle_id, "Bundle ID is required")

  def service_opts(bundle_id) do
    opts()
    |> Keyword.drop([:catalog_root])
    |> Keyword.put(:expected_bundle_id, bundle_id)
  end

  def require_matching_id(%{"id" => bundle_id}, bundle_id), do: :ok

  def require_matching_id(_, _),
    do: safe_error(:bundle_id_mismatch, "Catalog bundle ID does not match its manifest")

  def result({:ok, payload}), do: {:ok, payload}

  def result({:error, {code, message}}) do
    protocol_code =
      cond do
        code in [:profile_not_found] ->
          :not_found

        code in [:conflict, :confirmation_mismatch, :skill_collision, :staged_bundle_changed] ->
          :conflict

        code in [
          :automation_create_failed,
          :skill_enable_failed,
          :skill_refresh_failed,
          :skill_write_failed
        ] ->
          :unavailable

        true ->
          :invalid_request
      end

    {:error, Errors.error(protocol_code, message)}
  end

  def result(_), do: {:error, Errors.internal_error("Blueprint operation failed")}

  defp require_directory(path, missing_code) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        safe_error(:symlink_not_allowed, "Bundle catalog paths cannot be symlinks")

      _ ->
        safe_error(missing_code, "Bundle catalog entry is unavailable")
    end
  end

  defp safe_error(code, message), do: {:error, {code, message}}
end

defmodule LemonControlPlane.Methods.BlueprintsList do
  @moduledoc "Lists portable skill and automation bundles from a bounded catalog directory."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BlueprintsSupport

  @impl true
  def name, do: "blueprints.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    BlueprintsSupport.catalog_root()
    |> LemonAutomation.Blueprint.list()
    |> BlueprintsSupport.result()
  end
end

defmodule LemonControlPlane.Methods.BlueprintsInspect do
  @moduledoc "Inspects a portable bundle without returning paths, prompts, or skill bodies."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BlueprintsSupport

  @impl true
  def name, do: "blueprints.inspect"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    bundle_id = params["bundleId"]

    with {:ok, path} <- BlueprintsSupport.bundle_path(bundle_id),
         {:ok, payload} <- LemonAutomation.Blueprint.inspect(path),
         :ok <- BlueprintsSupport.require_matching_id(payload, bundle_id) do
      {:ok, payload}
    end
    |> BlueprintsSupport.result()
  end
end

defmodule LemonControlPlane.Methods.BlueprintsValidate do
  @moduledoc "Validates and audits a portable bundle without mutation."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BlueprintsSupport

  @impl true
  def name, do: "blueprints.validate"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    bundle_id = params["bundleId"]

    with {:ok, path} <- BlueprintsSupport.bundle_path(bundle_id),
         {:ok, payload} <- LemonAutomation.Blueprint.validate(path),
         :ok <- BlueprintsSupport.require_matching_id(payload, bundle_id) do
      {:ok, payload}
    end
    |> BlueprintsSupport.result()
  end
end

defmodule LemonControlPlane.Methods.BlueprintsPreview do
  @moduledoc "Returns the digest-bound exact activation plan for a target profile."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BlueprintsSupport

  @impl true
  def name, do: "blueprints.preview"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    bundle_id = params["bundleId"]

    with {:ok, path} <- BlueprintsSupport.bundle_path(bundle_id) do
      LemonAutomation.Blueprint.preview(
        path,
        params["profileId"],
        BlueprintsSupport.service_opts(bundle_id)
      )
    end
    |> BlueprintsSupport.result()
  end
end

defmodule LemonControlPlane.Methods.BlueprintsActivate do
  @moduledoc "Activates one freshly confirmed profile bundle and cron blueprint."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.BlueprintsSupport

  @impl true
  def name, do: "blueprints.activate"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    bundle_id = params["bundleId"]

    with {:ok, path} <- BlueprintsSupport.bundle_path(bundle_id) do
      LemonAutomation.Blueprint.activate(
        path,
        params["profileId"],
        params["confirmationDigest"],
        BlueprintsSupport.service_opts(bundle_id)
      )
    end
    |> BlueprintsSupport.result()
  end
end
