export type Command = {name: 'list' | 'show' | 'delete'; mutating: boolean};
export function resolveCommand(input: string): Command | undefined {
  switch (input.trim().toLowerCase()) {
    case 'list': case 'ls': return {name: 'list', mutating: false};
    case 'show': case 'get': return {name: 'show', mutating: false};
    case 'delete': case 'rm': return {name: 'delete', mutating: true};
    default: return undefined;
  }
}
export function executeCommand(command: Command, payload: string): string {
  switch (command.name) {
    case 'list': return 'items';
    case 'show': return `item:${payload}`;
    case 'delete': return `deleted:${payload}`;
  }
}
