defmodule LemonRouter.ChannelAdapter do
  @moduledoc """
  Behaviour defining channel-specific output strategies.

  The router produces generic output intents; channel-specific rendering
  strategies are encapsulated behind adapter implementations dispatched
  via `for/1`.
  """

  @type state_snapshot :: map()
  @type state_updates :: map()

  @doc "Emit streaming output (called on each coalesced flush)."
  @callback emit_stream_output(state_snapshot()) :: {:ok, state_updates()} | :skip

  @doc "Finalize the stream at run completion."
  @callback finalize_stream(state_snapshot(), final_text :: binary() | nil) ::
              {:ok, state_updates()} | :skip

  @doc "Emit a tool status message update."
  @callback emit_tool_status(state_snapshot(), text :: binary()) ::
              {:ok, state_updates()} | :skip

  @doc "Handle a delivery acknowledgement from the outbox."
  @callback handle_delivery_ack(state_snapshot(), ref :: reference(), result :: term()) ::
              state_updates()

  @doc "Truncate text for the channel's limits."
  @callback truncate(text :: binary()) :: binary()

  @doc "Batch files for sending (e.g. Telegram media groups)."
  @callback batch_files(files :: [map()]) :: [[map()]]

  @doc "Reply markup for tool status messages (e.g. cancel button)."
  @callback tool_status_reply_markup(state_snapshot()) :: map() | nil

  @doc "Whether to skip emitting final output for non-streaming runs."
  @callback skip_non_streaming_final_emit?() :: boolean()

  @doc "Whether the channel requires stream finalization."
  @callback should_finalize_stream?() :: boolean()

  @doc "Auto-send file configuration for the channel."
  @callback auto_send_config() :: map()

  @doc "Maximum download bytes for explicit send files."
  @callback files_max_download_bytes() :: non_neg_integer()

  @doc "Limit the display order of tool actions for the channel."
  @callback limit_order(order :: [String.t()]) :: {[String.t()], non_neg_integer()}

  @doc "Format extra info for a tool action line (channel-specific detail)."
  @callback format_action_extra(action :: map(), rendered_title :: String.t()) ::
              String.t() | nil

  @doc """
  Dispatch to the appropriate adapter module for a channel.
  """
  @spec for(String.t() | nil) :: module()
  def for("telegram"), do: LemonRouter.ChannelAdapter.Telegram
  def for(_), do: LemonRouter.ChannelAdapter.Generic
end
