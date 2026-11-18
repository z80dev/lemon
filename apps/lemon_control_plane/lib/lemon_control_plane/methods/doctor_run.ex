defmodule LemonControlPlane.Methods.DoctorRun do
  @moduledoc """
  Handler for `doctor.run`: the `lemon doctor` check suite, run in the daemon.

  Runs `LemonCore.Doctor.report/1` — the same built-in and app-registered
  checks the CLI prints — which only reads configuration, secrets readiness,
  store/process state and `PATH`. The optional `botPublicUrl` checks an HTTPS
  callback origin against the controller's actual admission configuration using
  the same registered doctor check. It never writes a support bundle.

  The projection is bounded and redacted: at most 64 checks, each with
  `name`, `status` (`pass | warn | fail | skip`), `message` and `remediation`
  truncated to 480 bytes after `LemonCore.Doctor.Redaction.text/1` (secrets
  masked, filesystem paths replaced by `[path]`).

  Check text is not a fixed template set: configuration checks quote validator
  and TOML parser errors (which echo the offending configured value) and some
  checks put `Exception.message/1` into remediation. That text therefore needs
  `operator.admin`, like non-public `config.get` values. Other callers get each
  check's name, status and counts with fixed per-status guidance instead, and
  `detailsWithheld: true`.

  ## Response

      %{
        "overall" => "pass" | "warn" | "fail",
        "counts" => %{"pass" => 9, "warn" => 1, "fail" => 0, "skip" => 2},
        "checks" => [%{"name", "status", "message", "remediation"}],
        "detailsWithheld" => false,
        "truncated" => false,
        "generatedAtMs" => 1_700_000_000_000
      }
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonCore.Doctor.Report

  @max_checks 64
  @max_text_bytes 480

  @fixed_message %{
    pass: "Check passed.",
    warn: "Check reported a warning.",
    fail: "Check failed.",
    skip: "Check skipped."
  }
  @fixed_remediation "Details need operator.admin: run doctor.run with an admin operator " <>
                       "or `lemon doctor` on the host."
  @impl true
  def name, do: "doctor.run"

  @impl true
  def scopes, do: [:read]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx) do
    with {:ok, opts} <- doctor_options(params) do
      report(opts, admin?(ctx))
    end
  end

  defp admin?(%{auth: %{role: :operator} = auth}),
    do: Authorize.authorize(auth, name(), [:admin]) == :ok

  defp admin?(_ctx), do: false

  defp doctor_options(%{"botPublicUrl" => url}) do
    case LemonMCP.HTTP.OriginPolicy.canonical_https_origin(url) do
      {:ok, origin} -> {:ok, [runtime: :local, bot_public_url: origin]}
      _ -> {:error, {:invalid_params, "botPublicUrl must be an HTTPS origin.", nil}}
    end
  end

  defp doctor_options(_), do: {:ok, [runtime: :local]}

  defp report(opts, admin?) do
    report_fun =
      Application.get_env(:lemon_control_plane, :doctor_report_fun, &LemonCore.Doctor.report/1)

    report = report_fun.(opts)
    checks = Enum.take(report.checks, @max_checks)

    {:ok,
     Map.merge(
       if(opts[:bot_public_url], do: %{"botPublicOrigin" => opts[:bot_public_url]}, else: %{}),
       %{
         "overall" => report |> Report.overall() |> Atom.to_string(),
         "counts" => %{
           "pass" => report.pass,
           "warn" => report.warn,
           "fail" => report.fail,
           "skip" => report.skip
         },
         "checks" => Enum.map(checks, &project_check(&1, admin?)),
         "detailsWithheld" => not admin?,
         "truncated" => length(report.checks) > @max_checks,
         "generatedAtMs" => System.system_time(:millisecond),
         "cleanup" => %{
           "includesPaths" => false,
           "includesSecretValues" => false,
           "writesSupportBundle" => false
         }
       }
     )}
  end

  defp project_check(check, true) do
    %{
      "name" => safe_text(check.name),
      "status" => Atom.to_string(check.status),
      "message" => safe_text(check.message),
      "remediation" => safe_text(check.remediation)
    }
  end

  defp project_check(check, false) do
    %{
      "name" => safe_text(check.name),
      "status" => Atom.to_string(check.status),
      "message" => Map.get(@fixed_message, check.status),
      "remediation" => if(check.status in [:warn, :fail], do: @fixed_remediation)
    }
  end

  @doc false
  def safe_text(nil), do: nil

  def safe_text(text) when is_binary(text) do
    text
    |> LemonCore.Doctor.Redaction.text()
    |> truncate()
  end

  def safe_text(other), do: other |> inspect(limit: 5) |> safe_text()

  defp truncate(text) when byte_size(text) <= @max_text_bytes, do: text

  defp truncate(text) do
    text
    |> binary_part(0, @max_text_bytes)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
    |> Kernel.<>("…")
  end
end
