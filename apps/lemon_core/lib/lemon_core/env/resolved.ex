defmodule LemonCore.Env.Resolved do
  @moduledoc """
  A single resolved environment variable, as produced by
  `LemonCore.Env.snapshot/0`.

  The custom `Inspect` implementation redacts `:value` whenever `secret?`
  is true, so accidentally logging or `IO.inspect`-ing a snapshot (e.g. in
  a doctor report) can't leak a credential.
  """

  @enforce_keys [:name, :env_var, :value, :source, :secret?]
  defstruct [:name, :env_var, :value, :source, :secret?]

  @type source :: :env | :alias | :default

  @type t :: %__MODULE__{
          name: atom(),
          env_var: String.t(),
          value: term(),
          source: source(),
          secret?: boolean()
        }
end

defimpl Inspect, for: LemonCore.Env.Resolved do
  def inspect(%LemonCore.Env.Resolved{} = resolved, _opts) do
    value_repr =
      cond do
        resolved.secret? and is_nil(resolved.value) -> "nil"
        resolved.secret? -> "\"***REDACTED***\""
        true -> Kernel.inspect(resolved.value)
      end

    "#LemonCore.Env.Resolved<#{resolved.name} (#{resolved.env_var}) = #{value_repr}, source: #{resolved.source}>"
  end
end
