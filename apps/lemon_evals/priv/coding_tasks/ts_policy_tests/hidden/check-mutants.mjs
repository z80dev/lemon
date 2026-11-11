import assert from 'node:assert/strict';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(process.argv[2]);
const canonical = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'policy.reference.js'), 'utf8');
assert.ok(existsSync(join(root, 'test/policy.test.js')), 'Write test/policy.test.js');
assert.equal(readFileSync(join(root, 'src/policy.js'), 'utf8'), canonical, 'Production policy must remain unchanged');

const mutations = [
  ['anonymous-public', "if (!subject) return false;", "if (!subject) return resource.visibility === 'public' && action === 'read';"],
  ['suspension', 'if (subject.suspended) return false;', 'if (false) return false;'],
  ['admin-tenant-bypass', 'if (subject.orgId !== resource.orgId) return false;', "if (subject.orgId !== resource.orgId && subject.role !== 'admin') return false;"],
  ['explicit-denial', 'if (resource.deniedUserIds?.includes(subject.id)) return false;', 'if (false) return false;'],
  ['unknown-action', "if (action !== 'read' && action !== 'write' && action !== 'delete') return false;", 'if (false) return false;'],
  ['archived-write', "if (resource.archived && action !== 'read') return false;", 'if (false) return false;'],
  ['owner-delete', 'if (resource.ownerId === subject.id) return true;', "if (resource.ownerId === subject.id) return action !== 'delete';"],
  ['private-disclosure', "if (resource.visibility === 'private') return false;", 'if (false) return false;'],
  ['editor-delete', "return action === 'write' && subject.role === 'editor';", "return subject.role === 'editor';"],
  ['viewer-write', "return action === 'write' && subject.role === 'editor';", "return action === 'write';"],
];

function run(cwd, paths) {
  const result = spawnSync(process.execPath, ['--test', ...paths], { cwd, encoding: 'utf8', timeout: 20_000 });
  if (result.error) throw result.error;
  assert.equal(result.signal, null, 'Test process must finish normally');
  return result;
}

const correct = run(root, ['test/smoke.test.js', 'test/policy.test.js']);
if (correct.status !== 0) {
  process.stdout.write(correct.stdout);
  process.stderr.write(correct.stderr);
  throw new Error('Tests must pass on the correct policy');
}

for (const [name, before, after] of mutations) {
  const pattern = new RegExp([...before].map(char =>
    /\s/.test(char) ? '\\s*' : /['"]/.test(char) ? '[\\x22\\x27]' :
    '\\x' + char.charCodeAt(0).toString(16).padStart(2, '0')
  ).join(''), 'g');
  assert.equal([...canonical.matchAll(pattern)].length, 1, `Mutation anchor must be unique: ${name}`);
  const sandbox = mkdtempSync(join(tmpdir(), 'workspace-policy-'));
  try {
    cpSync(join(root, 'src'), join(sandbox, 'src'), { recursive: true });
    cpSync(join(root, 'test'), join(sandbox, 'test'), { recursive: true });
    cpSync(join(root, 'package.json'), join(sandbox, 'package.json'));
    writeFileSync(join(sandbox, 'src/policy.js'), canonical.replace(pattern, after));
    const result = run(sandbox, ['test/policy.test.js']);
    assert.notEqual(result.status, 0, `Tests failed to detect policy regression: ${name}`);
  } finally {
    rmSync(sandbox, { recursive: true, force: true });
  }
}
console.log(`Policy tests passed and detected all ${mutations.length} regressions.`);
