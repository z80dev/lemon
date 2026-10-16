defmodule LemonChannels.DeliveryError do
  @moduledoc false

  # These errors do not prove that a non-idempotent platform write was rejected.
  def classify(:timeout), do: {:outcome_unknown, :timeout}
  def classify(:closed), do: {:outcome_unknown, :closed}
  def classify({:timeout, _} = reason), do: {:outcome_unknown, reason}
  def classify({:closed, _} = reason), do: {:outcome_unknown, reason}

  def classify({:http_error, status, _} = reason) when status >= 500 and status < 600,
    do: {:outcome_unknown, reason}

  def classify(%{status_code: status} = reason) when status >= 500 and status < 600,
    do: {:outcome_unknown, reason}

  def classify(reason), do: reason

  @doc """
  Whether a delivery failure may have reached the platform, so the outbox
  retries it at-least-once with the same idempotency key instead of reporting
  it as terminal.

  Adapters return an ambiguous write as `{:outcome_unknown, reason}`; the
  email adapter reports `{:smtp, :timeout}`, its deadline, which can expire
  while the relay's acknowledgement is pending after the message was sent, and
  the Discord `*_crashed` wrappers are rescued adapter exceptions. A worker exit
  may have sent the message before dying. Definite rejections and local
  validation failures are not listed here and stay terminal.
  """
  @spec outcome_unknown?(term()) :: boolean()
  def outcome_unknown?(:outcome_unknown), do: true
  def outcome_unknown?({:outcome_unknown, _detail}), do: true
  def outcome_unknown?({:worker_exit, _reason}), do: true
  def outcome_unknown?({:discord_send_crashed, _error}), do: true
  def outcome_unknown?({:discord_file_crashed, _error}), do: true
  def outcome_unknown?({:discord_edit_crashed, _error}), do: true
  def outcome_unknown?({:smtp, :timeout}), do: true
  def outcome_unknown?(_reason), do: false
end
