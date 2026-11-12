import { findCommand } from './cli.ts';
export function describeCommands(inputs: string[]): string[] {
  return inputs.map(input => findCommand(input) ?? '?');
}
