import { resolveCommand } from './commands.ts';
export function describeCommands(inputs: string[]): string[] {
  return inputs.map(input => resolveCommand(input)?.name ?? '?');
}
