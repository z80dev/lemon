/**
 * Tests for the HelpOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext } from '../test-helpers.js';
import { HelpOverlay } from './HelpOverlay.js';

describe('HelpOverlay', () => {
  it('should render help title', () => {
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<HelpOverlay onClose={onClose} />);
    expect(lastFrame()).toContain('Help');
  });

  it('should show session commands section', () => {
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<HelpOverlay onClose={onClose} />);
    expect(lastFrame()).toContain('Session Commands');
    expect(lastFrame()).toContain('/new-session');
    expect(lastFrame()).toContain('/switch');
  });

  it('should show keybindings section', () => {
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<HelpOverlay onClose={onClose} />);
    expect(lastFrame()).toContain('Keybindings');
    expect(lastFrame()).toContain('Ctrl+N');
    expect(lastFrame()).toContain('Ctrl+O');
    expect(lastFrame()).toContain('Ctrl+F');
  });

  it('should show input editor section', () => {
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<HelpOverlay onClose={onClose} />);
    expect(lastFrame()).toContain('Input Editor');
    expect(lastFrame()).toContain('Ctrl+K');
    expect(lastFrame()).toContain('Ctrl+W');
  });

  it('should show navigation and control sections', () => {
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<HelpOverlay onClose={onClose} />);
    expect(lastFrame()).toContain('Navigation');
    expect(lastFrame()).toContain('Control');
    expect(lastFrame()).toContain('/abort');
    expect(lastFrame()).toContain('/compact');
    expect(lastFrame()).toContain('/bell');
  });

  it('should show escape hint', () => {
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<HelpOverlay onClose={onClose} />);
    expect(lastFrame()).toContain('Escape');
  });
});
