defmodule LemonSkills.InstallPlan do
  @moduledoc """
  A fully-resolved install plan produced before any filesystem work begins.

  `LemonSkills.Installer` builds an `InstallPlan` from a user-facing identifier
  after source routing and scoping decisions are made. Callers can inspect the
  plan (e.g. for approval UIs) before executing it.

  ## Fields

  - `source_module` — source module that will perform `fetch/3`
  - `source_id` — canonical identifier within the source (nil for builtins)
  - `source_kind` — `:builtin | :local | :git | :registry | :well_known`
  - `trust_level` — trust assigned by the source module
  - `skill_name` — directory name / skill key for the install
  - `dest_dir` — absolute filesystem path where the skill will land
  - `scope` — `:global | {:project, cwd}` — where lockfile is written
  - `force` — whether to overwrite an existing install
  """

  @enforce_keys [:source_module, :source_id, :source_kind, :trust_level, :skill_name, :dest_dir, :scope]
  defstruct [
    :source_module,
    :source_id,
    :source_kind,
    :trust_level,
    :skill_name,
    :dest_dir,
    :scope,
    force: false
  ]

  @type scope :: :global | {:project, String.t()}

  @type t :: %__MODULE__{
          source_module: module(),
          source_id: String.t() | nil,
          source_kind: LemonSkills.Entry.source_kind(),
          trust_level: LemonSkills.Entry.trust_level(),
          skill_name: String.t(),
          dest_dir: String.t(),
          scope: scope(),
          force: boolean()
        }
end
