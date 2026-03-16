from lemon_cli.types import (
    ServerMessage,
    ReadyMessage,
    EventMessage,
    StatsMessage,
    SessionStartedMessage,
    SessionClosedMessage,
    ActiveSessionMessage,
    UIRequestMessage,
    SessionsListMessage,
    RunningSessionsMessage,
    ModelsListMessage,
    SaveResultMessage,
    ErrorMessage,
    PongMessage,
    DebugMessage,
    UnknownMessage,
    ContentBlock,
    TextContent,
    ThinkingContent,
    ToolCall,
    ImageContent,
)


def parse_content_block(block: dict) -> ContentBlock:
    """Parse a content block dict into the appropriate dataclass."""
    struct = block.get("__struct__", "")
    block_type = block.get("type", "")

    if block_type == "text" or "TextContent" in struct:
        return TextContent(
            type="text",
            text=block.get("text", ""),
            text_signature=block.get("text_signature"),
        )
    elif block_type == "thinking" or "ThinkingContent" in struct:
        return ThinkingContent(
            type="thinking",
            thinking=block.get("thinking", ""),
            thinking_signature=block.get("thinking_signature"),
        )
    elif block_type == "tool_call" or "ToolCall" in struct:
        return ToolCall(
            type="tool_call",
            id=block.get("id", ""),
            name=block.get("name", ""),
            arguments=block.get("arguments", {}),
        )
    elif block_type == "image" or "ImageContent" in struct:
        return ImageContent(
            type="image",
            data=block.get("data", ""),
            mime_type=block.get("mime_type", "image/png"),
        )
    else:
        # Fallback to text
        return TextContent(
            type="text",
            text=str(block),
            text_signature=None,
        )


def parse_server_message(data: dict) -> ServerMessage:
    """Dispatch on data['type'] to construct the right dataclass."""
    match data.get("type"):
        case "ready":
            return ReadyMessage.from_dict(data)
        case "event":
            return EventMessage.from_dict(data)
        case "stats":
            return StatsMessage.from_dict(data)
        case "session_started":
            return SessionStartedMessage.from_dict(data)
        case "session_closed":
            return SessionClosedMessage.from_dict(data)
        case "active_session":
            return ActiveSessionMessage.from_dict(data)
        case "ui_request":
            return UIRequestMessage.from_dict(data)
        case "sessions_list":
            return SessionsListMessage.from_dict(data)
        case "running_sessions":
            return RunningSessionsMessage.from_dict(data)
        case "models_list":
            return ModelsListMessage.from_dict(data)
        case "save_result":
            return SaveResultMessage.from_dict(data)
        case "error":
            return ErrorMessage.from_dict(data)
        case "pong":
            return PongMessage()
        case "debug":
            return DebugMessage.from_dict(data)
        case _:
            return UnknownMessage(type=data.get("type", "unknown"), raw=data)
