defmodule LemonChannels.ProjectSelection do
  @moduledoc """
  `/cwd <project>` and `/new <project>` selection shared by Telegram and Discord.

  Only operator-configured project ids (`[gateway.projects]`) can be selected.
  Host paths are refused, and the selection is stored only as the chat scope's
  project override: chat never creates or retargets a project, so one chat
  cannot change where another chat bound to the same project runs. Errors do
  not echo host paths.
  """

  alias LemonChannels.BindingResolver
  alias LemonCore.{ChatScope, ProjectBindingStore}

  @path_refusal "Only configured project ids can be selected here; host paths are not accepted. " <>
                  "Ask the operator to add a [gateway.projects] entry."

  @doc "Resolve a selector to a configured project without persisting it."
  @spec resolve(term()) ::
          {:ok, %{id: String.t(), root: String.t()}} | {:error, String.t()} | :noop
  def resolve(selector) when is_binary(selector) do
    selector = String.trim(selector)

    cond do
      selector == "" ->
        :noop

      path_like?(selector) ->
        {:error, @path_refusal}

      true ->
        case BindingResolver.lookup_project(selector) do
          %{root: root} when is_binary(root) and root != "" ->
            root = Path.expand(root)

            if File.dir?(root),
              do: {:ok, %{id: selector, root: root}},
              else: {:error, "Configured project #{selector} is not available on this host."}

          _ ->
            {:error,
             "Unknown project: #{String.slice(selector, 0, 64)}. Only configured project ids can be selected."}
        end
    end
  end

  def resolve(_selector), do: :noop

  @doc "Bind a resolved project to the chat scope."
  @spec persist(ChatScope.t(), %{id: String.t(), root: String.t()}) ::
          {:ok, %{id: String.t(), root: String.t()}}
  def persist(%ChatScope{} = scope, %{id: id, root: root}) do
    :ok = ProjectBindingStore.put_override(scope, id)
    {:ok, %{id: id, root: root}}
  end

  @doc "Resolve and bind a selector for the chat scope."
  @spec select(ChatScope.t(), term()) ::
          {:ok, %{id: String.t(), root: String.t()}} | {:error, String.t()} | :noop
  def select(%ChatScope{} = scope, selector) do
    with {:ok, project} <- resolve(selector), do: persist(scope, project)
  end

  defp path_like?(selector) do
    String.starts_with?(selector, ["/", "~", "."]) or String.contains?(selector, ["/", "\\"])
  end
end
