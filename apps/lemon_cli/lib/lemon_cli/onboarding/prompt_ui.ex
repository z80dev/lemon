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
  def available?, do: not test_env?()

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
        :cancel

      :eof ->
        :cancel

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

  defp normalize_input(nil), do: ""
  defp normalize_input(:eof), do: ""
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()

  defp test_env?,
    do: Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
end
