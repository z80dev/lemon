/**
 * BorderBox - a container component with Unicode borders.
 */

import { type Component, visibleWidth } from '@mariozechner/pi-tui';

/**
 * BorderBox - a container with a thin Unicode border around its children.
 * Uses box-drawing characters for a clean, modern look.
 */
export class BorderBox implements Component {
  children: Component[] = [];
  private borderFn: (s: string) => string;
  private bgFn?: (s: string) => string;
  private compact: boolean;

  constructor(borderFn: (s: string) => string, bgFn?: (s: string) => string, compact = false) {
    this.borderFn = borderFn;
    this.bgFn = bgFn;
    this.compact = compact;
  }

  addChild(component: Component): void {
    this.children.push(component);
  }

  removeChild(component: Component): void {
    const index = this.children.indexOf(component);
    if (index !== -1) {
      this.children.splice(index, 1);
    }
  }

  invalidate(): void {
    for (const child of this.children) {
      child.invalidate?.();
    }
  }

  render(width: number): string[] {
    if (this.children.length === 0) {
      return [];
    }

    // Border characters (thin)
    const topLeft = '\u250c';
    const topRight = '\u2510';
    const bottomLeft = '\u2514';
    const bottomRight = '\u2518';
    const horizontal = '\u2500';
    const vertical = '\u2502';

    // Content width is width minus 2 for borders, minus 2 for padding (1 each side)
    const contentWidth = Math.max(1, width - 4);
    const innerWidth = width - 2; // width inside borders

    // Render all children
    const childLines: string[] = [];
    for (const child of this.children) {
      const lines = child.render(contentWidth);
      for (const line of lines) {
        childLines.push(line);
      }
    }

    if (childLines.length === 0) {
      return [];
    }

    const result: string[] = [];

    // Top border
    const topBorder = topLeft + horizontal.repeat(innerWidth) + topRight;
    result.push(this.borderFn(topBorder));

    // Empty line for top padding (skip in compact mode)
    if (!this.compact) {
      result.push(this.renderPaddingLine(vertical, innerWidth));
    }

    // Content lines with side borders and padding
    for (const line of childLines) {
      const lineWidth = visibleWidth(line);
      const padding = Math.max(0, contentWidth - lineWidth);
      const paddedLine = ' ' + line + ' '.repeat(padding + 1);

      // Apply background to content area if provided
      const content = this.bgFn ? this.applyBgToLine(paddedLine, innerWidth) : paddedLine;
      result.push(this.borderFn(vertical) + content + this.borderFn(vertical));
    }

    // Empty line for bottom padding (skip in compact mode)
    if (!this.compact) {
      result.push(this.renderPaddingLine(vertical, innerWidth));
    }

    // Bottom border
    const bottomBorder = bottomLeft + horizontal.repeat(innerWidth) + bottomRight;
    result.push(this.borderFn(bottomBorder));

    return result;
  }

  private renderPaddingLine(vertical: string, innerWidth: number): string {
    const emptyContent = ' '.repeat(innerWidth);
    const content = this.bgFn ? this.bgFn(emptyContent) : emptyContent;
    return this.borderFn(vertical) + content + this.borderFn(vertical);
  }

  private applyBgToLine(line: string, targetWidth: number): string {
    if (!this.bgFn) return line;
    const lineWidth = visibleWidth(line);
    const padding = Math.max(0, targetWidth - lineWidth);
    return this.bgFn(line + ' '.repeat(padding));
  }
}
