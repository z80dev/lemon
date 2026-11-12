import { CsvParser } from './parser.ts';
import type { CsvOptions } from './parser.ts';
import { CsvSchemaError } from './errors.ts';

export class CsvTable {
  private readonly parser: CsvParser;
  private headers: string[] | undefined;
  private record = 0;
  private failure: unknown;
  private failed = false;

  constructor(options: CsvOptions = {}) { this.parser = new CsvParser(options); }

  private convert(rows: string[][]): Record<string, string>[] {
    const result: Record<string, string>[] = [];
    for (const row of rows) {
      this.record++;
      if (!this.headers) {
        const seen = new Set<string>();
        for (const name of row) {
          if (name === '') throw new CsvSchemaError('EMPTY_HEADER', this.record);
          if (seen.has(name)) throw new CsvSchemaError('DUPLICATE_HEADER', this.record);
          seen.add(name);
        }
        this.headers = row;
      } else {
        if (row.length !== this.headers.length) throw new CsvSchemaError('ROW_WIDTH', this.record);
        result.push(Object.fromEntries(this.headers.map((key, index) => [key, row[index]])));
      }
    }
    return result;
  }

  private consume(finish: boolean, chunk = ''): Record<string, string>[] {
    if (this.failed) throw this.failure;
    try {
      return this.convert(finish ? this.parser.finish() : this.parser.write(chunk));
    } catch (error) {
      this.failed = true; this.failure = error; throw error;
    }
  }

  write(chunk: string): Record<string, string>[] { return this.consume(false, chunk); }
  finish(): Record<string, string>[] { return this.consume(true); }
}
