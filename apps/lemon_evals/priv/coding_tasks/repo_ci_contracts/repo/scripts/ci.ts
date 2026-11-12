import { checkContracts } from './check-contracts.ts';
const issues = checkContracts(process.cwd());
if (issues.length) {
  process.stderr.write(issues.join('\n') + '\n');
  process.exitCode = 1;
} else {
  process.stdout.write('contracts: ok\n');
}
