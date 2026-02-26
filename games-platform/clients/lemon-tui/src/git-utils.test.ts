import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import * as childProcess from 'node:child_process';

// Mock child_process before importing the module under test
vi.mock('node:child_process', () => ({
  execFile: vi.fn(),
}));

describe('git-utils', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  describe('getGitModeline', () => {
    it('parses basic branch status', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head main\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('main');
    });

    it('handles detached HEAD state with (detached) marker', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head (detached)\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('abc1234');
    });

    it('handles detached HEAD state with HEAD marker', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid def5678901234\n# branch.head HEAD\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('def5678');
    });

    it('handles ahead indicator', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head feature\n# branch.ab +3 -0\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('feature +3');
    });

    it('handles behind indicator', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head feature\n# branch.ab +0 -5\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('feature -5');
    });

    it('handles both ahead and behind indicators', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head feature\n# branch.ab +2 -3\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('feature +2 -3');
    });

    it('handles dirty state with modified files', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head main\n1 .M N... 100644 100644 abc def file.txt\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('main *');
    });

    it('handles dirty state with untracked files', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head main\n? untracked.txt\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('main *');
    });

    it('handles all indicators together (ahead, behind, dirty)', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head feature\n# branch.ab +1 -2\n1 .M N... 100644 100644 abc def file.txt\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('feature +1 -2 *');
    });

    it('returns null when git command fails', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(new Error('Not a git repository'), '', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBeNull();
    });

    it('returns null for empty output', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBeNull();
    });

    it('returns null when no head or oid is found', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# some other line\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBeNull();
    });

    it('handles Windows-style line endings (CRLF)', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\r\n# branch.head main\r\n# branch.ab +1 -0\r\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('main +1');
    });

    it('handles branch with missing head but valid oid', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      expect(result).toBe('abc1234');
    });

    it('handles empty head (falls back to oid)', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# branch.oid abc1234567890\n# branch.head \n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitModeline } = await import('./git-utils.js');
      const result = await getGitModeline('/test/path');

      // Empty head after trim becomes falsy, so falls back to short oid
      expect(result).toBe('abc1234');
    });
  });

  describe('getGitStatusOutput', () => {
    it('returns trimmed stdout on success', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '  output with whitespace  \n', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitStatusOutput } = await import('./git-utils.js');
      const result = await getGitStatusOutput('/test/path');

      expect(result).toBe('output with whitespace');
    });

    it('returns null on error', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(new Error('git error'), '', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitStatusOutput } = await import('./git-utils.js');
      const result = await getGitStatusOutput('/test/path');

      expect(result).toBeNull();
    });

    it('returns null for whitespace-only output', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '   \n\t  ', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitStatusOutput } = await import('./git-utils.js');
      const result = await getGitStatusOutput('/test/path');

      expect(result).toBeNull();
    });

    it('calls git with correct arguments', async () => {
      const mockExecFile = vi.mocked(childProcess.execFile);
      mockExecFile.mockImplementation((_cmd, _args, _opts, callback) => {
        const cb = callback as (err: Error | null, stdout: string, stderr: string) => void;
        cb(null, '# output', '');
        return {} as ReturnType<typeof childProcess.execFile>;
      });

      const { getGitStatusOutput } = await import('./git-utils.js');
      await getGitStatusOutput('/test/path');

      expect(mockExecFile).toHaveBeenCalledWith(
        'git',
        ['status', '--porcelain=v2', '--branch'],
        expect.objectContaining({
          cwd: '/test/path',
          timeout: 2000,
          maxBuffer: 1024 * 1024,
        }),
        expect.any(Function)
      );
    });
  });
});
