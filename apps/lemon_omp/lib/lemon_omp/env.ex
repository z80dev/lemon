defmodule LemonOmp.Env do
  @moduledoc """
  Environment variables read by `lemon_omp`, the omp delegate driver.

  `LEMON_OMP_*` are Lemon's own knobs. `PI_CODING_AGENT_DIR` and `PI_CONFIG_DIR`
  belong to omp; they are declared here because session discovery must look
  where the omp processes Lemon starts (which inherit them) write. Aggregated by
  `LemonCore.Env` through the `:env_registries` list; `LemonOmp.Config` reads them.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :omp_bin,
      env_var: "LEMON_OMP_BIN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path or name of the omp executable. Defaults to the first `omp` on PATH.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    },
    %{
      name: :omp_max_sessions,
      env_var: "LEMON_OMP_MAX_SESSIONS",
      aliases: [],
      type: :integer,
      default: 4,
      doc: "Maximum number of live omp processes Lemon supervises at once.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    },
    %{
      name: :omp_idle_timeout_ms,
      env_var: "LEMON_OMP_IDLE_TIMEOUT_MS",
      aliases: [],
      type: :integer,
      default: 1_800_000,
      doc:
        "Close an idle omp process after this many milliseconds (0 disables). Sessions stay resumable.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    },
    %{
      name: :omp_approvals,
      env_var: "LEMON_OMP_APPROVALS",
      aliases: [],
      type: :string,
      default: "bridge",
      doc: "Tool approval prompts: bridge to Lemon approvals (default), or decline.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    },
    %{
      name: :omp_approval_timeout_ms,
      env_var: "LEMON_OMP_APPROVAL_TIMEOUT_MS",
      aliases: [],
      type: :integer,
      default: 600_000,
      doc: "Maximum wait for an omp tool approval, capped by the omp dialog timeout.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    },
    %{
      name: :omp_agent_dir,
      env_var: "PI_CODING_AGENT_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "omp's agent directory; Lemon reads `<dir>/sessions` for read-only session discovery.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    },
    %{
      name: :omp_config_dir,
      env_var: "PI_CONFIG_DIR",
      aliases: [],
      type: :string,
      default: ".omp",
      doc: "omp's config directory name under HOME, used when PI_CODING_AGENT_DIR is unset.",
      secret?: false,
      required?: false,
      area: :omp,
      apps: [:lemon_omp]
    }
  ]
end
