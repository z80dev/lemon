defmodule LemonControlPlane.APIWorkspace do
  @moduledoc """
  The working-directory boundary for non-admin API principals (the
  `LEMON_OPENAI_COMPAT_API_TOKEN` and `LEMON_ACP_API_TOKEN` tokens).

  The workspace is `gateway.default_cwd`, else the assistant home
  (`LemonCore.Cwd.channel_default_cwd/0`), resolved to its realpath. A caller
  directory is resolved relative to it and must stay inside it after every
  symlink is followed.
  """

  alias LemonCore.TrustedRoot

  @doc "Realpath of the API workspace."
  @spec root() :: {:ok, String.t()} | {:error, :unavailable}
  def root do
    case TrustedRoot.realpath(LemonCore.Cwd.channel_default_cwd()) do
      {:ok, root} -> {:ok, root}
      {:error, _} -> {:error, :unavailable}
    end
  end

  @doc "Realpath of `cwd` when it is a directory inside the API workspace."
  @spec confine(term()) :: {:ok, String.t()} | {:error, :outside | :unavailable}
  def confine(cwd) when is_binary(cwd) and cwd != "" do
    with {:ok, root} <- root() do
      case TrustedRoot.dir(Path.expand(cwd, root), root) do
        {:ok, real} -> {:ok, real}
        :error -> {:error, :outside}
      end
    end
  end

  def confine(_cwd), do: {:error, :outside}
end
