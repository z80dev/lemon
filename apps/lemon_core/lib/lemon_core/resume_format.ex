defmodule LemonCore.ResumeFormat do
  @moduledoc """
  One engine's resume-command syntax: how to print it, and how to find it again.

  A resume command is vendor surface, not platform surface — `codex resume X`,
  `claude --resume X`, `opencode --session ses_X` are three different CLIs'
  spellings of the same idea. Core knows the *shape* of that knowledge; the
  vendor package owns the spelling and hands it over at boot:

      LemonCore.ResumeFormats.register(
        LemonCore.ResumeFormat.new("codex",
          pattern: ~r/`?codex\\s+resume\\s+([a-zA-Z0-9_-]+)`?/i,
          render: &MyVendor.render_resume/1
        )
      )

  ## Fields

    * `:engine` — the engine id the format belongs to.
    * `:pattern` — a regex matched *anywhere* in a blob of text. Its first
      capture group is the token value; there is rarely a reason for a second.
    * `:strict_pattern` — the anchored form, used to decide whether a whole line
      is nothing but a resume command. Derived from `:pattern` unless given.
    * `:render` — `(value -> command line)`. Prefer an external function capture
      (`&Mod.fun/1`): formats outlive a code reload in application env.
    * `:normalize` — optional `(captured -> value)`, for syntax where the
      captured text is not the value itself (pi's quoted session paths).
  """

  @enforce_keys [:engine, :pattern, :strict_pattern, :render]
  defstruct [:engine, :pattern, :strict_pattern, :render, :normalize]

  @type t :: %__MODULE__{
          engine: String.t(),
          pattern: Regex.t(),
          strict_pattern: Regex.t(),
          render: (String.t() -> String.t()),
          normalize: (String.t() -> String.t()) | nil
        }

  @doc """
  Builds a format. Raises `ArgumentError` on anything the parser could not use.

      iex> format =
      ...>   LemonCore.ResumeFormat.new("myengine",
      ...>     pattern: ~r/myengine\\s+resume\\s+(\\w+)/i,
      ...>     render: &("myengine resume " <> &1)
      ...>   )
      iex> LemonCore.ResumeFormat.capture(format, "run myengine resume abc now")
      "abc"
      iex> LemonCore.ResumeFormat.resume_line?(format, "run myengine resume abc now")
      false
      iex> LemonCore.ResumeFormat.resume_line?(format, "myengine resume abc")
      true
  """
  @spec new(String.t(), keyword()) :: t()
  def new(engine, opts) when is_binary(engine) and is_list(opts) do
    pattern = Keyword.fetch!(opts, :pattern)
    render = Keyword.fetch!(opts, :render)
    normalize = Keyword.get(opts, :normalize)

    validate!(engine, pattern, render, normalize)

    %__MODULE__{
      engine: engine,
      pattern: pattern,
      strict_pattern: Keyword.get_lazy(opts, :strict_pattern, fn -> anchor(pattern) end),
      render: render,
      normalize: normalize
    }
  end

  @doc "The command line a user could paste to resume `value`."
  @spec render(t(), String.t()) :: String.t()
  def render(%__MODULE__{render: render}, value) when is_binary(value), do: render.(value)

  @doc """
  The token value this format finds in `text`, or `nil`.

  Extra capture groups are ignored rather than rejected: a pattern
  `resume_line?/2` accepts must never be one `capture/2` silently answers `nil`
  for, or the platform would pin a line it cannot then read.
  """
  @spec capture(t(), String.t()) :: String.t() | nil
  def capture(%__MODULE__{pattern: pattern, normalize: normalize}, text) when is_binary(text) do
    case Regex.run(pattern, text) do
      [_, value | _] when is_function(normalize, 1) -> normalize.(value)
      [_, value | _] -> value
      _ -> nil
    end
  end

  def capture(%__MODULE__{}, _text), do: nil

  @doc "Whether `line` is *only* a resume command in this format."
  @spec resume_line?(t(), String.t()) :: boolean()
  def resume_line?(%__MODULE__{strict_pattern: pattern}, line) when is_binary(line) do
    Regex.match?(pattern, String.trim(line))
  end

  def resume_line?(%__MODULE__{}, _line), do: false

  # The strict form of a pattern is the loose form with the whole thing
  # anchored, so a format only ever states its syntax once.
  defp anchor(pattern) do
    Regex.compile!("^(?:" <> Regex.source(pattern) <> ")$", Regex.opts(pattern))
  end

  defp validate!(engine, pattern, render, normalize) do
    cond do
      String.trim(engine) == "" ->
        raise ArgumentError, "resume format engine must not be blank"

      not is_struct(pattern, Regex) ->
        raise ArgumentError, "resume format :pattern must be a Regex, got: #{inspect(pattern)}"

      not is_function(render, 1) ->
        raise ArgumentError, "resume format :render must be a 1-arity function"

      not (is_nil(normalize) or is_function(normalize, 1)) ->
        raise ArgumentError, "resume format :normalize must be nil or a 1-arity function"

      true ->
        :ok
    end
  end
end
