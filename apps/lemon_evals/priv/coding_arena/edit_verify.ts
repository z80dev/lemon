// Run the pinned upstream verifier, not a Python approximation of Prettier.
// The upstream checkout must already have its dependencies installed.
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const [source, expected, actual] = process.argv.slice(2);
if (!source || !expected || !actual) throw new Error('usage: edit_verify.ts OMP_SOURCE EXPECTED ACTUAL');
// This module is runtime-selected from an operator-supplied, pinned checkout;
// it cannot be a static import relative to Lemon's source tree.
const modulePath = resolve(source, 'packages/typescript-edit-benchmark/src/verify.ts');
const { verifyExpectedFiles } = await import(pathToFileURL(modulePath).href);
console.log(JSON.stringify(await verifyExpectedFiles(resolve(expected), resolve(actual))));
