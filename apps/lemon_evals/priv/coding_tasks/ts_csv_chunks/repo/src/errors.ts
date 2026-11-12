export type CsvErrorCode = 'UNEXPECTED_QUOTE' | 'AFTER_QUOTE' | 'UNTERMINATED_QUOTE' | 'CLOSED';
export class CsvError extends Error {
  readonly code: CsvErrorCode;
  readonly offset: number;
  constructor(code: CsvErrorCode, offset: number) {
    super(code + ' at offset ' + offset);
    this.name = 'CsvError'; this.code = code; this.offset = offset;
  }
}

export type CsvSchemaCode = 'EMPTY_HEADER' | 'DUPLICATE_HEADER' | 'ROW_WIDTH';
export class CsvSchemaError extends Error {
  readonly code: CsvSchemaCode;
  readonly record: number;
  constructor(code: CsvSchemaCode, record: number) {
    super(code + ' at record ' + record);
    this.name = 'CsvSchemaError'; this.code = code; this.record = record;
  }
}
