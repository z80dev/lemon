defmodule LemonCore.Supervision do
  @moduledoc """
  Dependency-ordered OTP subtrees shared by runtime applications.

  Children start in list order. A child failure stops all later children in
  reverse order, then restarts them in list order. Put registries before their
  dynamic supervisors and managers so no live dependant retains a lost registry.

  The default restart intensity (10 restarts in 5 seconds) is a caller policy:
  contain a burst inside one dependency group before escalating to its parent.
  It is not a measured throughput limit. Callers may override either value.
  Temporary dynamic children are never replayed by this supervisor.
  """

  @spec subtree(atom(), [Supervisor.child_spec() | {module(), term()} | module()], keyword()) ::
          Supervisor.child_spec()
  def subtree(name, children, opts \\ []) do
    supervisor_opts =
      Keyword.merge(
        [name: name, strategy: :rest_for_one, max_restarts: 10, max_seconds: 5],
        opts
      )

    %{
      id: name,
      start: {Supervisor, :start_link, [children, supervisor_opts]},
      type: :supervisor
    }
  end
end
