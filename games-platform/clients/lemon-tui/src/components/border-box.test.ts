/**
 * Tests for the BorderBox component.
 */

import { describe, it, expect, vi } from 'vitest';
import { BorderBox } from './border-box.js';
import type { Component } from '@mariozechner/pi-tui';

// Helper to create a mock component that renders specific lines
function createMockComponent(lines: string[]): Component {
  return {
    render: () => lines,
  } as unknown as Component;
}

describe('BorderBox', () => {
  const identity = (s: string) => s;
  const wrap = (s: string) => `[${s}]`;

  describe('render', () => {
    it('returns empty array when no children', () => {
      const box = new BorderBox(identity);
      const result = box.render(40);
      expect(result).toEqual([]);
    });

    it('returns empty array when children render empty', () => {
      const box = new BorderBox(identity);
      box.addChild(createMockComponent([]));
      const result = box.render(40);
      expect(result).toEqual([]);
    });

    it('includes border characters', () => {
      const box = new BorderBox(identity);
      box.addChild(createMockComponent(['Hello']));
      const result = box.render(20);

      // Should have top border, padding, content, padding, bottom border
      expect(result.length).toBe(5);

      // Top border should have corner and horizontal characters
      expect(result[0]).toContain('\u250c'); // top-left corner
      expect(result[0]).toContain('\u2510'); // top-right corner
      expect(result[0]).toContain('\u2500'); // horizontal line

      // Bottom border should have corner characters
      expect(result[4]).toContain('\u2514'); // bottom-left corner
      expect(result[4]).toContain('\u2518'); // bottom-right corner

      // Side borders on content lines
      expect(result[2]).toContain('\u2502'); // vertical line
    });

    it('properly pads content', () => {
      const box = new BorderBox(identity);
      box.addChild(createMockComponent(['Hi']));
      const result = box.render(20);

      // Content line should have padding
      // Format: vertical + space + content + padding + space + vertical
      const contentLine = result[2];
      expect(contentLine.startsWith('\u2502')).toBe(true);
      expect(contentLine.endsWith('\u2502')).toBe(true);
      expect(contentLine).toContain(' Hi ');
    });

    it('renders multiple children', () => {
      const box = new BorderBox(identity);
      box.addChild(createMockComponent(['Line 1']));
      box.addChild(createMockComponent(['Line 2']));
      const result = box.render(20);

      // top border + padding + 2 content lines + padding + bottom border = 6
      expect(result.length).toBe(6);
      expect(result[2]).toContain('Line 1');
      expect(result[3]).toContain('Line 2');
    });

    it('applies border function to borders', () => {
      const box = new BorderBox(wrap);
      box.addChild(createMockComponent(['Test']));
      const result = box.render(20);

      // Top border should be wrapped
      expect(result[0].startsWith('[')).toBe(true);
      expect(result[0].endsWith(']')).toBe(true);
    });

    it('applies background function when provided', () => {
      const bg = (s: string) => `<bg>${s}</bg>`;
      const box = new BorderBox(identity, bg);
      box.addChild(createMockComponent(['Content']));
      const result = box.render(20);

      // Padding lines and content should have bg applied
      expect(result[1]).toContain('<bg>');
      expect(result[2]).toContain('<bg>');
      expect(result[3]).toContain('<bg>');
    });

    it('handles narrow widths gracefully', () => {
      const box = new BorderBox(identity);
      box.addChild(createMockComponent(['X']));
      const result = box.render(6); // minimum practical width

      expect(result.length).toBe(5);
      expect(result[2]).toContain('X');
    });

    it('handles very small width without crashing', () => {
      const box = new BorderBox(identity);
      box.addChild(createMockComponent(['Test']));
      // Width of 4 means contentWidth = max(1, 4-4) = max(1, 0) = 1
      const result = box.render(4);
      expect(result.length).toBeGreaterThan(0);
    });
  });

  describe('addChild', () => {
    it('adds a child component', () => {
      const box = new BorderBox(identity);
      const child = createMockComponent(['Test']);
      box.addChild(child);
      expect(box.children).toContain(child);
    });

    it('adds multiple children in order', () => {
      const box = new BorderBox(identity);
      const child1 = createMockComponent(['First']);
      const child2 = createMockComponent(['Second']);
      box.addChild(child1);
      box.addChild(child2);
      expect(box.children).toEqual([child1, child2]);
    });
  });

  describe('removeChild', () => {
    it('removes an existing child', () => {
      const box = new BorderBox(identity);
      const child = createMockComponent(['Test']);
      box.addChild(child);
      box.removeChild(child);
      expect(box.children).not.toContain(child);
    });

    it('does nothing when removing non-existent child', () => {
      const box = new BorderBox(identity);
      const child1 = createMockComponent(['Test']);
      const child2 = createMockComponent(['Other']);
      box.addChild(child1);
      box.removeChild(child2);
      expect(box.children).toEqual([child1]);
    });
  });

  describe('invalidate', () => {
    it('calls invalidate on children that have it', () => {
      const box = new BorderBox(identity);
      const invalidateFn = vi.fn();
      const child = {
        children: [],
        render: () => ['Test'],
        invalidate: invalidateFn,
      };
      box.addChild(child);
      box.invalidate();
      expect(invalidateFn).toHaveBeenCalled();
    });

    it('handles children without invalidate method', () => {
      const box = new BorderBox(identity);
      const child = createMockComponent(['Test']);
      box.addChild(child);
      // Should not throw
      expect(() => box.invalidate()).not.toThrow();
    });
  });
});
