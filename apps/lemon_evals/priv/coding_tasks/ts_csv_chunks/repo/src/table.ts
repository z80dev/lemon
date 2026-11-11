import { CsvParser } from './parser.ts';
import type { CsvOptions } from './parser.ts';

export class CsvTable {
  private parser: CsvParser;
  private headers: string[] | undefined;
  constructor(options: CsvOptions = {}) { this.parser = new CsvParser(options); }
  private convert(rows: string[][]): Record<string, string>[] {
    const result: Record<string, string>[] = [];
    for (const row of rows) {
      if (!this.headers) { this.headers = row; continue; }
      result.push(Object.fromEntries(this.headers.map((key, i) => [key, row[i] ?? ''])));
    }
    return result;
  }
  write(chunk: string): Record<string, string>[] { return this.convert(this.parser.write(chunk)); }
  finish(): Record<string, string>[] { return this.convert(this.parser.finish()); }
}
