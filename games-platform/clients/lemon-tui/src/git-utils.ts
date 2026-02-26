/**
 * Git utility functions for retrieving repository status information.
 */

import { execFile } from 'node:child_process';
import { GIT_STATUS_TIMEOUT_MS } from './constants.js';

/**
 * Retrieves a formatted modeline string showing the current git branch status.
 * The modeline includes the branch name (or short commit hash for detached HEAD),
 * ahead/behind indicators, and a dirty state marker.
 *
 * @param cwd - The working directory to check git status in
 * @returns A formatted string like "main +2 -1 *" or null if not a git repository
 */
export async function getGitModeline(cwd: string): Promise<string | null> {
  const output = await getGitStatusOutput(cwd);
  if (!output) {
    return null;
  }

  const lines = output.split(/\r?\n/);
  let head: string | null = null;
  let oid: string | null = null;
  let ahead = 0;
  let behind = 0;
  let dirty = false;

  for (const line of lines) {
    if (!line) {
      continue;
    }
    if (line.startsWith('# branch.head ')) {
      head = line.slice('# branch.head '.length).trim();
      continue;
    }
    if (line.startsWith('# branch.oid ')) {
      oid = line.slice('# branch.oid '.length).trim();
      continue;
    }
    if (line.startsWith('# branch.ab ')) {
      const match = line.match(/\+(\d+)\s+-(\d+)/);
      if (match) {
        ahead = Number.parseInt(match[1] || '0', 10);
        behind = Number.parseInt(match[2] || '0', 10);
      }
      continue;
    }
    if (!line.startsWith('#')) {
      dirty = true;
    }
  }

  if (!head && !oid) {
    return null;
  }

  let branch = head;
  if (branch === '(detached)' || branch === 'HEAD' || !branch) {
    const shortOid = oid ? oid.slice(0, 7) : '';
    branch = shortOid || 'detached';
  }

  let suffix = '';
  if (ahead > 0) {
    suffix += ` +${ahead}`;
  }
  if (behind > 0) {
    suffix += ` -${behind}`;
  }
  if (dirty) {
    suffix += ' *';
  }

  return `${branch}${suffix}`;
}

/**
 * Executes git status and returns the raw output.
 *
 * @param cwd - The working directory to run git status in
 * @returns The raw git status output or null if the command fails
 */
export function getGitStatusOutput(cwd: string): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      'git',
      ['status', '--porcelain=v2', '--branch'],
      { cwd, timeout: GIT_STATUS_TIMEOUT_MS, maxBuffer: 1024 * 1024 },
      (err, stdout) => {
        if (err) {
          resolve(null);
          return;
        }
        const trimmed = stdout.trim();
        resolve(trimmed || null);
      }
    );
  });
}
