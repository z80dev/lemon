/**
 * Tests for the MarkdownRenderer component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore, createMockConnection } from '../test-helpers.js';
import { MarkdownRenderer } from './MarkdownRenderer.js';

describe('MarkdownRenderer', () => {
  it('should render plain text content', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="Hello world" />);
    expect(lastFrame()).toContain('Hello world');
  });

  it('should render multi-line content', () => {
    const content = 'Line one\nLine two\nLine three';
    const { lastFrame } = renderWithContext(<MarkdownRenderer content={content} />);
    const frame = lastFrame();
    expect(frame).toContain('Line one');
    expect(frame).toContain('Line two');
    expect(frame).toContain('Line three');
  });

  it('should render empty string without error', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="" />);
    expect(lastFrame()).toBe('');
  });

  it('should render headers', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="# Hello" />);
    expect(lastFrame()).toContain('Hello');
  });

  it('should render unordered lists with bullets', () => {
    const content = '- item one\n- item two';
    const { lastFrame } = renderWithContext(<MarkdownRenderer content={content} />);
    const frame = lastFrame();
    expect(frame).toContain('\u2022');
    expect(frame).toContain('item one');
    expect(frame).toContain('item two');
  });

  it('should render ordered lists', () => {
    const content = '1. first\n2. second';
    const { lastFrame } = renderWithContext(<MarkdownRenderer content={content} />);
    const frame = lastFrame();
    expect(frame).toContain('1.');
    expect(frame).toContain('first');
    expect(frame).toContain('second');
  });

  it('should render horizontal rule', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="---" />);
    expect(lastFrame()).toContain('\u2500');
  });

  it('should render blockquotes', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="> quoted text" />);
    expect(lastFrame()).toContain('\u2502');
    expect(lastFrame()).toContain('quoted text');
  });

  it('should render code blocks with line numbers', () => {
    const content = '```js\nconsole.log("hi")\nconst x = 1\n```';
    const { lastFrame } = renderWithContext(<MarkdownRenderer content={content} />);
    const frame = lastFrame();
    expect(frame).toContain('console.log');
    expect(frame).toContain('js');
    // Should have line numbers
    expect(frame).toContain('1');
    expect(frame).toContain('2');
    // Should have gutter separator
    expect(frame).toContain('\u2502');
  });

  it('should render tables with headers and rows', () => {
    const content = '| Name | Age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |';
    const { lastFrame } = renderWithContext(<MarkdownRenderer content={content} />);
    const frame = lastFrame();
    expect(frame).toContain('Name');
    expect(frame).toContain('Age');
    expect(frame).toContain('Alice');
    expect(frame).toContain('30');
    expect(frame).toContain('Bob');
    expect(frame).toContain('25');
    // Should have table borders
    expect(frame).toContain('\u2502');
    expect(frame).toContain('\u2500');
  });

  it('should render tables without leading pipes', () => {
    const content = 'Name | Age\n--- | ---\nAlice | 30';
    const { lastFrame } = renderWithContext(<MarkdownRenderer content={content} />);
    const frame = lastFrame();
    expect(frame).toContain('Name');
    expect(frame).toContain('Alice');
  });

  it('should render inline bold text', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="This is **bold** text" />);
    expect(lastFrame()).toContain('bold');
    expect(lastFrame()).toContain('This is');
    expect(lastFrame()).toContain('text');
  });

  it('should render inline code', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="Use `foo()` here" />);
    expect(lastFrame()).toContain('foo()');
    expect(lastFrame()).toContain('Use');
  });

  it('should render links', () => {
    const { lastFrame } = renderWithContext(<MarkdownRenderer content="Visit [example](https://example.com)" />);
    expect(lastFrame()).toContain('example');
    expect(lastFrame()).toContain('https://example.com');
  });
});
