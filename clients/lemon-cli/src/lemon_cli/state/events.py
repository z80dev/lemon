import time
from lemon_cli.state.store import (
    SessionState, StateStore, NormalizedUserMessage,
    NormalizedAssistantMessage, NormalizedToolResultMessage, ToolExecution,
)
from lemon_cli.types import SessionEvent


def handle_session_event(event: SessionEvent, session: SessionState, store: StateStore):
    """Route event to handler."""
    match event.type:
        case "agent_start":
            session.busy = True
            session.is_streaming = True
            session.tool_executions.clear()
            store._state.agent_start_time = time.monotonic()

        case "agent_end":
            _finish_streaming(session)
            session.busy = False
            session.is_streaming = False
            session.tool_working_message = None
            session.agent_working_message = None
            store._state.agent_start_time = None

        case "turn_start":
            pass

        case "turn_end":
            pass

        case "message_start":
            msg_data = event.data[0] if event.data else None
            if not msg_data:
                return
            role = msg_data.get("role")
            if role == "user":
                normalized = _normalize_user_message(msg_data, store._next_message_id())
                session.messages.append(normalized)
            elif role == "assistant":
                session.streaming_message = _normalize_assistant_message(
                    msg_data, f"assistant_{msg_data.get('timestamp', 0)}", is_streaming=True)

        case "message_update":
            if session.streaming_message and event.data:
                msg_data = event.data[0]
                session.streaming_message = _normalize_assistant_message(
                    msg_data, session.streaming_message.id, is_streaming=True)

        case "message_end":
            if session.streaming_message and event.data:
                msg_data = event.data[0]
                final = _normalize_assistant_message(
                    msg_data, session.streaming_message.id, is_streaming=False)
                session.messages.append(final)
                session.streaming_message = None
                # Update cumulative usage
                if final.usage:
                    session.cumulative_usage.update_from_usage(final.usage)

        case "tool_execution_start":
            if event.data and len(event.data) >= 3:
                tool_id, name, args = event.data[0], event.data[1], event.data[2]
                session.tool_executions[tool_id] = ToolExecution(
                    id=tool_id, name=name, args=args or {}, start_time=time.monotonic())
                session.tool_working_message = f"Running {name}..."

        case "tool_execution_update":
            if event.data and len(event.data) >= 4:
                tool_id = event.data[0]
                partial = event.data[3]
                te = session.tool_executions.get(tool_id)
                if te:
                    te.partial_result = partial
                    # Extract task fields if present
                    if isinstance(partial, dict):
                        details = partial.get("details", {})
                        if details:
                            te.task_engine = details.get("engine")
                            action = details.get("current_action", {})
                            if action:
                                te.task_current_action = action

        case "tool_execution_end":
            if event.data and len(event.data) >= 4:
                tool_id, name = event.data[0], event.data[1]
                result, is_error = event.data[2], event.data[3]
                te = session.tool_executions.get(tool_id)
                if te:
                    te.result = result
                    te.is_error = is_error
                    te.end_time = time.monotonic()
                session.tool_working_message = None

        case "error":
            reason = event.data[0] if event.data else "Unknown error"
            store.set_error(reason)
            session.busy = False
            session.is_streaming = False


def _finish_streaming(session: SessionState):
    if session.streaming_message:
        session.streaming_message.is_streaming = False
        session.messages.append(session.streaming_message)
        session.streaming_message = None


def _normalize_user_message(data: dict, msg_id: str) -> NormalizedUserMessage:
    content = data.get("content", "")
    if isinstance(content, list):
        content = " ".join(
            block.get("text", "") for block in content
            if block.get("type") == "text"
        )
    return NormalizedUserMessage(id=msg_id, content=content, timestamp=data.get("timestamp", 0))


def _normalize_assistant_message(data: dict, msg_id: str,
                                  is_streaming: bool = False) -> NormalizedAssistantMessage:
    content_blocks = data.get("content", [])
    text_parts, thinking_parts, tool_calls = [], [], []

    for block in (content_blocks if isinstance(content_blocks, list) else []):
        btype = block.get("type")
        if btype == "text":
            text_parts.append(block.get("text", ""))
        elif btype == "thinking":
            thinking_parts.append(block.get("thinking", ""))
        elif btype == "tool_call":
            tool_calls.append({
                "id": block.get("id"),
                "name": block.get("name"),
                "arguments": block.get("arguments", {}),
            })

    usage_raw = data.get("usage")
    usage = None
    if usage_raw:
        cost_raw = usage_raw.get("cost", {})
        usage = {
            "input_tokens": usage_raw.get("input", 0),
            "output_tokens": usage_raw.get("output", 0),
            "cache_read_tokens": usage_raw.get("cache_read", 0),
            "cache_write_tokens": usage_raw.get("cache_write", 0),
            "total_tokens": usage_raw.get("total_tokens", 0),
            "total_cost": cost_raw.get("total", 0) if cost_raw else 0,
        }

    return NormalizedAssistantMessage(
        id=msg_id,
        text_content="\n".join(text_parts),
        thinking_content="\n".join(thinking_parts),
        tool_calls=tool_calls,
        provider=data.get("provider", ""),
        model=data.get("model", ""),
        usage=usage,
        stop_reason=data.get("stop_reason"),
        error=data.get("error_message"),
        timestamp=data.get("timestamp", 0),
        is_streaming=is_streaming,
    )
