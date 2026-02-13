import fs from 'node:fs';
import path from 'node:path';

const KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

export function loadDotenvFromDir(dir?: string, opts?: { override?: boolean }): void {
  const targetDir = path.resolve(dir || process.cwd());
  const envPath = path.join(targetDir, '.env');
  const override = opts?.override === true;

  let content: string;
  try {
    content = fs.readFileSync(envPath, 'utf-8');
  } catch {
    return;
  }

  for (const line of content.split(/\r?\n/)) {
    const parsed = parseLine(line);
    if (!parsed) {
      continue;
    }

    const [key, value] = parsed;
    if (override || process.env[key] == null) {
      process.env[key] = value;
    }
  }
}

function parseLine(line: string): [string, string] | null {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) {
    return null;
  }

  const exportStripped = trimmed.startsWith('export ')
    ? trimmed.slice('export '.length).trimStart()
    : trimmed;
  const eqIndex = exportStripped.indexOf('=');
  if (eqIndex <= 0) {
    return null;
  }

  const key = exportStripped.slice(0, eqIndex).trim();
  if (!KEY_PATTERN.test(key)) {
    return null;
  }

  const rawValue = exportStripped.slice(eqIndex + 1).trimStart();
  return [key, parseValue(rawValue)];
}

function parseValue(rawValue: string): string {
  if (!rawValue) {
    return '';
  }

  if (rawValue.startsWith('"')) {
    const match = rawValue.match(/^"((?:\\.|[^"])*)"(?:\s+#.*)?\s*$/);
    if (match) {
      return unescapeDoubleQuoted(match[1]);
    }
  }

  if (rawValue.startsWith('\'')) {
    const match = rawValue.match(/^'([^']*)'(?:\s+#.*)?\s*$/);
    if (match) {
      return match[1];
    }
  }

  return stripInlineComment(rawValue).trim();
}

function stripInlineComment(value: string): string {
  return value.replace(/\s+#.*$/, '');
}

function unescapeDoubleQuoted(value: string): string {
  return value
    .replace(/\\n/g, '\n')
    .replace(/\\r/g, '\r')
    .replace(/\\t/g, '\t')
    .replace(/\\"/g, '"')
    .replace(/\\\\/g, '\\');
}
