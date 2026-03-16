defmodule LemonSkills.SkillView do
  @moduledoc """
  Unified metadata summary for a skill, used by both the system prompt renderer
  and the CLI display layer.

  `SkillView` decouples the prompt/CLI formatting code from the raw `Entry` +
  `Status` structs, giving callers a single well-typed shape that includes
  everything needed to render a skill entry in a UI.

  ## Building a view

      view = LemonSkills.SkillView.from_entry(entry, cwd: "/my/project")
      view.activation_state  # => :active | :not_ready | :hidden | ...
      view.missing_bins       # => ["kubectl"]

  ## Filtering for display

  Prompt renderers and CLI tools typically want only entries that might be
  relevant to show:

      views
      |> Enum.filter(&LemonSkills.SkillView.displayable?/1)
      |> LemonSkills.PromptView.render_skill_list()

  A view is `displayable?` when its `activation_state` is `:active` or
  `:not_ready` — i.e. the skill exists and is platform-compatible, just
  possibly missing some dependencies.
  """

  alias LemonSkills.{Entry, Manifest, Status}

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t(),
          path: String.t(),
          activation_state: Status.activation_state(),
          platform_compatible: boolean(),
          missing_bins: [String.t()],
          missing_env_vars: [String.t()],
          missing_tools: [String.t()],
          trust_level: Entry.trust_level() | nil,
          source_kind: Entry.source_kind() | nil,
          platforms: [String.t()]
        }

  @enforce_keys [:key, :path]
  defstruct [
    :key,
    :path,
    :trust_level,
    :source_kind,
    name: "",
    description: "",
    activation_state: :active,
    platform_compatible: true,
    missing_bins: [],
    missing_env_vars: [],
    missing_tools: [],
    platforms: ["any"]
  ]

  @doc """
  Build a `SkillView` from a skill `Entry` by running the status check.

  ## Options

  - `:cwd` — project working directory, forwarded to `Status.check_entry/2`
  """
  @spec from_entry(Entry.t(), keyword()) :: t()
  def from_entry(%Entry{} = entry, opts \\ []) do
    status = Status.check_entry(entry, opts)
    manifest = entry.manifest || %{}

    %__MODULE__{
      key: entry.key,
      name: entry.name || entry.key,
      description: entry.description || "",
      path: entry.path,
      activation_state: status.activation_state,
      platform_compatible: status.platform_compatible,
      missing_bins: status.missing_bins,
      missing_env_vars: status.missing_env_vars,
      missing_tools: status.missing_tools,
      trust_level: entry.trust_level,
      source_kind: entry.source_kind,
      platforms: Manifest.platforms(manifest)
    }
  end

  @doc """
  Return `true` for views that should be shown to the agent or in the CLI.

  A view is displayable when `activation_state` is `:active` or `:not_ready`.
  Hidden, platform-incompatible, and blocked skills are excluded from normal
  display.
  """
  @spec displayable?(t()) :: boolean()
  def displayable?(%__MODULE__{activation_state: state}),
    do: state in [:active, :not_ready]

  @doc """
  Return `true` when the skill is fully ready to use.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{activation_state: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @doc """
  Return a flat list of all missing items across bins, env vars, and tools.
  """
  @spec all_missing(t()) :: [String.t()]
  def all_missing(%__MODULE__{} = view) do
    view.missing_bins ++ view.missing_env_vars ++ view.missing_tools
  end
end
