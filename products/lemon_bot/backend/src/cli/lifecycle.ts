import { launcherProcess } from '../core/config';

export interface ProcessResult { exitCode: number; stdout: string; stderr: string }
export interface ProcessInput { stdin?: string; attached?: boolean; diagnostics?: boolean; environment?: Record<string, string | undefined> }
export type Spawn = (executable: string, args: string[], input?: ProcessInput) => Promise<ProcessResult>;

/** Secrets are piped to stdin, never shell-expanded, placed in argv or exported. */
export const spawn: Spawn = async (executable, args, input = {}) => {
  const runtime = launcherProcess(executable);
  const child = Bun.spawn([executable, ...args], {
    ...runtime, env: { ...runtime.env, ...input.environment },
    stdin: input.attached ? 'inherit' : input.stdin === undefined ? 'ignore' : 'pipe',
    stdout: input.attached ? input.diagnostics ? 2 : 'inherit' : 'pipe', stderr: input.attached ? 'inherit' : 'pipe',
  });
  if (input.stdin !== undefined && typeof child.stdin !== 'number' && child.stdin) {
    child.stdin.write(input.stdin); child.stdin.end();
  }
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited, child.stdout instanceof ReadableStream ? new Response(child.stdout).text() : '', child.stderr instanceof ReadableStream ? new Response(child.stderr).text() : '',
  ]);
  return { exitCode, stdout, stderr };
};

export interface ServiceUnit {
  role: 'controller' | 'backend' | 'worker' | 'tunnel'; name: string | null; state: string;
  detail: string | null; action?: string;
}
export interface ServiceStatus {
  schema: 1; manager: 'launchd' | 'systemd' | 'none'; persistence: 'login' | 'boot' | 'session' | 'none';
  linger: boolean | null; units: ServiceUnit[];
}
export interface ServiceResult { exitCode: number; status: ServiceStatus | null }

export function parseServiceStatus(text: string): ServiceStatus {
  const value = JSON.parse(text) as ServiceStatus;
  if (value?.schema !== 1 || !['launchd', 'systemd', 'none'].includes(value.manager)
      || !['login', 'boot', 'session', 'none'].includes(value.persistence) || !Array.isArray(value.units)
      || !value.units.every(unit => ['controller', 'backend', 'worker', 'tunnel'].includes(unit.role)
        && typeof unit.state === 'string' && (unit.detail === null || typeof unit.detail === 'string'))) {
    throw new Error('Invalid service status.');
  }
  return value;
}

/** A non-zero command can still carry the authoritative parked/blocked unit state. */
export async function service(launcher: string, args: string[], run: Spawn = spawn, input: ProcessInput = {}): Promise<ServiceResult> {
  try {
    const result = await run(launcher, ['service', ...args, '--json'], input);
    let status: ServiceStatus | null = null;
    try { status = parseServiceStatus(result.stdout); } catch { /* An interrupted enrollment has no reliable receipt. */ }
    return { exitCode: result.exitCode, status };
  } catch { return { exitCode: 1, status: null }; }
}
