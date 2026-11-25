defmodule LemonControlPlane.Methods.SkillsSupport do
  @moduledoc false

  # Shared projection for installed-skill methods. The projection is an
  # allowlist: no filesystem paths, source identifiers (URLs/paths), manifest
  # bodies, environment values or raw audit text cross the wire. Missing
  # requirement *names* (binaries, environment variable names, tools) are kept,
  # bounded, because they are what an operator has to fix.

  alias LemonControlPlane.Protocol.Errors

  @max_skills 500
  @max_text 600
  @max_names 12
  @max_name_bytes 80

  def max_skills, do: @max_skills

  @doc "Validates the optional project `cwd` parameter."
  def cwd(params) do
    case params["cwd"] do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      cwd when is_binary(cwd) -> if Path.type(cwd) == :absolute, do: {:ok, cwd}, else: bad_cwd()
      _ -> bad_cwd()
    end
  end

  defp bad_cwd, do: {:error, Errors.invalid_request("cwd must be an absolute path")}

  @doc "Validates a skill key parameter."
  def skill_key(params) do
    case params["skillKey"] do
      key when is_binary(key) ->
        key = String.trim(key)

        if key != "" and byte_size(key) <= 200 and not String.contains?(key, ["/", "\\", <<0>>]),
          do: {:ok, key},
          else: {:error, Errors.invalid_request("skillKey is invalid")}

      _ ->
        {:error, Errors.invalid_request("skillKey is required")}
    end
  end

  @doc "Runs `fun` against the skill registry, mapping a stopped registry to `unavailable`."
  def with_registry(fun) do
    if Code.ensure_loaded?(LemonSkills.Registry) and Process.whereis(LemonSkills.Registry) do
      try do
        fun.()
      catch
        :exit, _ -> {:error, Errors.unavailable("Skill registry is unavailable")}
      end
    else
      {:error, Errors.unavailable("Skill registry is unavailable")}
    end
  end

  @doc "Error for an unusable `skills.json` state file (the doctor names it)."
  def state_unavailable,
    do: Errors.unavailable("Skill state is unreadable; run `lemon doctor`")

  @doc "Projects one registry entry plus its activation status."
  def project(entry, view) do
    manifest = entry.manifest || %{}

    %{
      "key" => text(entry.key, 200),
      "name" => text(entry.name || entry.key, 200),
      "description" => text(entry.description, @max_text),
      "scope" => scope(entry),
      "sourceKind" => atom_text(entry.source_kind),
      "trustLevel" => atom_text(entry.trust_level),
      "enabled" => view.activation_state != :hidden,
      "activation" => atom_text(view.activation_state),
      "auditStatus" => atom_text(entry.audit_status),
      "auditFindingCount" => length(List.wrap(entry.audit_findings)),
      "category" => text(LemonSkills.Manifest.lemon_category(manifest), 80),
      "platforms" => names(view.platforms),
      "missing" => %{
        "bins" => names(view.missing_bins),
        "envVars" => names(view.missing_env_vars),
        "tools" => names(view.missing_tools)
      },
      "installedAtMs" => datetime_ms(entry.installed_at),
      "updatedAtMs" => datetime_ms(entry.updated_at)
    }
  end

  def scope(%{source: :project}), do: "project"
  def scope(_entry), do: "global"

  defp atom_text(nil), do: nil
  defp atom_text(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_text(_), do: nil

  defp names(list) do
    list
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.take(@max_names)
    |> Enum.map(&text(&1, @max_name_bytes))
  end

  defp datetime_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp datetime_ms(_), do: nil

  @doc "Single-line, control-free, length-bounded text (nil for non-binaries)."
  def text(value, max) when is_binary(value) do
    value =
      value
      |> String.replace(~r/[\x00-\x1F\x7F\x{202A}-\x{202E}\x{2066}-\x{2069}]+/u, " ")
      |> String.trim()

    if String.length(value) > max, do: String.slice(value, 0, max - 1) <> "…", else: value
  end

  def text(_value, _max), do: nil
end

defmodule LemonControlPlane.Methods.SkillsList do
  @moduledoc """
  Handler for the read-only `skills.list` method: installed skills (global and,
  with `cwd`, that project's) with source kind, trust level, enabled state,
  activation status and missing-requirement names. Bounded allowlist projection.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SkillsSupport

  @impl true
  def name, do: "skills.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, cwd} <- SkillsSupport.cwd(params) do
      SkillsSupport.with_registry(fn ->
        case LemonSkills.Config.disabled_keys(cwd) do
          {:ok, disabled} -> {:ok, list(cwd, disabled)}
          {:error, _} -> {:error, SkillsSupport.state_unavailable()}
        end
      end)
    end
  end

  defp list(cwd, disabled) do
    entries = LemonSkills.Registry.list(cwd: cwd)

    skills =
      entries
      |> Enum.sort_by(& &1.key)
      |> Enum.take(SkillsSupport.max_skills())
      |> Enum.map(fn entry ->
        view = LemonSkills.SkillView.from_entry(entry, cwd: cwd, disabled_keys: disabled)
        SkillsSupport.project(entry, view)
      end)

    %{
      "skills" => skills,
      "summary" => %{
        "count" => length(entries),
        "returned" => length(skills),
        "truncated" => length(entries) > length(skills),
        "enabled" => Enum.count(skills, & &1["enabled"]),
        "projectScoped" => is_binary(cwd)
      }
    }
  end
end

defmodule LemonControlPlane.Methods.SkillsToggle do
  @moduledoc false

  # Shared implementation of `skills.enable` / `skills.disable`: writes the
  # owning scope's skills state through `LemonSkills.Config` (global state
  # for global skills, the project's state for project skills). A project
  # enable never lifts a global disable or an archive.

  alias LemonControlPlane.Methods.SkillsSupport
  alias LemonControlPlane.Protocol.Errors

  def handle(params, enabled?) do
    params = params || %{}

    with {:ok, cwd} <- SkillsSupport.cwd(params),
         {:ok, key} <- SkillsSupport.skill_key(params) do
      SkillsSupport.with_registry(fn ->
        case LemonSkills.Registry.get(key, cwd: cwd) do
          {:ok, entry} -> apply_toggle(entry, key, cwd, enabled?)
          :error -> {:error, Errors.not_found("Skill not found")}
        end
      end)
    end
  end

  defp apply_toggle(entry, key, cwd, enabled?) do
    scope = SkillsSupport.scope(entry)
    opts = [global: scope == "global", cwd: cwd]

    result =
      if enabled?,
        do: LemonSkills.Config.enable(key, opts),
        else: LemonSkills.Config.disable(key, opts)

    case result do
      :ok ->
        {:ok,
         %{
           "skillKey" => key,
           "enabled" => enabled?,
           "scope" => scope,
           "summary" => %{
             "action" => if(enabled?, do: "skills.enable", else: "skills.disable"),
             "configScope" => scope,
             "cleanup" => %{"includesPath" => false, "includesSource" => false}
           }
         }}

      {:error, :disabled_globally} ->
        {:error, Errors.conflict("Skill is disabled globally; enable it globally first")}

      {:error, :archived} ->
        {:error, Errors.conflict("Skill is archived; restore it before enabling")}

      {:error, {:skills_state, _scope, _reason}} ->
        {:error, SkillsSupport.state_unavailable()}

      {:error, _reason} ->
        {:error, Errors.internal_error("Unable to update skill configuration")}
    end
  end
end

defmodule LemonControlPlane.Methods.SkillsEnable do
  @moduledoc "Handler for `skills.enable` (admin): re-enables an installed skill."

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "skills.enable"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx), do: LemonControlPlane.Methods.SkillsToggle.handle(params, true)
end

defmodule LemonControlPlane.Methods.SkillsDisable do
  @moduledoc "Handler for `skills.disable` (admin): hides an installed skill from agents."

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "skills.disable"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx), do: LemonControlPlane.Methods.SkillsToggle.handle(params, false)
end
