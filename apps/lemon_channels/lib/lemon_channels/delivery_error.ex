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
end
