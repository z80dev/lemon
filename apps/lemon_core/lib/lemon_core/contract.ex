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
          | {:not_a_behaviour, term()}
          | {:not_loadable, module()}
          | {:missing_callbacks, module(), [callback()]}

  @doc """
  Validates that `module` is loadable and exports every required callback of
  `behaviour`.
  """
  @spec validate(term(), term()) :: :ok | {:error, error()}
  def validate(module, _behaviour) when not is_atom(module) or is_nil(module),
    do: {:error, {:not_a_module, module}}

  def validate(_module, behaviour) when not is_atom(behaviour) or is_nil(behaviour),
    do: {:error, {:not_a_behaviour, behaviour}}

  def validate(module, behaviour) do
    with :ok <- loadable(module),
         {:ok, required_callbacks} <- required_callbacks(behaviour) do
      missing_callbacks =
        Enum.reject(required_callbacks, fn {function, arity} ->
          function_exported?(module, function, arity)
        end)

      case missing_callbacks do
        [] -> :ok
        callbacks -> {:error, {:missing_callbacks, module, callbacks}}
      end
    end
  end

  defp required_callbacks(behaviour) do
    with {:module, ^behaviour} <- Code.ensure_loaded(behaviour),
         true <- function_exported?(behaviour, :behaviour_info, 1),
         {:ok, callbacks, optional_callbacks} <- behaviour_callbacks(behaviour) do
      {:ok, callbacks -- optional_callbacks}
    else
      _ -> {:error, {:not_a_behaviour, behaviour}}
    end
  rescue
    _ -> {:error, {:not_a_behaviour, behaviour}}
  catch
    _, _ -> {:error, {:not_a_behaviour, behaviour}}
  end

  defp behaviour_callbacks(behaviour) do
    callbacks = behaviour.behaviour_info(:callbacks)
    optional_callbacks = behaviour.behaviour_info(:optional_callbacks)

    if valid_callbacks?(callbacks) and valid_callbacks?(optional_callbacks) do
      {:ok, callbacks, optional_callbacks}
    else
      :error
    end
  end

  defp valid_callbacks?(callbacks) when is_list(callbacks) do
    Enum.all?(callbacks, fn
      {function, arity}
      when is_atom(function) and is_integer(arity) and arity >= 0 and arity <= 255 ->
        true

      _other ->
        false
    end)
  end

  defp valid_callbacks?(_callbacks), do: false

  defp loadable(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, _reason} -> {:error, {:not_loadable, module}}
    end
  rescue
    _ -> {:error, {:not_loadable, module}}
  catch
    _, _ -> {:error, {:not_loadable, module}}
  end
end
