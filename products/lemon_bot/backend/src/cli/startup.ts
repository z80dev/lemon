/** Service entrypoints and non-interactive invocations must remain foreground servers. */
export function foregroundStartup(args: string[], interactive: boolean, serviceRole?: string): boolean {
  return args.includes('--no-open') || Boolean(serviceRole) || !interactive;
}
