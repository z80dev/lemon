defmodule CodingAgent.ModelProvenance do
  @moduledoc """
  Where a session or child model came from, and the operator gate for
  project-origin child selections.

  A repository supplies project personas (the `.lemon`, `.omp` and `.claude`
  agent directories, see `CodingAgent.Subagents`) and a project
  `.lemon/config.toml` whose `model_roles`, `runtime.task.agent_models`,
  `defaults.model`/`defaults.provider` and `defaults.thinking_level`
  ProjectLayer admits as preferences. None of them is operator authority.

  ## Provenance

  Every decision reads the provenance pair loaded with the settings
  (`SettingsManager.t()` `:provenance`: the operator's settings alone and the
  admitted project layer, from the same config read), never the disk, so it
  always describes the values in use and is refreshed only with them.
  Settings without provenance (built in code, not loaded) are operator-owned.

  A model and its origin are resolved together (`resolve/3`): a `@role`
  selector's origin follows the same expansion as its model, through operator
  aliases, project-defined roles, and the fallback an unconfigured built-in
  role (`@default`, `@smol`, `@slow`, `@plan`, `@commit`) takes: the parent
  model with its recorded origin, else the configured default with its own.

  A session records its model's origin (`:project` or `:operator`) with every
  model transition: a project role or project default gives `:project`; an
  explicit user or operator choice gives `:operator`. The journal stores it
  with each model change.

  ## Child gate

  A child selection whose effective origin is the project passes the same
  operator-owned `[runtime.task]` gate as an explicit task argument:

    * `per_call_model = "off"` (the default) refuses it;
    * `per_call_model = "on"` accepts it when `per_call_model_allow` is unset,
      or when the canonical `provider/model` it resolves to is listed (a
      provider switch therefore needs an allowlisted model of that provider).
      A literal `@role` entry only matches a role whose resolution is
      operator-origin.

  A refused selection is never applied silently: it is logged and the child
  falls back to the operator's own configuration (operator `model_roles.task`,
  else the inherited parent model unless that is itself project-origin, else
  the operator default model). Global and builtin personas and operator
  config remain operator-trusted, but a role they name is judged by where it
  resolves.

  ## Routing

  `[model_routing]` rules are operator-only (`LemonCore.Config.ProjectLayer`)
  and always resolve against the operator's settings (`prepare_routing/1`), so
  routing never resolves through project roles or defaults.
  """

  require Logger

  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager
  alias LemonAgent.ModelRuntime.ModelRouting

  @typedoc "Where a session's model came from."
  @type t :: :project | :operator

  @typedoc """
  Where a child's model selector came from: an explicit task argument (already
  gated by the preflight), operator configuration, a project persona, or a
  `runtime.task.agent_models` entry (project-origin when the project layer sets it).
  """
  @type launch_origin :: :explicit | :operator | :project | {:agent_models, String.t()} | nil

  @typedoc "A parent model with its recorded origin (nil when unknown)."
  @type parent :: {term(), t() | nil}

  @builtin_roles ~w(default smol slow plan commit)
  @max_role_depth 8

  @doc "The admitted project layer the settings were loaded with (`%{}` when none)."
  @spec project_layer(SettingsManager.t()) :: map()
  def project_layer(%SettingsManager{provenance: %{project: project}}), do: project
  def project_layer(%SettingsManager{}), do: %{}

  @doc "The operator's settings alone, from the same load (the settings themselves when not loaded)."
  @spec operator(SettingsManager.t()) :: SettingsManager.t()
  def operator(%SettingsManager{provenance: %{operator: operator}}), do: operator
  def operator(%SettingsManager{} = settings), do: settings

  @doc """
  Prepared `[model_routing]` for a session on `settings`: the effective table
  (operator rules, cost cap no higher than the operator's), with rule models
  resolved against the operator's settings.
  """
  @spec prepare_routing(SettingsManager.t()) :: term()
  def prepare_routing(%SettingsManager{} = settings) do
    operator = operator(settings)

    ModelRouting.prepare(
      settings.model_routing,
      &ModelResolver.resolve_session_model(&1, operator),
      settings.providers
    )
  end

  @doc """
  Resolves an operator-sourced session selector (an agent profile model or
  the router default) against the operator's settings alone, so a `@role`
  never expands through project `model_roles` or a project default. The
  resolution touches no project data, so its origin is `:operator`.
  """
  @spec resolve_operator(term(), SettingsManager.t()) :: {LemonAi.Types.Model.t(), t()}
  def resolve_operator(selector, %SettingsManager{} = settings),
    do: {ModelResolver.resolve_session_model(selector, operator(settings)), :operator}

  @doc """
  Resolves a child's model `selector` and its origin together, exactly as
  `ModelResolver.resolve_task_model/3` resolves the model.

  `nil` uses `model_roles.task` when configured, else the parent model. A
  `@role` expands through operator aliases and project-defined roles; an
  unconfigured built-in role falls back to the parent model (origin: the
  parent's) or, without one, the configured default (origin: `origin(nil, _)`).
  The origin is `:project` when any step of that resolution is project data.
  """
  @spec resolve(term(), SettingsManager.t(), parent()) :: {term(), t()}
  def resolve(selector, %SettingsManager{} = settings, {parent_model, _} = parent) do
    selector = selector || if(Map.has_key?(settings.model_roles || %{}, "task"), do: "@task")
    fallback_origin = fallback_origin(settings, parent)
    model = ModelResolver.resolve_task_model(selector, settings, parent_model)

    origin =
      if is_nil(selector),
        do: fallback_origin,
        else: selector_origin(selector, settings, fallback_origin)

    {model, origin}
  end

  # Origin of the model an unconfigured built-in role falls back to: the
  # parent with its recorded origin, else the configured default.
  defp fallback_origin(settings, {nil, _parent_origin}), do: origin(nil, settings)

  defp fallback_origin(settings, {parent_model, parent_origin}),
    do: parent_origin || origin(parent_model, settings)

  @doc """
  Origin of a model chosen without an explicit user or operator selection, as
  a session resolves it (an unconfigured built-in role falls back to the
  configured default): `selector` is `nil` (the configured default), a
  `@role`, or a concrete model whose selector is unknown (a journal entry
  without a recorded origin).
  """
  @spec origin(term(), SettingsManager.t()) :: t()
  def origin(nil, %SettingsManager{} = settings) do
    layer = project_layer(settings)

    cond do
      project_default?(layer) ->
        :project

      is_binary(default_selector(settings)) ->
        # A default role's own fallback has no default to fall back to.
        selector_origin(default_selector(settings), settings, :operator)

      true ->
        :operator
    end
  end

  def origin("@" <> _ = selector, %SettingsManager{} = settings),
    do: selector_origin(selector, settings, origin(nil, settings))

  def origin(model, %SettingsManager{} = settings) do
    if concrete_project?(model, project_layer(settings), settings),
      do: :project,
      else: :operator
  end

  defp default_selector(%SettingsManager{default_model: %{model_id: "@" <> _ = role}}), do: role
  defp default_selector(%SettingsManager{default_model: "@" <> _ = role}), do: role
  defp default_selector(_settings), do: nil

  # A concrete model of unknown selection counts as the operator's only when
  # the project influences no model choice or it is the operator default.
  defp concrete_project?(model, layer, settings) do
    influences? =
      project_default?(layer) or table(layer["model_roles"]) != %{} or
        project_agent_models(layer) != %{}

    influences? and canonical(model, settings) != canonical(nil, operator(settings))
  end

  @doc """
  Origin of a model restored from the journal (`SessionManager.build_session_context/1`):
  its journaled origin, else `:operator` for an explicit selection, else the
  conservative origin of a concrete model of unknown selection.
  """
  @spec restored(map(), SettingsManager.t()) :: t()
  def restored(%{model_origin: origin}, _settings) when origin in [:project, :operator],
    do: origin

  def restored(%{model_explicit: true}, _settings), do: :operator
  def restored(%{model: model}, settings), do: origin(model, settings)

  # The origin of `selector` along its role expansion; an unconfigured
  # built-in role takes `fallback_origin` (the origin of the model it falls
  # back to). Concrete selectors are operator-origin here; the caller adds the
  # origin of where the selector itself came from.
  defp selector_origin(selector, settings, fallback_origin),
    do: chain(selector, project_layer(settings), settings, fallback_origin, 0)

  defp chain(_selector, _layer, _settings, _fallback, depth) when depth > @max_role_depth,
    do: :project

  defp chain(selector, layer, settings, fallback, depth) when is_binary(selector) do
    case String.trim(selector) do
      "@" <> role ->
        cond do
          Map.has_key?(table(layer["model_roles"]), role) ->
            :project

          Map.has_key?(settings.model_roles || %{}, role) ->
            chain(settings.model_roles[role], layer, settings, fallback, depth + 1)

          role in @builtin_roles ->
            fallback

          # Unknown custom roles fail resolution.
          true ->
            :operator
        end

      _concrete ->
        :operator
    end
  end

  defp chain(_selector, _layer, _settings, _fallback, _depth), do: :operator

  defp project_default?(layer) do
    defaults = table(layer["defaults"])
    defaults["model"] not in [nil, ""] or defaults["provider"] not in [nil, ""]
  end

  @doc """
  Admits a delegated persona's model `selector` of `origin` (`:project` for a
  project persona, else `:operator`) against the parent's `settings` snapshot,
  resolved as a fresh session resolves it (an unconfigured built-in role falls
  back to the configured default).

  Returns `{model, origin}` with the concrete, fully qualified `provider:id`
  admitted here, so the delegated run (which loads its own cwd's settings)
  cannot re-resolve an alias differently; `nil` (logged) when the gate
  refuses it or it does not resolve, so the delegated run uses its operator
  profile and defaults.
  """
  @spec admit(term(), t(), SettingsManager.t()) :: {String.t(), t()} | nil
  def admit(nil, _origin, _settings), do: nil

  def admit(selector, origin, %SettingsManager{} = settings) do
    project? = origin == :project or origin(selector, settings) == :project

    with {:ok, qualified} <- admitted_model(selector, settings),
         true <- not project? or allowed?(selector, qualified, :project, settings) do
      {qualified, if(project?, do: :project, else: :operator)}
    else
      _ ->
        Logger.warning(
          "Delegated model #{describe(selector)} comes from project configuration and is " <>
            "not permitted by [runtime.task].per_call_model/per_call_model_allow (or does " <>
            "not resolve); using the operator's configuration instead"
        )

        nil
    end
  end

  @doc """
  An explicit delegated model selector resolved against the parent's
  `settings` snapshot: a `@role` becomes the concrete, fully qualified
  `provider:id` it resolves to there, with its origin (`:project` when the
  role resolves through project data); a concrete selector is qualified when
  it resolves and is operator-origin (an explicit choice).
  """
  @spec delegate(String.t(), SettingsManager.t()) ::
          {:ok, String.t(), t()} | {:error, String.t()}
  def delegate("@" <> _ = selector, %SettingsManager{} = settings) do
    case qualify(selector, settings) do
      {:ok, qualified} -> {:ok, qualified, origin(selector, settings)}
      :error -> {:error, "Model #{selector} does not resolve to a configured model"}
    end
  end

  def delegate(selector, %SettingsManager{} = settings) do
    case qualify(selector, settings) do
      {:ok, qualified} -> {:ok, qualified, :operator}
      :error -> {:ok, selector, :operator}
    end
  end

  # A `@role` must resolve here; a concrete selector that does not resolve is
  # passed on unchanged (it names no alias the destination could re-resolve).
  defp admitted_model("@" <> _ = selector, settings), do: qualify(selector, settings)

  defp admitted_model(selector, settings) do
    case qualify(selector, settings) do
      {:ok, qualified} -> {:ok, qualified}
      :error -> {:ok, selector}
    end
  end

  # The fully qualified `provider:id` a selector resolves to as a session.
  defp qualify(selector, settings) do
    case ModelResolver.resolve_session_model(selector, settings) do
      %LemonAi.Types.Model{provider: provider, id: id} -> {:ok, "#{provider}:#{id}"}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Resolves a child's model, gating project-origin selections.

  `selector`/`origin` come from the launch; `parent` is the inherited parent
  model with its recorded origin. The model and its effective origin come
  from `resolve/3`; the launch origin adds project personas and project
  `agent_models` entries. Returns `{model, origin}`: the model to start the
  child with and the origin the child records.
  """
  @spec resolve_child(term(), launch_origin(), SettingsManager.t(), parent()) :: {term(), t()}
  def resolve_child(selector, launch_origin, %SettingsManager{} = settings, parent) do
    layer = project_layer(settings)
    {model, resolved_origin} = resolve(selector, settings, parent)

    project? =
      resolved_origin == :project or launch_origin == :project or
        case launch_origin do
          {:agent_models, id} -> Map.has_key?(project_agent_models(layer), id)
          _ -> false
        end

    if not project? or allowed?(selector, model, resolved_origin, settings) do
      {model, if(project?, do: :project, else: :operator)}
    else
      Logger.warning(
        "Task child model #{describe(selector || model)} comes from project configuration " <>
          "and is not permitted by [runtime.task].per_call_model/per_call_model_allow; " <>
          "using the operator's configuration instead"
      )

      {operator_fallback(settings, parent), :operator}
    end
  end

  defp project_agent_models(layer),
    do: table(table(table(layer["runtime"])["task"])["agent_models"])

  # `model` is the selection's effective model; `resolved_origin` the origin
  # of its role expansion (a literal `@role` entry matches only an
  # operator-origin expansion).
  defp allowed?(selector, model, resolved_origin, settings) do
    task = settings.task || %{}

    case {Map.get(task, :per_call_model), Map.get(task, :per_call_model_allow)} do
      {"on", nil} ->
        true

      {"on", allow} when is_list(allow) ->
        (is_binary(selector) and selector in allow and
           (resolved_origin == :operator or not String.starts_with?(selector, "@"))) or
          canonical(model, settings) in allow

      _ ->
        false
    end
  end

  @doc """
  The `per_call_model_allow` rule for an explicit task argument, resolved
  against the launching session's `parent` exactly as the launch will: a
  `@role` matches only literally, and only when its resolution (including an
  unconfigured built-in role's fallback to the parent or default) is
  operator-origin; anything else matches literally or by the canonical
  `provider/model` it resolves to.
  """
  @spec allow_listed?(term(), [String.t()], SettingsManager.t(), parent()) :: boolean()
  def allow_listed?("@" <> _ = selector, allow, %SettingsManager{} = settings, parent),
    do:
      selector in allow and
        selector_origin(selector, settings, fallback_origin(settings, parent)) == :operator

  def allow_listed?(selector, allow, %SettingsManager{} = settings, _parent),
    do: selector in allow or canonical(selector, settings) in allow

  defp operator_fallback(settings, {parent_model, parent_origin}) do
    operator = operator(settings)

    parent_project? =
      not is_nil(parent_model) and
        (parent_origin || origin(parent_model, settings)) == :project

    parent =
      if is_nil(parent_model) or parent_project?,
        do: operator_default(operator),
        else: parent_model

    ModelResolver.resolve_task_model(nil, operator, parent) || operator_default(operator)
  end

  defp operator_default(operator) do
    ModelResolver.resolve_session_model(nil, operator)
  rescue
    _ -> nil
  end

  @doc "Canonical `provider/model` of a selector or model under `settings`, or nil."
  @spec canonical(term(), SettingsManager.t()) :: String.t() | nil
  def canonical(selector, settings) do
    case ModelResolver.resolve_session_model(selector, settings) do
      %LemonAi.Types.Model{provider: provider, id: id} -> "#{provider}/#{id}"
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Thinking level for a child: a project persona's level is applied only when
  `per_call_model = "on"`; otherwise it is dropped (logged) and the operator
  or parent level applies.
  """
  @spec thinking_level(String.t() | nil, launch_origin(), map()) :: String.t() | nil
  def thinking_level(level, :project, task_settings) when is_binary(level) do
    if Map.get(task_settings, :per_call_model) == "on" do
      level
    else
      Logger.warning(
        "Task child thinking level #{inspect(level)} comes from a project persona and " <>
          "[runtime.task].per_call_model is off; using the operator's level instead"
      )

      nil
    end
  end

  def thinking_level(level, _origin, _task_settings), do: level

  @doc """
  Thinking level to start a child with when the launch sets none. A child
  otherwise inherits `default_thinking_level`; when the project sets
  `defaults.thinking_level` and `per_call_model` is not `"on"`, the operator's
  default level is used instead (logged).
  """
  @spec child_thinking(term(), SettingsManager.t()) :: term()
  def child_thinking(level, _settings) when not is_nil(level), do: level

  def child_thinking(nil, %SettingsManager{} = settings) do
    project_level = table(project_layer(settings)["defaults"])["thinking_level"]

    if project_level in [nil, ""] or Map.get(settings.task || %{}, :per_call_model) == "on" do
      nil
    else
      Logger.warning(
        "Task child thinking level #{inspect(project_level)} comes from project defaults and " <>
          "[runtime.task].per_call_model is off; using the operator's level instead"
      )

      operator(settings).default_thinking_level
    end
  end

  defp describe(%LemonAi.Types.Model{provider: provider, id: id}), do: "#{provider}/#{id}"
  defp describe(selector), do: inspect(selector)

  defp table(value) when is_map(value), do: value
  defp table(_value), do: %{}
end
