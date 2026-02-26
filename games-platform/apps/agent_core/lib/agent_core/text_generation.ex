defmodule AgentCore.TextGeneration do
  @moduledoc """
  Lightweight text completion bridge for apps that depend on `agent_core`.

  Keeps direct `Ai.*` calls inside `agent_core`, which lets callers stay
  within architecture boundaries.
  """

  @typedoc "Options for `complete_text/4`."
  @type option ::
          {:system_prompt, String.t() | nil}
          | {:complete_opts, map() | keyword()}
          | {:model_registry, module()}
          | {:context_module, module()}
          | {:ai_module, module()}

  @spec complete_text(atom(), String.t(), String.t(), [option()]) ::
          {:ok, String.t()} | {:error, term()}
  def complete_text(provider, model_id, prompt, opts \\ [])
      when is_atom(provider) and is_binary(model_id) and is_binary(prompt) and is_list(opts) do
    model_registry = Keyword.get(opts, :model_registry, Ai.Models)
    context_module = Keyword.get(opts, :context_module, Ai.Types.Context)
    ai_module = Keyword.get(opts, :ai_module, Ai)
    system_prompt = Keyword.get(opts, :system_prompt)
    complete_opts = Keyword.get(opts, :complete_opts, %{}) |> normalize_complete_opts()

    with model when not is_nil(model) <- model_registry.get_model(provider, model_id),
         context <-
           context_module.new(system_prompt: system_prompt)
           |> context_module.add_user_message(prompt),
         {:ok, message} <- ai_module.complete(model, context, complete_opts) do
      {:ok, ai_module.get_text(message)}
    else
      nil -> {:error, {:model_not_found, provider, model_id}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      {:error, {:ai_exception, Exception.message(e)}}
  end

  defp normalize_complete_opts(opts) when is_map(opts), do: opts
  defp normalize_complete_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_complete_opts(_), do: %{}
end
