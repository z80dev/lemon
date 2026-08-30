defmodule LemonControlPlane.Methods.BlueprintsSupport do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors

  def opts do
    Application.get_env(:lemon_control_plane, :blueprint_opts, [])
  end

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
    LemonAutomation.Blueprint.Catalog.list(BlueprintsSupport.opts())
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
    LemonAutomation.Blueprint.Catalog.inspect(params["bundleId"], BlueprintsSupport.opts())
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
    LemonAutomation.Blueprint.Catalog.validate(params["bundleId"], BlueprintsSupport.opts())
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
    LemonAutomation.Blueprint.Catalog.preview(
      params["bundleId"],
      params["profileId"],
      BlueprintsSupport.opts()
    )
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
    LemonAutomation.Blueprint.Catalog.activate(
      params["bundleId"],
      params["profileId"],
      params["confirmationDigest"],
      BlueprintsSupport.opts()
    )
    |> BlueprintsSupport.result()
  end
end
