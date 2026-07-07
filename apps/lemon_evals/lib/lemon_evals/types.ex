defmodule LemonEvals.Types do
  @moduledoc """
  Shared typespecs for eval results produced by the LemonEvals harness and
  its extracted eval modules (`LemonEvals.Evals.*`).
  """

  @type eval_result :: %{
          name: String.t(),
          status: :pass | :fail,
          details: map()
        }

  @type run_report :: %{
          summary: %{passed: non_neg_integer(), failed: non_neg_integer()},
          results: [eval_result()]
        }
end
