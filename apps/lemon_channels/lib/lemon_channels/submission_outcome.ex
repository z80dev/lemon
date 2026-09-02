defmodule LemonChannels.SubmissionOutcome do
  @moduledoc """
  Classifies router submission failures for transport delivery decisions.

  A definite rejection is safe for a transport to redeliver (or to forget a
  provisional dedupe marker). `:outcome_unknown` is different: the router may
  have accepted the run before its reply was lost, so transports retain their
  dedupe marker while telling the user that acceptance could not be confirmed.

  Error labels are deliberately bounded. Transport logs and user messages must
  not include arbitrary router terms, because they can contain prompt or
  provider data.
  """

  @type failure :: {:error, term()}

  @spec uncertain?(term()) :: boolean()
  def uncertain?({:error, :outcome_unknown}), do: true
  def uncertain?(_), do: false

  @spec retry_safe?(term()) :: boolean()
  def retry_safe?({:error, _} = failure), do: not uncertain?(failure)
  def retry_safe?(_), do: false

  @spec log_label(term()) :: atom()
  def log_label({:error, :outcome_unknown}), do: :outcome_unknown
  def log_label({:error, :unavailable}), do: :unavailable
  def log_label({:error, {:unexpected_answer, _}}), do: :unexpected_answer
  def log_label({:error, _}), do: :rejected
  def log_label(_), do: :unexpected_result
end
