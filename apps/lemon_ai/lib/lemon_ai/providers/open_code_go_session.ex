defmodule LemonAi.Providers.OpenCodeGoSession do
  @moduledoc """
  Conversation and client-identification headers for the `opencode_go` provider.

  OpenCode Go (`https://opencode.ai/inference/go/openai/v1`) rejects requests that do not
  carry an `x-opencode-session` header with `400 MissingSessionID`. The value
  must be a stable identifier per conversation, reused for every request of
  that conversation (including retries).

  The id is taken from `StreamOptions.session_id` when callers provide one.
  Sessionless utility calls fall back to a fixed id derived from the system
  prompt, so the same agent role always routes consistently.

  Headers are only produced for the `opencode_go` provider; every other
  provider gets an empty map. The User-Agent identifies Lemon rather than Req.
  """

  alias LemonAi.Types.{Context, Model}

  @header "x-opencode-session"
  @providers [:opencode_go, "opencode_go"]
  @user_agent "lemon_ai"

  @doc "Name of the session header."
  @spec header_name() :: String.t()
  def header_name, do: @header

  @doc """
  Returns the extra request headers required by `model`'s provider.

  Returns a conversation ID and client User-Agent for `opencode_go` models;
  all other providers receive an empty map.
  """
  @spec headers(Model.t(), Context.t(), map()) :: %{optional(String.t()) => String.t()}
  def headers(%Model{provider: provider}, %Context{} = context, opts)
      when provider in @providers do
    %{@header => session_id(context, opts), "user-agent" => @user_agent}
  end

  def headers(_model, _context, _opts), do: %{}

  defp session_id(_context, %{session_id: id}) when is_binary(id) and id != "", do: id

  defp session_id(%Context{system_prompt: prompt}, _opts) do
    digest =
      (prompt || "")
      |> to_string()
      |> then(&:erlang.md5/1)
      |> Base.encode16(case: :lower)

    "lemon-" <> binary_part(digest, 0, 16)
  end
end
