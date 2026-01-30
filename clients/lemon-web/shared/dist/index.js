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
export {
  JsonLineDecoder,
  encodeJsonLine
};
