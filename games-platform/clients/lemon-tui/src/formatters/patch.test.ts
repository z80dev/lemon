/**
 * Tests for the patch tool formatter.
 *
 * Tests formatting of patch operations including parsing unified diff format,
 * detecting file operations (create, modify, delete), and counting changes.
 */

import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';

// Mock os module to control home directory for path formatting
vi.mock('node:os', () => ({
  homedir: vi.fn(() => '/Users/testuser'),
}));

describe('patchFormatter', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  describe('formatArgs', () => {
    it('shows "Applying patch (N files)" summary for single file', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/index.ts
+++ b/src/index.ts
@@ -1,3 +1,4 @@
 import { app } from './app';
+import { logger } from './logger';

 app.start();`;

      const result = patchFormatter.formatArgs({ patch_text: patchText });

      expect(result.summary).toBe('Applying patch (1 file)');
    });

    it('shows "Applying patch (N files)" summary for multiple files', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/index.ts
+++ b/src/index.ts
@@ -1,3 +1,4 @@
 import { app } from './app';
+import { logger } from './logger';
--- a/src/app.ts
+++ b/src/app.ts
@@ -5,6 +5,7 @@
 export const app = {
+  version: '1.0.0',
   start() {}
 };
--- a/package.json
+++ b/package.json
@@ -1,4 +1,4 @@
 {
-  "version": "0.9.0"
+  "version": "1.0.0"
 }`;

      const result = patchFormatter.formatArgs({ patch_text: patchText });

      expect(result.summary).toBe('Applying patch (3 files)');
    });

    it('parses file list from patch headers', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/components/Button.tsx
+++ b/src/components/Button.tsx
@@ -1 +1 @@
-export const Button = () => <button />;
+export const Button = () => <button className="btn" />;`;

      const result = patchFormatter.formatArgs({ patch_text: patchText });

      expect(result.details).toContain('Files to patch:');
      expect(result.details.some((d) => d.includes('Button.tsx'))).toBe(true);
    });

    it('shows "Applying patch" when no files detected', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatArgs({ patch_text: '' });

      expect(result.summary).toBe('Applying patch');
      expect(result.details).toContain('No files detected in patch');
    });

    it('handles empty patch_text', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatArgs({ patch_text: '' });

      expect(result.summary).toBe('Applying patch');
    });

    it('handles missing patch_text', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatArgs({});

      expect(result.summary).toBe('Applying patch');
    });
  });

  describe('formatResult - success', () => {
    it('shows "N files patched" summary with checkmark', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/file1.ts
+++ b/src/file1.ts
@@ -1 +1 @@
-old
+new
--- a/src/file2.ts
+++ b/src/file2.ts
@@ -1 +1 @@
-old
+new`;

      const result = patchFormatter.formatResult(
        { content: [{ type: 'text', text: 'Patch applied successfully' }] },
        { patch_text: patchText }
      );

      expect(result.summary).toBe('\u2713 2 files patched');
      expect(result.isError).toBeFalsy();
    });

    it('shows created files with "+" prefix', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- /dev/null
+++ b/src/newfile.ts
@@ -0,0 +1,5 @@
+export const newFeature = () => {
+  return 'hello';
+};
+
+export default newFeature;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.details.some((d) => d.startsWith('+ ') && d.includes('newfile.ts'))).toBe(true);
      expect(result.details.some((d) => d.includes('(created)'))).toBe(true);
    });

    it('shows modified files with "M" prefix and +/- counts', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/utils.ts
+++ b/src/utils.ts
@@ -1,5 +1,8 @@
 export function helper() {
-  return null;
+  return {
+    value: 42,
+    name: 'helper'
+  };
 }

 export const PI = 3.14;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      const modifiedLine = result.details.find((d) => d.startsWith('M ') && d.includes('utils.ts'));
      expect(modifiedLine).toBeDefined();
      expect(modifiedLine).toContain('+');
      expect(modifiedLine).toContain('-');
    });

    it('shows deleted files with "-" prefix', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/deprecated.ts
+++ /dev/null
@@ -1,10 +0,0 @@
-export const oldFunction = () => {
-  console.log('deprecated');
-};
-
-export const anotherOld = () => {
-  return false;
-};
-
-// Old code
-export default oldFunction;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.details.some((d) => d.startsWith('- ') && d.includes('deprecated.ts'))).toBe(true);
      expect(result.details.some((d) => d.includes('(removed)'))).toBe(true);
    });

    it('handles single file patched', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-# Old Title
+# New Title`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.summary).toBe('\u2713 1 file patched');
    });

    it('counts additions and deletions correctly', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/config.ts
+++ b/src/config.ts
@@ -1,6 +1,8 @@
 export const config = {
-  debug: false,
-  verbose: false,
+  debug: true,
+  verbose: true,
+  logLevel: 'info',
+  timeout: 5000,
 };`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      const modifiedLine = result.details.find((d) => d.includes('config.ts'));
      expect(modifiedLine).toBeDefined();
      // Should have 4 additions and 2 deletions
      expect(modifiedLine).toContain('+4');
      expect(modifiedLine).toContain('-2');
    });
  });

  describe('formatResult - failure', () => {
    it('shows "Failed" summary with X mark when error in result', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult(
        { error: true },
        { patch_text: '--- a/file.ts\n+++ b/file.ts\n' }
      );

      expect(result.summary).toBe('\u2717 Failed');
      expect(result.isError).toBe(true);
    });

    it('detects error from isError field', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult(
        { isError: true },
        { patch_text: '' }
      );

      expect(result.summary).toBe('\u2717 Failed');
      expect(result.isError).toBe(true);
    });

    it('detects error from content text containing "error"', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult(
        { content: [{ type: 'text', text: 'Patch error: file not found' }] },
        { patch_text: '' }
      );

      expect(result.summary).toBe('\u2717 Failed');
      expect(result.isError).toBe(true);
    });

    it('detects error from content text containing "failed"', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult(
        { content: [{ type: 'text', text: 'Patch application failed' }] },
        { patch_text: '' }
      );

      expect(result.summary).toBe('\u2717 Failed');
      expect(result.isError).toBe(true);
    });

    it('shows failure details', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult(
        { error: true },
        { patch_text: '' }
      );

      expect(result.details).toContain('\u2717 Patch failed');
    });
  });

  describe('patch parsing', () => {
    it('detects new file when --- is /dev/null', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- /dev/null
+++ b/src/brand-new.ts
@@ -0,0 +1,3 @@
+export const x = 1;
+export const y = 2;
+export const z = 3;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.details.some((d) => d.includes('(created)'))).toBe(true);
    });

    it('detects deleted file when +++ is /dev/null', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/to-delete.ts
+++ /dev/null
@@ -1,2 +0,0 @@
-const old = true;
-export default old;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.details.some((d) => d.includes('(removed)'))).toBe(true);
    });

    it('detects modified file when both --- and +++ have paths', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/existing.ts
+++ b/src/existing.ts
@@ -1,3 +1,3 @@
 export const config = {
-  value: 1
+  value: 2
 };`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.details.some((d) => d.startsWith('M '))).toBe(true);
    });

    it('counts additions correctly (lines starting with + but not +++)', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/test.ts
+++ b/src/test.ts
@@ -1,2 +1,5 @@
 const a = 1;
+const b = 2;
+const c = 3;
+const d = 4;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      const modifiedLine = result.details.find((d) => d.includes('test.ts'));
      expect(modifiedLine).toContain('+3'); // 3 additions
    });

    it('counts deletions correctly (lines starting with - but not ---)', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/test.ts
+++ b/src/test.ts
@@ -1,5 +1,2 @@
 const a = 1;
-const b = 2;
-const c = 3;
-const d = 4;`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      const modifiedLine = result.details.find((d) => d.includes('test.ts'));
      expect(modifiedLine).toContain('-3'); // 3 deletions
    });

    it('handles multiple files in single patch', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- /dev/null
+++ b/src/new.ts
@@ -0,0 +1 @@
+export const x = 1;
--- a/src/modify.ts
+++ b/src/modify.ts
@@ -1 +1 @@
-old
+new
--- a/src/delete.ts
+++ /dev/null
@@ -1 +0,0 @@
-gone`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.summary).toBe('\u2713 3 files patched');
      expect(result.details.some((d) => d.includes('(created)'))).toBe(true);
      expect(result.details.some((d) => d.startsWith('M '))).toBe(true);
      expect(result.details.some((d) => d.includes('(removed)'))).toBe(true);
    });

    it('handles paths without a/ or b/ prefix', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- src/file.ts
+++ src/file.ts
@@ -1 +1 @@
-old
+new`;

      const result = patchFormatter.formatArgs({ patch_text: patchText });

      expect(result.details.some((d) => d.includes('file.ts'))).toBe(true);
    });

    it('handles Windows-style line endings in patch', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/file.ts\r\n+++ b/src/file.ts\r\n@@ -1 +1 @@\r\n-old\r\n+new`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      expect(result.summary).toBe('\u2713 1 file patched');
    });
  });

  describe('edge cases', () => {
    it('handles empty result', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult({}, { patch_text: '' });

      expect(result.summary).toBe('\u2713 0 files patched');
      expect(result.details).toContain('No file operations detected');
    });

    it('handles null result', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult(null, { patch_text: '' });

      expect(result.summary).toBe('\u2713 0 files patched');
    });

    it('handles missing args', async () => {
      const { patchFormatter } = await import('./patch.js');

      const result = patchFormatter.formatResult({});

      expect(result.summary).toBe('\u2713 0 files patched');
    });

    it('handles patch with only context lines', async () => {
      const { patchFormatter } = await import('./patch.js');

      const patchText = `--- a/src/file.ts
+++ b/src/file.ts
@@ -1,3 +1,3 @@
 line1
 line2
 line3`;

      const result = patchFormatter.formatResult({}, { patch_text: patchText });

      const modifiedLine = result.details.find((d) => d.includes('file.ts'));
      expect(modifiedLine).toContain('+0');
      expect(modifiedLine).toContain('-0');
    });
  });

  describe('tools property', () => {
    it('handles patch tool', async () => {
      const { patchFormatter } = await import('./patch.js');

      expect(patchFormatter.tools).toContain('patch');
    });
  });
});
