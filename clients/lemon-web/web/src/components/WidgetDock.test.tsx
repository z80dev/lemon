import { render, screen, within, act } from '@testing-library/react';
import { describe, it, expect, beforeEach } from 'vitest';
import { WidgetDock } from './WidgetDock';
import { useLemonStore, type LemonState, type WidgetState } from '../store/useLemonStore';

// ============================================================================
// Test Fixtures
// ============================================================================

function createWidget(overrides: Partial<WidgetState> = {}): WidgetState {
  return {
    key: 'test-widget',
    content: { message: 'Hello, World!' },
    ...overrides,
  };
}

function createWidgets(widgets: WidgetState[]): Record<string, WidgetState> {
  const result: Record<string, WidgetState> = {};
  for (const widget of widgets) {
    result[widget.key] = widget;
  }
  return result;
}

// ============================================================================
// Store Setup Helpers
// ============================================================================

function getInitialState(): Partial<LemonState> {
  return {
    ui: {
      requestsQueue: [],
      status: {},
      widgets: {},
      workingMessage: null,
      title: null,
      editorText: '',
    },
  };
}

function setupStore(overrides: { widgets?: Record<string, WidgetState> } = {}) {
  useLemonStore.setState({
    ...getInitialState(),
    ui: {
      requestsQueue: [],
      status: {},
      widgets: overrides.widgets ?? {},
      workingMessage: null,
      title: null,
      editorText: '',
    },
  } as LemonState);
}

// ============================================================================
// Tests
// ============================================================================

describe('WidgetDock', () => {
  beforeEach(() => {
    setupStore();
  });

  // ==========================================================================
  // Empty State Tests
  // ==========================================================================

  describe('Empty State', () => {
    it('returns null when no widgets are present', () => {
      setupStore({ widgets: {} });

      const { container } = render(<WidgetDock />);

      expect(container.firstChild).toBeNull();
    });

    it('does not render widget-dock section when widgets are empty', () => {
      setupStore({ widgets: {} });

      render(<WidgetDock />);

      expect(document.querySelector('.widget-dock')).not.toBeInTheDocument();
    });

    it('renders no widget cards when widgets object is empty', () => {
      setupStore({ widgets: {} });

      render(<WidgetDock />);

      expect(document.querySelectorAll('.widget-card')).toHaveLength(0);
    });
  });

  // ==========================================================================
  // Single Widget Tests
  // ==========================================================================

  describe('Single Widget Rendering', () => {
    it('renders a single widget card', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'my-widget' })]),
      });

      render(<WidgetDock />);

      expect(document.querySelector('.widget-card')).toBeInTheDocument();
    });

    it('displays the widget key as the title', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'status-widget' })]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('status-widget')).toBeInTheDocument();
    });

    it('renders widget content as JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({
            key: 'data-widget',
            content: { count: 42, active: true },
          }),
        ]),
      });

      render(<WidgetDock />);

      // Check that JSON content is rendered
      expect(screen.getByText(/"count": 42/)).toBeInTheDocument();
      expect(screen.getByText(/"active": true/)).toBeInTheDocument();
    });

    it('renders widget content in a pre element', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'json-widget' })]),
      });

      render(<WidgetDock />);

      const preElement = document.querySelector('pre');
      expect(preElement).toBeInTheDocument();
    });

    it('renders widget-dock section container', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'test' })]),
      });

      render(<WidgetDock />);

      const section = document.querySelector('section.widget-dock');
      expect(section).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Multiple Widgets Tests
  // ==========================================================================

  describe('Multiple Widgets Rendering', () => {
    it('renders multiple widget cards', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'widget-1' }),
          createWidget({ key: 'widget-2' }),
          createWidget({ key: 'widget-3' }),
        ]),
      });

      render(<WidgetDock />);

      const cards = document.querySelectorAll('.widget-card');
      expect(cards).toHaveLength(3);
    });

    it('displays all widget keys as titles', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'alpha' }),
          createWidget({ key: 'beta' }),
          createWidget({ key: 'gamma' }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('alpha')).toBeInTheDocument();
      expect(screen.getByText('beta')).toBeInTheDocument();
      expect(screen.getByText('gamma')).toBeInTheDocument();
    });

    it('renders each widget with its own content', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'widget-a', content: { value: 'first' } }),
          createWidget({ key: 'widget-b', content: { value: 'second' } }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText(/"value": "first"/)).toBeInTheDocument();
      expect(screen.getByText(/"value": "second"/)).toBeInTheDocument();
    });

    it('assigns unique keys to widget cards', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'unique-1' }),
          createWidget({ key: 'unique-2' }),
        ]),
      });

      const { container } = render(<WidgetDock />);

      // Each card should be distinguishable
      const cards = container.querySelectorAll('.widget-card');
      const titles = Array.from(cards).map(
        (card) => card.querySelector('.widget-card__title')?.textContent
      );

      expect(titles).toContain('unique-1');
      expect(titles).toContain('unique-2');
      expect(new Set(titles).size).toBe(2); // Ensure uniqueness
    });
  });

  // ==========================================================================
  // Widget Content Display Tests
  // ==========================================================================

  describe('Widget Content Display', () => {
    it('renders string content as JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'string-widget', content: 'Simple string content' }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('"Simple string content"')).toBeInTheDocument();
    });

    it('renders number content as JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'number-widget', content: 12345 }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('12345')).toBeInTheDocument();
    });

    it('renders boolean content as JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'bool-widget', content: true }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('true')).toBeInTheDocument();
    });

    it('renders null content as JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'null-widget', content: null }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('null')).toBeInTheDocument();
    });

    it('renders array content as formatted JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'array-widget', content: ['item1', 'item2', 'item3'] }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText(/"item1"/)).toBeInTheDocument();
      expect(screen.getByText(/"item2"/)).toBeInTheDocument();
      expect(screen.getByText(/"item3"/)).toBeInTheDocument();
    });

    it('renders nested object content as formatted JSON', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({
            key: 'nested-widget',
            content: {
              level1: {
                level2: {
                  value: 'deep',
                },
              },
            },
          }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText(/"level1":/)).toBeInTheDocument();
      expect(screen.getByText(/"level2":/)).toBeInTheDocument();
      expect(screen.getByText(/"value": "deep"/)).toBeInTheDocument();
    });

    it('renders JSON with 2-space indentation', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'formatted', content: { a: 1, b: 2 } }),
        ]),
      });

      render(<WidgetDock />);

      const pre = document.querySelector('pre');
      expect(pre).toBeInTheDocument();
      // JSON.stringify with 2-space indent creates multi-line output
      expect(pre?.textContent).toContain('{\n');
    });
  });

  // ==========================================================================
  // CSS Classes and Styling Tests
  // ==========================================================================

  describe('CSS Classes and Styling', () => {
    it('applies widget-dock class to the section container', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'styled' })]),
      });

      render(<WidgetDock />);

      expect(document.querySelector('section.widget-dock')).toBeInTheDocument();
    });

    it('applies widget-card class to each card', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'card-1' }),
          createWidget({ key: 'card-2' }),
        ]),
      });

      render(<WidgetDock />);

      const cards = document.querySelectorAll('.widget-card');
      expect(cards).toHaveLength(2);
      cards.forEach((card) => {
        expect(card).toHaveClass('widget-card');
      });
    });

    it('applies widget-card__title class to the title element', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'title-test' })]),
      });

      render(<WidgetDock />);

      const title = document.querySelector('.widget-card__title');
      expect(title).toBeInTheDocument();
      expect(title?.textContent).toBe('title-test');
    });

    it('uses semantic section element for the dock', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'semantic' })]),
      });

      render(<WidgetDock />);

      const section = document.querySelector('section');
      expect(section).toBeInTheDocument();
      expect(section).toHaveClass('widget-dock');
    });

    it('uses div elements for widget cards', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'div-card' })]),
      });

      render(<WidgetDock />);

      const card = document.querySelector('.widget-card');
      expect(card?.tagName).toBe('DIV');
    });
  });

  // ==========================================================================
  // Widget Updates Tests (Store State Changes)
  // ==========================================================================

  describe('Widget Updates', () => {
    it('reflects store updates when widget is added', () => {
      setupStore({ widgets: {} });

      const { rerender } = render(<WidgetDock />);

      // Initially empty
      expect(document.querySelector('.widget-dock')).not.toBeInTheDocument();

      // Add a widget to the store
      act(() => {
        useLemonStore.setState({
          ui: {
            ...useLemonStore.getState().ui,
            widgets: createWidgets([createWidget({ key: 'new-widget' })]),
          },
        });
      });

      rerender(<WidgetDock />);

      expect(screen.getByText('new-widget')).toBeInTheDocument();
    });

    it('reflects store updates when widget content changes', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'mutable', content: { status: 'pending' } }),
        ]),
      });

      const { rerender } = render(<WidgetDock />);

      expect(screen.getByText(/"status": "pending"/)).toBeInTheDocument();

      // Update widget content
      act(() => {
        useLemonStore.setState({
          ui: {
            ...useLemonStore.getState().ui,
            widgets: createWidgets([
              createWidget({ key: 'mutable', content: { status: 'completed' } }),
            ]),
          },
        });
      });

      rerender(<WidgetDock />);

      expect(screen.getByText(/"status": "completed"/)).toBeInTheDocument();
    });

    it('reflects store updates when additional widget is added', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'existing' })]),
      });

      const { rerender } = render(<WidgetDock />);

      expect(document.querySelectorAll('.widget-card')).toHaveLength(1);

      // Add another widget
      act(() => {
        useLemonStore.setState({
          ui: {
            ...useLemonStore.getState().ui,
            widgets: createWidgets([
              createWidget({ key: 'existing' }),
              createWidget({ key: 'additional' }),
            ]),
          },
        });
      });

      rerender(<WidgetDock />);

      expect(document.querySelectorAll('.widget-card')).toHaveLength(2);
      expect(screen.getByText('additional')).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Widget Removal Tests
  // ==========================================================================

  describe('Widget Removal', () => {
    it('removes widget card when widget is removed from store', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'removable' }),
          createWidget({ key: 'persistent' }),
        ]),
      });

      const { rerender } = render(<WidgetDock />);

      expect(screen.getByText('removable')).toBeInTheDocument();
      expect(screen.getByText('persistent')).toBeInTheDocument();

      // Remove one widget
      act(() => {
        useLemonStore.setState({
          ui: {
            ...useLemonStore.getState().ui,
            widgets: createWidgets([createWidget({ key: 'persistent' })]),
          },
        });
      });

      rerender(<WidgetDock />);

      expect(screen.queryByText('removable')).not.toBeInTheDocument();
      expect(screen.getByText('persistent')).toBeInTheDocument();
    });

    it('returns null when all widgets are removed', () => {
      setupStore({
        widgets: createWidgets([createWidget({ key: 'last-widget' })]),
      });

      const { container, rerender } = render(<WidgetDock />);

      expect(document.querySelector('.widget-dock')).toBeInTheDocument();

      // Remove all widgets
      useLemonStore.setState({
        ui: {
          ...useLemonStore.getState().ui,
          widgets: {},
        },
      });

      rerender(<WidgetDock />);

      expect(container.firstChild).toBeNull();
    });

    it('updates card count correctly when multiple widgets are removed', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'a' }),
          createWidget({ key: 'b' }),
          createWidget({ key: 'c' }),
          createWidget({ key: 'd' }),
        ]),
      });

      const { rerender } = render(<WidgetDock />);

      expect(document.querySelectorAll('.widget-card')).toHaveLength(4);

      // Remove two widgets
      useLemonStore.setState({
        ui: {
          ...useLemonStore.getState().ui,
          widgets: createWidgets([
            createWidget({ key: 'a' }),
            createWidget({ key: 'd' }),
          ]),
        },
      });

      rerender(<WidgetDock />);

      expect(document.querySelectorAll('.widget-card')).toHaveLength(2);
      expect(screen.getByText('a')).toBeInTheDocument();
      expect(screen.getByText('d')).toBeInTheDocument();
      expect(screen.queryByText('b')).not.toBeInTheDocument();
      expect(screen.queryByText('c')).not.toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Edge Cases
  // ==========================================================================

  describe('Edge Cases', () => {
    it('handles widget with empty object content', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'empty-obj', content: {} }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('empty-obj')).toBeInTheDocument();
      expect(screen.getByText('{}')).toBeInTheDocument();
    });

    it('handles widget with empty array content', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'empty-arr', content: [] }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('empty-arr')).toBeInTheDocument();
      expect(screen.getByText('[]')).toBeInTheDocument();
    });

    it('handles widget with undefined content', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'undefined-content', content: undefined }),
        ]),
      });

      render(<WidgetDock />);

      // undefined is not valid JSON, so JSON.stringify returns undefined
      // which gets coerced to empty string or "undefined"
      expect(screen.getByText('undefined-content')).toBeInTheDocument();
    });

    it('handles widget with special characters in key', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'widget-with_special.chars:123' }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText('widget-with_special.chars:123')).toBeInTheDocument();
    });

    it('handles widget with very long key', () => {
      const longKey = 'x'.repeat(200);
      setupStore({
        widgets: createWidgets([createWidget({ key: longKey })]),
      });

      render(<WidgetDock />);

      expect(screen.getByText(longKey)).toBeInTheDocument();
    });

    it('handles widget with complex nested content', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({
            key: 'complex',
            content: {
              users: [
                { id: 1, name: 'Alice', tags: ['admin', 'active'] },
                { id: 2, name: 'Bob', tags: ['user'] },
              ],
              meta: {
                total: 2,
                page: 1,
              },
            },
          }),
        ]),
      });

      render(<WidgetDock />);

      expect(screen.getByText(/"users":/)).toBeInTheDocument();
      expect(screen.getByText(/"name": "Alice"/)).toBeInTheDocument();
      expect(screen.getByText(/"name": "Bob"/)).toBeInTheDocument();
    });

    it('handles widget with opts property (even though not displayed)', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({
            key: 'with-opts',
            content: { data: 'value' },
            opts: { collapsible: true, maxHeight: 200 },
          }),
        ]),
      });

      render(<WidgetDock />);

      // Component currently doesn't render opts, but should not break
      expect(screen.getByText('with-opts')).toBeInTheDocument();
      expect(screen.getByText(/"data": "value"/)).toBeInTheDocument();
    });
  });

  // ==========================================================================
  // Structure Tests
  // ==========================================================================

  describe('Component Structure', () => {
    it('renders title before content in each card', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'order-test', content: { test: true } }),
        ]),
      });

      render(<WidgetDock />);

      const card = document.querySelector('.widget-card');
      const children = Array.from(card?.children ?? []);

      expect(children[0]).toHaveClass('widget-card__title');
      expect(children[1]?.tagName).toBe('PRE');
    });

    it('renders cards as direct children of the section', () => {
      setupStore({
        widgets: createWidgets([
          createWidget({ key: 'child-1' }),
          createWidget({ key: 'child-2' }),
        ]),
      });

      render(<WidgetDock />);

      const section = document.querySelector('.widget-dock');
      const cards = section?.querySelectorAll(':scope > .widget-card');

      expect(cards).toHaveLength(2);
    });
  });
});
