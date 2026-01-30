/**
 * JSON line decoder/encoder helpers for Lemon RPC.
 */

export interface JsonLineParserOptions {
  onMessage: (value: unknown) => void;
  onError?: (error: Error, rawLine: string) => void;
}

export class JsonLineDecoder {
  private buffer = '';

  constructor(private readonly opts: JsonLineParserOptions) {}

  write(chunk: string | Buffer): void {
    this.buffer += chunk.toString();
    let index = this.buffer.indexOf('\n');

    while (index >= 0) {
      const line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      this.handleLine(line);
      index = this.buffer.indexOf('\n');
    }
  }

  flush(): void {
    if (this.buffer.trim() === '') {
      this.buffer = '';
      return;
    }
    this.handleLine(this.buffer);
    this.buffer = '';
  }

  private handleLine(raw: string): void {
    const line = raw.trim();
    if (!line) {
      return;
    }

    try {
      const value = JSON.parse(line);
      this.opts.onMessage(value);
    } catch (err) {
      const error = err instanceof Error ? err : new Error('Failed to parse JSON line');
      if (this.opts.onError) {
        this.opts.onError(error, line);
      }
    }
  }
}

export function encodeJsonLine(payload: unknown): string {
  return `${JSON.stringify(payload)}\n`;
}
