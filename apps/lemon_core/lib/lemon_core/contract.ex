defmodule LemonCore.Contract do
  @moduledoc """
  Validates configuration-injected modules against behaviours.

  Umbrella applications use module names in application configuration to
  invert dependencies across package boundaries. `validate/2` gives those
  seams one shared startup check: the implementation must be loadable and
  export every required callback. Optional callbacks declared by the
  behaviour are not required.

  This validates the static shape of an implementation. Callback return
  values and operational failures remain part of the behaviour's own runtime
  contract.
  """

  @type callback :: {atom(), arity()}
  @type error ::
          {:not_a_module, term()}
          | {:not_loadable, module()}
          | {:missing_callbacks, module(), [callback()]}

  @doc """
  Validates that `module` is loadable and exports every required callback of
  `behaviour`.
  """
  @spec validate(term(), module()) :: :ok | {:error, error()}
  def validate(module, behaviour)
      when is_atom(module) and not is_nil(module) and is_atom(behaviour) do
    with :ok <- loadable(module) do
      missing_callbacks =
        Enum.reject(required_callbacks(behaviour), fn {function, arity} ->
          function_exported?(module, function, arity)
        end)

      case missing_callbacks do
        [] -> :ok
        callbacks -> {:error, {:missing_callbacks, module, callbacks}}
      end
    end
  end

  def validate(other, _behaviour), do: {:error, {:not_a_module, other}}

  @doc "Every callback of `behaviour` that an implementation must export."
  @spec required_callbacks(module()) :: [callback()]
  def required_callbacks(behaviour) when is_atom(behaviour) do
    behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)
  end

  defp loadable(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, _reason} -> {:error, {:not_loadable, module}}
    end
  end
end
