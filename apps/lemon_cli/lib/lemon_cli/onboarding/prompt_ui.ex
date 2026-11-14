defmodule LemonCli.Onboarding.PromptUI do
  @moduledoc false

  @type option :: %{
          required(:label) => String.t(),
          required(:value) => term()
        }

  @type select_params :: %{
          required(:title) => String.t(),
          required(:options) => [option()],
          optional(:subtitle) => String.t() | nil,
          optional(:default_index) => non_neg_integer()
        }

  @type io_callbacks :: %{
          required(:info) => (String.t() -> any()),
          required(:prompt) => (String.t() -> String.t() | charlist() | nil)
        }

  @spec available?() :: boolean()
  def available?, do: not test_env?() and terminal?()

  @spec terminal?() :: boolean()
  def terminal? do
    case :io.getopts(:standard_io) do
      options when is_list(options) -> Keyword.get(options, :terminal, false)
      _ -> false
    end
  end

  @spec select(select_params()) :: {:ok, term()} | :cancel | {:error, term()}
  def select(params), do: select(params, [])

  @doc false
  @spec select(select_params(), keyword()) :: {:ok, term()} | :cancel | {:error, term()}
  def select(%{title: title, options: options} = params, opts)
      when is_binary(title) and is_list(options) and is_list(opts) do
    cond do
      options == [] ->
        {:error, :no_options}

      not Keyword.get(opts, :force, false) and not available?() ->
        {:error, :not_available}

      true ->
        io = Keyword.get(opts, :io, default_io())
        default_index = valid_default_index(Map.get(params, :default_index, 0), options)

        io.info.("")
        io.info.(title)

        if subtitle = Map.get(params, :subtitle) do
          io.info.(subtitle)
        end

        io.info.("")

        options
        |> Enum.with_index(1)
        |> Enum.each(fn {option, number} ->
          marker = if number - 1 == default_index, do: " (default)", else: ""
          io.info.("  #{number}. #{option.label}#{marker}")
        end)

        prompt_for_choice(options, default_index, io)
    end
  end

  def select(_, _), do: {:error, :invalid_selector_params}

  defp prompt_for_choice(options, default_index, io) do
    case io.prompt.("Select [default: #{default_index + 1}, q to cancel]: ") do
      nil ->
        {:error, :end_of_input}

      :eof ->
        {:error, :end_of_input}

      input ->
        choose_input(normalize_input(input), options, default_index, io)
    end
  end

  defp choose_input(choice, options, default_index, io) do
    cond do
      choice == "" ->
        {:ok, options |> Enum.at(default_index) |> Map.fetch!(:value)}

      String.downcase(choice) in ["q", "quit", "cancel"] ->
        :cancel

      String.match?(choice, ~r/^\d+$/) ->
        select_number(choice, options, default_index, io)

      true ->
        select_label(choice, options, default_index, io)
    end
  end

  defp select_number(choice, options, default_index, io) do
    index = String.to_integer(choice) - 1

    if index >= 0 and index < length(options) do
      {:ok, options |> Enum.at(index) |> Map.fetch!(:value)}
    else
      io.info.("Enter a number from 1 to #{length(options)}, or q to cancel.")
      prompt_for_choice(options, default_index, io)
    end
  end

  defp select_label(choice, options, default_index, io) do
    normalized = String.downcase(choice)

    case Enum.find(options, &(String.downcase(&1.label) == normalized)) do
      nil ->
        io.info.("Enter a listed number or exact label, or q to cancel.")
        prompt_for_choice(options, default_index, io)

      option ->
        {:ok, option.value}
    end
  end

  defp valid_default_index(index, options)
       when is_integer(index) and index >= 0 and index < length(options),
       do: index

  defp valid_default_index(_, _), do: 0

  defp default_io do
    %{
      info: &IO.puts/1,
      prompt: &IO.gets/1
    }
  end

  def normalize_input(nil), do: ""
  def normalize_input(:eof), do: ""
  def normalize_input(value) when is_binary(value), do: String.trim(value)
  def normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  def normalize_input(value), do: value |> to_string() |> String.trim()

  def select_value(io, params) do
    case Map.get(io, :select) do
      select when is_function(select, 1) ->
        case select.(params) do
          {:ok, value} ->
            {:ok, value}

          :cancel ->
            :cancel

          # Non-interactive runs install a selector that always asks for the
          # prompt path; it must not be mistaken for a selected value.
          :fallback ->
            :fallback

          {:error, reason} ->
            if reason == :end_of_input, do: LemonCli.Onboarding.Runner.no_terminal!()

            io.error.(
              "Interactive onboarding UI unavailable (#{format_selector_error(reason)}). Falling back to prompt mode."
            )

            :fallback

          value ->
            {:ok, value}
        end

      _ ->
        :fallback
    end
  end

  defp format_selector_error(:no_selection), do: "selector exited before a choice was made"
  defp format_selector_error(:invalid_selector_params), do: "invalid selector parameters"
  defp format_selector_error(_reason), do: "the selector could not be started"

  def yes_no(message, io, default \\ true) do
    prompt_yes_no(message, io, default, fn -> yes_no(message, io, default) end)
  end

  defp prompt_yes_no(message, io, default, retry) do
    suffix = if default, do: " [Y/n]: ", else: " [y/N]: "

    answer =
      io.prompt.(message <> suffix)
      |> normalize_input!()
      |> String.downcase()

    case answer do
      "" -> default
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> retry.()
    end
  end

  def select_yes_no(message, default, io) do
    options = [
      %{label: "Yes", value: true},
      %{label: "No", value: false}
    ]

    default_index = if default, do: 0, else: 1

    case select_value(io, %{
           title: message,
           subtitle: "Use Enter to confirm.",
           options: options,
           default_index: default_index
         }) do
      {:ok, value} ->
        value

      :cancel ->
        default

      :fallback ->
        prompt_yes_no(message, io, default, fn -> select_yes_no(message, default, io) end)
    end
  end

  def normalize_input!(value) when value in [nil, :eof],
    do: LemonCli.Onboarding.Runner.no_terminal!()

  def normalize_input!(value), do: normalize_input(value)

  def interactive_prompt_session?(io) when is_map(io) do
    is_function(Map.get(io, :select), 1) and available?()
  end

  defp test_env?,
    do: Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
end
