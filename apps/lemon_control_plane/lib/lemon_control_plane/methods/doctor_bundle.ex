defmodule LemonControlPlane.Methods.DoctorBundle do
  @moduledoc """
  Handler for `doctor.bundle`: the support-bundle diagnostic sections,
  collected in the daemon.

  `lemon doctor --bundle` runs in a one-shot VM whose own browser, LSP, media,
  memory and channel probes would report that VM rather than the daemon. When
  a daemon answers, the CLI calls this method and writes the returned sections
  into the zip it builds locally.

  The sections come from `LemonCore.Doctor.SupportBundle.collect/1` for the
  daemon's working directory and are already passed through
  `LemonCore.Doctor.Redaction`: no absolute paths, chat/guild ids, credentials
  or exception terms. Admin scope, because the sections include the redacted
  shape of the daemon's configuration.

  ## Response

      %{"entries" => %{"media_diagnostics.json" => %{...}, ...}}
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "doctor.bundle"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(_params, _ctx) do
    {:ok, %{"entries" => LemonCore.Doctor.SupportBundle.collect()}}
  end
end
