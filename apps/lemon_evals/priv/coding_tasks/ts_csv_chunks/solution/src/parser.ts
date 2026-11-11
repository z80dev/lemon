import { CsvError } from './errors.ts';
import type { CsvErrorCode } from './errors.ts';
export interface CsvOptions { delimiter?: string }
type State = 'start' | 'bare' | 'quoted' | 'afterQuote';

export class CsvParser {
  private readonly delimiter: string;
  private state: State = 'start';
  private field = '';
  private fields: string[] = [];
  private pending = false;
  private skipLF = false;
  private offset = 0;
  private closed = false;
  private failure: CsvError | undefined;

  constructor(options: CsvOptions = {}) {
    this.delimiter = options.delimiter ?? ',';
    if (this.delimiter.length !== 1 || /["\r\n]/.test(this.delimiter)) throw new RangeError('delimiter must be one character other than quote or newline');
  }

  private fail(code: CsvErrorCode, offset: number): never {
    this.failure = new CsvError(code, offset);
    throw this.failure;
  }

  private endField(): void {
    this.fields.push(this.field);
    this.field = '';
    this.state = 'start';
  }

  private endRecord(): string[] {
    this.endField();
    const row = this.fields;
    this.fields = [];
    this.pending = false;
    return row;
  }

  write(chunk: string): string[][] {
    if (this.failure) throw this.failure;
    if (this.closed) throw new CsvError('CLOSED', this.offset);
    const rows: string[][] = [];
    for (let index = 0; index < chunk.length; index++) {
      const char = chunk[index];
      const position = this.offset++;
      if (this.skipLF) {
        this.skipLF = false;
        if (char === '\n') continue;
      }
      if (this.state === 'quoted') {
        if (char === '"') this.state = 'afterQuote';
        else this.field += char;
        continue;
      }
      if (this.state === 'afterQuote' && char === '"') {
        this.field += '"'; this.state = 'quoted'; continue;
      }
      if (char === this.delimiter) {
        this.pending = true; this.endField(); continue;
      }
      if (char === '\r' || char === '\n') {
        rows.push(this.endRecord());
        this.skipLF = char === '\r';
        continue;
      }
      if (this.state === 'afterQuote') this.fail('AFTER_QUOTE', position);
      if (char === '"') {
        if (this.state !== 'start') this.fail('UNEXPECTED_QUOTE', position);
        this.state = 'quoted'; this.pending = true; continue;
      }
      this.field += char;
      this.state = 'bare'; this.pending = true;
    }
    return rows;
  }

  finish(): string[][] {
    if (this.failure) throw this.failure;
    if (this.closed) return [];
    if (this.state === 'quoted') this.fail('UNTERMINATED_QUOTE', this.offset);
    this.closed = true;
    return this.pending ? [this.endRecord()] : [];
  }
}
