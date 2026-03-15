/**
 * Tests for the InputEditor component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { InputEditor } from './InputEditor.js';
import { SlashCommandAutocompleteProvider } from '../../autocomplete.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

const testCommands = [
  { name: 'help', description: 'Show help' },
  { name: 'quit', description: 'Exit' },
  { name: 'reset', description: 'Reset session' },
];

describe('InputEditor', () => {
  it('should render with prompt indicator', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    expect(lastFrame()).toContain('>');
  });

  it('should show busy prompt when busy', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const { lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    expect(lastFrame()).toContain('\u00B7'); // middle dot (·)
  });

  it('should accept text input', async () => {
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('hello world');
    await delay();
    expect(lastFrame()).toContain('hello world');
  });

  it('should submit on Enter', async () => {
    const onSubmit = vi.fn();
    const store = createTestStore();
    const { stdin } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('test message');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('test message');
  });

  it('should clear input after submit', async () => {
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('test');
    await delay();
    stdin.write('\r');
    await delay();
    // After submit, input should be cleared
    const frame = lastFrame();
    expect(frame).not.toContain('test');
  });

  it('should not submit empty input', async () => {
    const onSubmit = vi.fn();
    const store = createTestStore();
    const { stdin } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('\r'); // Enter on empty input
    await delay();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('should not submit when busy', async () => {
    const onSubmit = vi.fn();
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const { stdin } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('test');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('should handle backspace', async () => {
    const onSubmit = vi.fn();
    const store = createTestStore();
    const { stdin } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('hello');
    await delay();
    stdin.write('\x7F'); // Backspace
    await delay();
    stdin.write('\x7F'); // Backspace
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('hel');
  });

  it('should handle left/right arrow cursor movement', async () => {
    const onSubmit = vi.fn();
    const store = createTestStore();
    const { stdin } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('abc');
    await delay();
    stdin.write('\x1B[D'); // Left
    await delay();
    stdin.write('\x1B[D'); // Left
    await delay();
    stdin.write('X');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('aXbc');
  });

  it('should show autocomplete suggestions on Tab', async () => {
    const provider = new SlashCommandAutocompleteProvider(testCommands);
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} autocompleteProvider={provider} />,
      { store }
    );
    await delay();
    stdin.write('/');
    await delay();
    stdin.write('\t'); // Tab
    await delay();
    const frame = lastFrame();
    expect(frame).toContain('/help');
    expect(frame).toContain('/quit');
    expect(frame).toContain('/reset');
  });

  it('should apply autocomplete on Enter while suggestions are visible', async () => {
    const provider = new SlashCommandAutocompleteProvider(testCommands);
    const onSubmit = vi.fn();
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={true} autocompleteProvider={provider} />,
      { store }
    );
    await delay();
    stdin.write('/h');
    await delay();
    stdin.write('\t'); // Tab to show suggestions
    await delay();
    stdin.write('\r'); // Enter to apply first suggestion
    await delay();
    // Should have applied /help, not submitted
    expect(onSubmit).not.toHaveBeenCalled();
    expect(lastFrame()).toContain('/help');
  });

  it('should dismiss autocomplete on Escape', async () => {
    const provider = new SlashCommandAutocompleteProvider(testCommands);
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} autocompleteProvider={provider} />,
      { store }
    );
    await delay();
    stdin.write('/');
    await delay();
    stdin.write('\t');
    await delay();
    expect(lastFrame()).toContain('/help');
    stdin.write('\x1B'); // Escape
    await delay();
    // Suggestions should be gone, but input text remains
    const frame = lastFrame();
    expect(frame).toContain('/');
    // The autocomplete popup items should be gone
  });

  it('should navigate autocomplete with arrow keys', async () => {
    const provider = new SlashCommandAutocompleteProvider(testCommands);
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} autocompleteProvider={provider} />,
      { store }
    );
    await delay();
    stdin.write('/');
    await delay();
    stdin.write('\t'); // Show all commands
    await delay();
    stdin.write('\x1B[B'); // Down to second item (quit)
    await delay();
    stdin.write('\r'); // Apply
    await delay();
    expect(lastFrame()).toContain('/quit');
  });

  it('should clear input on Ctrl+C', async () => {
    const store = createTestStore();
    const { stdin, lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    await delay();
    stdin.write('some text');
    await delay();
    stdin.write('\x03'); // Ctrl+C
    await delay();
    // Should clear the text
    const frame = lastFrame();
    expect(frame).not.toContain('some text');
  });

  it('should not respond to input when not focused', async () => {
    const onSubmit = vi.fn();
    const store = createTestStore();
    const { stdin } = renderWithContext(
      <InputEditor onSubmit={onSubmit} isFocused={false} />,
      { store }
    );
    await delay();
    stdin.write('test');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('should show border around editor', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    const frame = lastFrame();
    // Ink border characters
    expect(frame).toContain('\u250C') // top-left corner
    expect(frame).toContain('\u2514') // bottom-left corner
  });

  it('should render cursor area in editor', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(
      <InputEditor onSubmit={vi.fn()} isFocused={true} />,
      { store }
    );
    const frame = lastFrame();
    // Editor should render with prompt indicator and box border
    expect(frame).toContain('>');
    expect(frame).toContain('\u250C'); // border top-left
  });
});
