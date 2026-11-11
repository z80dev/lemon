import { CsvError } from './errors.ts';
export interface CsvOptions { delimiter?: string }

export class CsvParser {
  private delimiter: string;
  private buffered = '';
  private closed = false;
  private offset = 0;
  constructor(options: CsvOptions = {}) {
    this.delimiter = options.delimiter ?? ',';
    if (this.delimiter.length !== 1 || /["\r\n]/.test(this.delimiter)) throw new RangeError('delimiter must be one character other than quote or newline');
  }
  write(chunk: string): string[][] {
    if (this.closed) throw new CsvError('CLOSED', this.offset);
    this.offset += chunk.length;
    this.buffered += chunk;
    const lines = this.buffered.split('\n');
    this.buffered = lines.pop()!;
    return lines.map(line => line.split(this.delimiter));
  }
  finish(): string[][] {
    if (this.closed) return [];
    this.closed = true;
    return this.buffered ? [this.buffered.split(this.delimiter)] : [];
  }
}
