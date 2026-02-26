// src/codec.ts
var JsonLineDecoder = class {
  constructor(opts) {
    this.opts = opts;
  }
  buffer = "";
  write(chunk) {
    this.buffer += chunk.toString();
    let index = this.buffer.indexOf("\n");
    while (index >= 0) {
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      this.handleLine(line);
      index = this.buffer.indexOf("\n");
    }
  }
  flush() {
    if (this.buffer.trim() === "") {
      this.buffer = "";
      return;
    }
    this.handleLine(this.buffer);
    this.buffer = "";
  }
  handleLine(raw) {
    const line = raw.trim();
    if (!line) {
      return;
    }
    try {
      const value = JSON.parse(line);
      this.opts.onMessage(value);
    } catch (err) {
      const error = err instanceof Error ? err : new Error("Failed to parse JSON line");
      if (this.opts.onError) {
        this.opts.onError(error, line);
      }
    }
  }
};
function encodeJsonLine(payload) {
  return `${JSON.stringify(payload)}
`;
}

// src/protocol_contract.json
var protocol_contract_default = {
  version: 1,
  core_frames: {
    ready: {
      required: [
        "type",
        "cwd",
        "model",
        "debug",
        "ui",
        "primary_session_id",
        "active_session_id"
      ]
    },
    event: {
      required: ["type", "session_id", "event"]
    },
    stats: {
      required: ["type", "session_id", "stats"]
    },
    pong: {
      required: ["type"]
    },
    debug: {
      required: ["type", "message"]
    },
    error: {
      required: ["type", "message"]
    },
    save_result: {
      required: ["type", "ok"]
    },
    sessions_list: {
      required: ["type", "sessions"]
    },
    running_sessions: {
      required: ["type", "sessions"]
    },
    models_list: {
      required: ["type", "providers"]
    },
    session_started: {
      required: ["type", "session_id", "cwd", "model"]
    },
    session_closed: {
      required: ["type", "session_id", "reason"]
    },
    active_session: {
      required: ["type", "session_id"]
    },
    config_state: {
      required: ["type", "config"]
    }
  }
};

// src/protocolContract.ts
var PROTOCOL_CONTRACT = protocol_contract_default;
var CORE_FRAME_CONTRACT = PROTOCOL_CONTRACT.core_frames;
var CORE_FRAME_TYPES = Object.keys(CORE_FRAME_CONTRACT);
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function getFrameType(value) {
  const frameType = value.type;
  return typeof frameType === "string" ? frameType : null;
}
function hasField(value, field) {
  return Object.prototype.hasOwnProperty.call(value, field);
}
function getRequiredCoreFrameFields(frameType) {
  const entry = CORE_FRAME_CONTRACT[frameType];
  if (!entry || !Array.isArray(entry.required)) {
    return null;
  }
  return entry.required;
}
function validateCoreServerFrame(value) {
  if (!isRecord(value)) {
    return { ok: false, missing: ["type"] };
  }
  const frameType = getFrameType(value);
  if (!frameType) {
    return { ok: false, missing: ["type"] };
  }
  const required = getRequiredCoreFrameFields(frameType);
  if (!required) {
    return { ok: false, type: frameType, missing: ["<unknown_type>"] };
  }
  const missing = required.filter((field) => !hasField(value, field));
  return {
    ok: missing.length === 0,
    type: frameType,
    missing
  };
}
function isCoreServerFrame(value) {
  return validateCoreServerFrame(value).ok;
}
export {
  CORE_FRAME_CONTRACT,
  CORE_FRAME_TYPES,
  JsonLineDecoder,
  PROTOCOL_CONTRACT,
  encodeJsonLine,
  getRequiredCoreFrameFields,
  isCoreServerFrame,
  validateCoreServerFrame
};
