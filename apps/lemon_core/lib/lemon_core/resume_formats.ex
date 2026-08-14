defmodule LemonCore.ResumeFormats do
  @moduledoc """
  Registry of `LemonCore.ResumeFormat`s, one per engine that has its own syntax.

  `LemonCore.ResumeToken` is the platform-wide entrypoint for reading and
  printing resume commands — channels and the router depend on core alone and
  call it — but the syntax it reads belongs to whoever wraps the vendor CLI.
  Vendor packages hand their format over when their application starts, the way
  they hand over subagent runners and gateway engines:

      LemonCliRunners.Application.start/2
        -> LemonCore.ResumeFormats.register(LemonCliRunners.CodexSubagent.resume_format())

  A runtime without those packages still parses `lemon resume <id>` (the
  built-in below) and still prints the generic `<engine> resume <value>` for
  everything else; it simply does not recognise vendor spellings it has no
  vendor for.

  ## Why application env and not a GenServer

  `LemonCore.ResumeToken.is_resume_line/1` runs per line while truncating a
  message for a chat transport, so lookups have to be cheap and must not depend
  on a process being alive. Registration, by contrast, happens once per
  application at boot — and OTP starts applications one at a time, which is
  what serialises the writes here.
  """

  alias LemonCore.ResumeFormat

  @key :resume_formats

  # The in-process engine's syntax is core's own, so it stays here: a runtime
  # with nothing but lemon_core still round-trips its own resume lines.
  @lemon_pattern ~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i

  @doc """
  Registers a format, replacing any format already held for its engine.

      LemonCore.ResumeFormats.register(format)
      LemonCore.ResumeFormats.register("kimi", pattern: ~r/.../, render: &render/1)
  """
  @spec register(ResumeFormat.t()) :: :ok
  def register(%ResumeFormat{} = format) do
    put(upsert(registered(), format))
  end

  @spec register(String.t(), keyword()) :: :ok
  def register(engine, opts) when is_binary(engine) and is_list(opts) do
    register(ResumeFormat.new(engine, opts))
  end

  @doc "Drops the format registered for `engine`. Always `:ok`."
  @spec unregister(String.t()) :: :ok
  def unregister(engine) when is_binary(engine) do
    put(Enum.reject(registered(), &(&1.engine == engine)))
  end

  @doc """
  Every known format: registered ones in registration order, then the built-in
  `lemon` format unless an engine registered over it.
  """
  @spec all() :: [ResumeFormat.t()]
  def all do
    registered = registered()

    registered ++ Enum.reject(builtin(), fn format -> has_engine?(registered, format.engine) end)
  end

  @doc "The format for `engine`, or `:error`."
  @spec fetch(term()) :: {:ok, ResumeFormat.t()} | :error
  def fetch(engine) when is_binary(engine) do
    case Enum.find(all(), &(&1.engine == engine)) do
      nil -> :error
      format -> {:ok, format}
    end
  end

  def fetch(_engine), do: :error

  @doc "Engine ids with a registered (or built-in) format, in lookup order."
  @spec list_engines() :: [String.t()]
  def list_engines, do: Enum.map(all(), & &1.engine)

  @doc "The formats core ships itself."
  @spec builtin() :: [ResumeFormat.t()]
  def builtin do
    [
      ResumeFormat.new("lemon",
        pattern: @lemon_pattern,
        render: &__MODULE__.render_lemon/1
      )
    ]
  end

  @doc false
  @spec render_lemon(String.t()) :: String.t()
  def render_lemon(value), do: "lemon resume #{value}"

  defp registered do
    :lemon_core
    |> Application.get_env(@key, [])
    |> List.wrap()
    |> Enum.filter(&is_struct(&1, ResumeFormat))
  end

  defp put(formats) do
    Application.put_env(:lemon_core, @key, formats)
    :ok
  end

  defp upsert(formats, format) do
    case Enum.find_index(formats, &(&1.engine == format.engine)) do
      nil -> formats ++ [format]
      index -> List.replace_at(formats, index, format)
    end
  end

  defp has_engine?(formats, engine), do: Enum.any?(formats, &(&1.engine == engine))
end
