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
  truncated to 480 bytes after secret redaction and with filesystem paths
  replaced by `[path]`.

  ## Response

      %{
        "overall" => "pass" | "warn" | "fail",
        "counts" => %{"pass" => 9, "warn" => 1, "fail" => 0, "skip" => 2},
        "checks" => [%{"name", "status", "message", "remediation"}],
        "truncated" => false,
        "generatedAtMs" => 1_700_000_000_000
      }
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.Doctor.Report

  @max_checks 64
  @max_text_bytes 480
  @path_token ~r/(?<![\w~.-])(?:~|\.{1,2})?\/[^\s"'`<>()\[\],;]+/u

  @impl true
  def name, do: "doctor.run"

  @impl true
  def scopes, do: [:read]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) do
    with {:ok, opts} <- doctor_options(params) do
      report(opts)
    end
  end

  defp doctor_options(%{"botPublicUrl" => url}) do
    case LemonMCP.HTTP.OriginPolicy.canonical_https_origin(url) do
      {:ok, origin} -> {:ok, [runtime: :local, bot_public_url: origin]}
      _ -> {:error, {:invalid_params, "botPublicUrl must be an HTTPS origin.", nil}}
    end
  end

  defp doctor_options(_), do: {:ok, [runtime: :local]}

  defp report(opts) do
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
         "checks" => Enum.map(checks, &project_check/1),
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

  defp project_check(check) do
    %{
      "name" => safe_text(check.name),
      "status" => Atom.to_string(check.status),
      "message" => safe_text(check.message),
      "remediation" => safe_text(check.remediation)
    }
  end

  @doc false
  def safe_text(nil), do: nil

  def safe_text(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@path_token, &1, "[path]"))
    |> LemonCore.Redact.text()
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
