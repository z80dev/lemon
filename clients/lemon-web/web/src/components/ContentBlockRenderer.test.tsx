import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, it } from 'vitest';
import { ContentBlockRenderer } from './ContentBlockRenderer';
import type {
  Message,
  TextContent,
  ThinkingContent,
  ToolCall,
  ImageContent,
  ContentBlock,
} from '@lemon-web/shared';

afterEach(() => {
  cleanup();
});

// ============================================================================
// Test Fixtures
// ============================================================================

function createUserMessage(content: string | ContentBlock[]): Message {
  return {
    __struct__: 'Elixir.Ai.Types.UserMessage',
    role: 'user',
    content,
    timestamp: Date.now(),
  };
}

function createAssistantMessage(content: ContentBlock[]): Message {
  return {
    __struct__: 'Elixir.Ai.Types.AssistantMessage',
    role: 'assistant',
    content,
    provider: 'test',
    model: 'test-model',
    api: 'test-api',
    usage: { input: 10, output: 5, total_tokens: 15 },
    stop_reason: 'stop',
    error_message: null,
    timestamp: Date.now(),
  };
}

function createTextContent(text: string): TextContent {
  return {
    __struct__: 'Elixir.Ai.Types.TextContent',
    type: 'text',
    text,
  };
}

function createThinkingContent(thinking: string): ThinkingContent {
  return {
    __struct__: 'Elixir.Ai.Types.ThinkingContent',
    type: 'thinking',
    thinking,
  };
}

function createToolCall(
  name: string,
  args: Record<string, unknown>,
  id = 'tool-call-1'
): ToolCall {
  return {
    __struct__: 'Elixir.Ai.Types.ToolCall',
    type: 'tool_call',
    id,
    name,
    arguments: args,
  };
}

function createImageContent(
  data: string,
  mimeType = 'image/png'
): ImageContent {
  return {
    __struct__: 'Elixir.Ai.Types.ImageContent',
    type: 'image',
    data,
    mime_type: mimeType,
  };
}

// ============================================================================
// Basic Rendering Tests
// ============================================================================

describe('ContentBlockRenderer', () => {
  describe('string content', () => {
    it('renders plain text string content', () => {
      const message = createUserMessage('Hello, world!');
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByText('Hello, world!')).toBeInTheDocument();
    });

    it('renders multiline string content', () => {
      const message = createUserMessage('Line 1\n\nLine 2\n\nLine 3');
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByText('Line 1')).toBeInTheDocument();
      expect(screen.getByText('Line 2')).toBeInTheDocument();
      expect(screen.getByText('Line 3')).toBeInTheDocument();
    });
  });

  describe('unsupported content', () => {
    it('renders unsupported message for non-string non-array content', () => {
      const message = {
        __struct__: 'Elixir.Ai.Types.UserMessage',
        role: 'user' as const,
        content: 12345 as unknown as string,
        timestamp: Date.now(),
      };
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByText('Unsupported content.')).toBeInTheDocument();
    });

    it('renders unknown block message for unrecognized block types', () => {
      const message = createAssistantMessage([
        { type: 'custom_unknown_type' } as unknown as ContentBlock,
      ]);
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByText('Unknown content block.')).toBeInTheDocument();
    });
  });
});

// ============================================================================
// Markdown Rendering Tests
// ============================================================================

describe('Markdown rendering', () => {
  describe('headers', () => {
    it('renders h1 headers', () => {
      const message = createUserMessage('# Heading 1');
      render(<ContentBlockRenderer message={message} />);

      const h1 = screen.getByRole('heading', { level: 1 });
      expect(h1).toHaveTextContent('Heading 1');
    });

    it('renders h2 headers', () => {
      const message = createUserMessage('## Heading 2');
      render(<ContentBlockRenderer message={message} />);

      const h2 = screen.getByRole('heading', { level: 2 });
      expect(h2).toHaveTextContent('Heading 2');
    });

    it('renders h3 headers', () => {
      const message = createUserMessage('### Heading 3');
      render(<ContentBlockRenderer message={message} />);

      const h3 = screen.getByRole('heading', { level: 3 });
      expect(h3).toHaveTextContent('Heading 3');
    });

    it('renders multiple heading levels', () => {
      const message = createUserMessage(
        '# Main Title\n\n## Section\n\n### Subsection'
      );
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent(
        'Main Title'
      );
      expect(screen.getByRole('heading', { level: 2 })).toHaveTextContent(
        'Section'
      );
      expect(screen.getByRole('heading', { level: 3 })).toHaveTextContent(
        'Subsection'
      );
    });
  });

  describe('lists', () => {
    it('renders unordered lists', () => {
      const message = createUserMessage('- Item 1\n- Item 2\n- Item 3');
      render(<ContentBlockRenderer message={message} />);

      const list = screen.getByRole('list');
      expect(list.tagName).toBe('UL');

      const items = screen.getAllByRole('listitem');
      expect(items).toHaveLength(3);
      expect(items[0]).toHaveTextContent('Item 1');
      expect(items[1]).toHaveTextContent('Item 2');
      expect(items[2]).toHaveTextContent('Item 3');
    });

    it('renders ordered lists', () => {
      const message = createUserMessage('1. First\n2. Second\n3. Third');
      render(<ContentBlockRenderer message={message} />);

      const list = screen.getByRole('list');
      expect(list.tagName).toBe('OL');

      const items = screen.getAllByRole('listitem');
      expect(items).toHaveLength(3);
      expect(items[0]).toHaveTextContent('First');
      expect(items[1]).toHaveTextContent('Second');
      expect(items[2]).toHaveTextContent('Third');
    });

    it('renders nested lists', () => {
      const message = createUserMessage(
        '- Parent 1\n  - Child 1.1\n  - Child 1.2\n- Parent 2'
      );
      render(<ContentBlockRenderer message={message} />);

      const lists = screen.getAllByRole('list');
      expect(lists.length).toBeGreaterThanOrEqual(2);

      expect(screen.getByText('Parent 1')).toBeInTheDocument();
      expect(screen.getByText('Child 1.1')).toBeInTheDocument();
      expect(screen.getByText('Child 1.2')).toBeInTheDocument();
      expect(screen.getByText('Parent 2')).toBeInTheDocument();
    });

    it('renders task lists (GFM)', () => {
      const message = createUserMessage(
        '- [x] Completed task\n- [ ] Pending task'
      );
      render(<ContentBlockRenderer message={message} />);

      const checkboxes = screen.getAllByRole('checkbox');
      expect(checkboxes).toHaveLength(2);
      expect(checkboxes[0]).toBeChecked();
      expect(checkboxes[1]).not.toBeChecked();
    });
  });

  describe('blockquotes', () => {
    it('renders single blockquote', () => {
      const message = createUserMessage('> This is a quote');
      render(<ContentBlockRenderer message={message} />);

      const blockquote = screen.getByRole('blockquote');
      expect(blockquote).toHaveTextContent('This is a quote');
    });

    it('renders multi-line blockquotes', () => {
      const message = createUserMessage(
        '> Line 1\n> Line 2\n> Line 3'
      );
      render(<ContentBlockRenderer message={message} />);

      const blockquote = screen.getByRole('blockquote');
      expect(blockquote).toHaveTextContent('Line 1');
      expect(blockquote).toHaveTextContent('Line 2');
      expect(blockquote).toHaveTextContent('Line 3');
    });

    it('renders nested blockquotes', () => {
      const message = createUserMessage('> Outer\n>> Nested');
      render(<ContentBlockRenderer message={message} />);

      const blockquotes = screen.getAllByRole('blockquote');
      expect(blockquotes.length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText('Outer')).toBeInTheDocument();
      expect(screen.getByText('Nested')).toBeInTheDocument();
    });
  });

  describe('links', () => {
    it('renders external links', () => {
      const message = createUserMessage(
        '[Google](https://www.google.com)'
      );
      render(<ContentBlockRenderer message={message} />);

      const link = screen.getByRole('link', { name: 'Google' });
      expect(link).toHaveAttribute('href', 'https://www.google.com');
    });

    it('renders multiple links', () => {
      const message = createUserMessage(
        '[Link 1](https://example.com/1) and [Link 2](https://example.com/2)'
      );
      render(<ContentBlockRenderer message={message} />);

      const link1 = screen.getByRole('link', { name: 'Link 1' });
      const link2 = screen.getByRole('link', { name: 'Link 2' });
      expect(link1).toHaveAttribute('href', 'https://example.com/1');
      expect(link2).toHaveAttribute('href', 'https://example.com/2');
    });

    it('renders autolinked URLs (GFM)', () => {
      const message = createUserMessage('Visit https://example.com for more');
      render(<ContentBlockRenderer message={message} />);

      const link = screen.getByRole('link');
      expect(link).toHaveAttribute('href', 'https://example.com');
    });

    it('renders relative/internal links', () => {
      const message = createUserMessage('[Internal](/docs/readme)');
      render(<ContentBlockRenderer message={message} />);

      const link = screen.getByRole('link', { name: 'Internal' });
      expect(link).toHaveAttribute('href', '/docs/readme');
    });
  });

  describe('tables (GFM)', () => {
    it('renders basic table', () => {
      const message = createUserMessage(
        '| Header 1 | Header 2 |\n|----------|----------|\n| Cell 1   | Cell 2   |'
      );
      render(<ContentBlockRenderer message={message} />);

      const table = screen.getByRole('table');
      expect(table).toBeInTheDocument();

      expect(screen.getByText('Header 1')).toBeInTheDocument();
      expect(screen.getByText('Header 2')).toBeInTheDocument();
      expect(screen.getByText('Cell 1')).toBeInTheDocument();
      expect(screen.getByText('Cell 2')).toBeInTheDocument();
    });

    it('renders table with multiple rows', () => {
      const message = createUserMessage(
        '| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |\n| Carol | 35 |'
      );
      render(<ContentBlockRenderer message={message} />);

      const rows = screen.getAllByRole('row');
      expect(rows).toHaveLength(4); // 1 header + 3 data rows

      expect(screen.getByText('Alice')).toBeInTheDocument();
      expect(screen.getByText('Bob')).toBeInTheDocument();
      expect(screen.getByText('Carol')).toBeInTheDocument();
    });
  });

  describe('text formatting', () => {
    it('renders bold text', () => {
      const message = createUserMessage('This is **bold** text');
      render(<ContentBlockRenderer message={message} />);

      const strong = screen.getByText('bold');
      expect(strong.tagName).toBe('STRONG');
    });

    it('renders italic text', () => {
      const message = createUserMessage('This is *italic* text');
      render(<ContentBlockRenderer message={message} />);

      const em = screen.getByText('italic');
      expect(em.tagName).toBe('EM');
    });

    it('renders strikethrough text (GFM)', () => {
      const message = createUserMessage('This is ~~deleted~~ text');
      render(<ContentBlockRenderer message={message} />);

      const del = screen.getByText('deleted');
      expect(del.tagName).toBe('DEL');
    });

    it('renders combined formatting', () => {
      const message = createUserMessage('This is ***bold and italic***');
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByText('bold and italic')).toBeInTheDocument();
    });
  });

  describe('horizontal rules', () => {
    it('renders horizontal rule', () => {
      const message = createUserMessage('Before\n\n---\n\nAfter');
      const { container } = render(
        <ContentBlockRenderer message={message} />
      );

      const hr = container.querySelector('hr');
      expect(hr).toBeInTheDocument();
    });
  });
});

// ============================================================================
// Code Rendering Tests
// ============================================================================

describe('Code rendering', () => {
  describe('inline code', () => {
    it('renders inline code', () => {
      const message = createUserMessage('Use `console.log()` for debugging');
      render(<ContentBlockRenderer message={message} />);

      const code = screen.getByText('console.log()');
      expect(code.tagName).toBe('CODE');
    });

    it('renders multiple inline code snippets', () => {
      const message = createUserMessage(
        'Compare `foo` with `bar` and `baz`'
      );
      render(<ContentBlockRenderer message={message} />);

      expect(screen.getByText('foo').tagName).toBe('CODE');
      expect(screen.getByText('bar').tagName).toBe('CODE');
      expect(screen.getByText('baz').tagName).toBe('CODE');
    });
  });

  describe('code blocks', () => {
    it('renders fenced code block', () => {
      const message = createUserMessage(
        '```\nconst x = 1;\nconst y = 2;\n```'
      );
      const { container } = render(
        <ContentBlockRenderer message={message} />
      );

      const pre = container.querySelector('pre');
      expect(pre).toBeInTheDocument();
      expect(pre).toHaveTextContent('const x = 1;');
      expect(pre).toHaveTextContent('const y = 2;');
    });

    it('renders code block with language specifier', () => {
      const message = createUserMessage(
        '```javascript\nfunction hello() {\n  return "world";\n}\n```'
      );
      const { container } = render(
        <ContentBlockRenderer message={message} />
      );

      const pre = container.querySelector('pre');
      const code = pre?.querySelector('code');
      expect(code).toBeInTheDocument();
      expect(code).toHaveTextContent('function hello()');
    });

    it('renders code block with TypeScript syntax', () => {
      const message = createUserMessage(
        '```typescript\ninterface User {\n  name: string;\n  age: number;\n}\n```'
      );
      const { container } = render(
        <ContentBlockRenderer message={message} />
      );

      const pre = container.querySelector('pre');
      expect(pre).toBeInTheDocument();
      expect(pre).toHaveTextContent('interface User');
      expect(pre).toHaveTextContent('name: string');
    });

    it('renders code block with Python syntax', () => {
      const message = createUserMessage(
        '```python\ndef greet(name):\n    return f"Hello, {name}!"\n```'
      );
      const { container } = render(
        <ContentBlockRenderer message={message} />
      );

      const pre = container.querySelector('pre');
      expect(pre).toBeInTheDocument();
      expect(pre).toHaveTextContent('def greet(name)');
    });

    it('renders multiple code blocks', () => {
      const message = createUserMessage(
        '```js\nconst a = 1;\n```\n\nSome text\n\n```py\nx = 2\n```'
      );
      const { container } = render(
        <ContentBlockRenderer message={message} />
      );

      const preElements = container.querySelectorAll('pre');
      expect(preElements).toHaveLength(2);
    });
  });
});

// ============================================================================
// Thinking Block Tests
// ============================================================================

describe('ThinkingBlock', () => {
  it('renders thinking block as collapsible details', () => {
    const message = createAssistantMessage([
      createThinkingContent('Let me think about this...'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    const details = screen.getByRole('group');
    expect(details).toBeInTheDocument();
    expect(details.tagName).toBe('DETAILS');
  });

  it('renders thinking summary', () => {
    const message = createAssistantMessage([
      createThinkingContent('Internal reasoning here'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('Thinking')).toBeInTheDocument();
  });

  it('renders thinking content in pre tag', () => {
    const thinkingText = 'Step 1: Analyze the problem\nStep 2: Find solution';
    const message = createAssistantMessage([
      createThinkingContent(thinkingText),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    const pre = container.querySelector('pre');
    expect(pre).toBeInTheDocument();
    expect(pre).toHaveTextContent('Step 1: Analyze the problem');
    expect(pre).toHaveTextContent('Step 2: Find solution');
  });

  it('expands and collapses thinking block on click', async () => {
    const user = userEvent.setup();
    const message = createAssistantMessage([
      createThinkingContent('Hidden thinking content'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    const details = screen.getByRole('group') as HTMLDetailsElement;
    const summary = screen.getByText('Thinking');

    // Initially collapsed (depending on browser default)
    expect(details.open).toBe(false);

    // Click to expand
    await user.click(summary);
    expect(details.open).toBe(true);

    // Click to collapse
    await user.click(summary);
    expect(details.open).toBe(false);
  });

  it('has correct class name', () => {
    const message = createAssistantMessage([
      createThinkingContent('Some thoughts'),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    const details = container.querySelector('.thinking-block');
    expect(details).toBeInTheDocument();
  });
});

// ============================================================================
// Tool Call Block Tests
// ============================================================================

describe('ToolCallBlock', () => {
  it('renders tool name', () => {
    const message = createAssistantMessage([
      createToolCall('read', { path: '/tmp/file.txt' }),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('read')).toBeInTheDocument();
  });

  it('renders tool call id', () => {
    const message = createAssistantMessage([
      createToolCall('write', { path: '/out.txt' }, 'call-abc-123'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText(/id: call-abc-123/)).toBeInTheDocument();
  });

  it('renders tool arguments as JSON', () => {
    const message = createAssistantMessage([
      createToolCall('bash', { command: 'ls -la', timeout: 5000 }),
    ]);
    render(<ContentBlockRenderer message={message} />);

    // JSON.stringify with indentation
    expect(screen.getByText(/"command": "ls -la"/)).toBeInTheDocument();
    expect(screen.getByText(/"timeout": 5000/)).toBeInTheDocument();
  });

  it('renders complex nested arguments', () => {
    const message = createAssistantMessage([
      createToolCall('api_call', {
        endpoint: '/users',
        method: 'POST',
        body: { name: 'Test', roles: ['admin', 'user'] },
      }),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText(/"endpoint": "\/users"/)).toBeInTheDocument();
    expect(screen.getByText(/"method": "POST"/)).toBeInTheDocument();
  });

  it('has correct class names', () => {
    const message = createAssistantMessage([
      createToolCall('grep', { pattern: 'test' }),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    expect(container.querySelector('.tool-call-block')).toBeInTheDocument();
    expect(
      container.querySelector('.tool-call-block__header')
    ).toBeInTheDocument();
    expect(
      container.querySelector('.tool-call-block__id')
    ).toBeInTheDocument();
  });

  it('renders empty arguments object', () => {
    const message = createAssistantMessage([
      createToolCall('ping', {}),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    const pre = container.querySelector('pre');
    expect(pre).toHaveTextContent('{}');
  });
});

// ============================================================================
// Image Block Tests
// ============================================================================

describe('ImageBlock', () => {
  it('renders image with base64 data URI', () => {
    const base64Data = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    const message = createAssistantMessage([
      createImageContent(base64Data, 'image/png'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    const img = screen.getByRole('img');
    expect(img).toHaveAttribute(
      'src',
      `data:image/png;base64,${base64Data}`
    );
  });

  it('renders image with correct alt text', () => {
    const message = createAssistantMessage([
      createImageContent('abc123', 'image/jpeg'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    const img = screen.getByRole('img');
    expect(img).toHaveAttribute('alt', 'Assistant supplied');
  });

  it('renders image in figure element', () => {
    const message = createAssistantMessage([
      createImageContent('base64data', 'image/gif'),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    const figure = container.querySelector('figure.image-block');
    expect(figure).toBeInTheDocument();
    expect(figure?.querySelector('img')).toBeInTheDocument();
  });

  it('handles different mime types', () => {
    const testCases = [
      { mimeType: 'image/png', expected: 'data:image/png;base64,test' },
      { mimeType: 'image/jpeg', expected: 'data:image/jpeg;base64,test' },
      { mimeType: 'image/gif', expected: 'data:image/gif;base64,test' },
      { mimeType: 'image/webp', expected: 'data:image/webp;base64,test' },
    ];

    testCases.forEach(({ mimeType, expected }) => {
      cleanup();
      const message = createAssistantMessage([
        createImageContent('test', mimeType),
      ]);
      render(<ContentBlockRenderer message={message} />);

      const img = screen.getByRole('img');
      expect(img).toHaveAttribute('src', expected);
    });
  });
});

// ============================================================================
// Multiple Content Blocks Tests
// ============================================================================

describe('Multiple content blocks', () => {
  it('renders multiple text blocks', () => {
    const message = createAssistantMessage([
      createTextContent('First paragraph'),
      createTextContent('Second paragraph'),
      createTextContent('Third paragraph'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('First paragraph')).toBeInTheDocument();
    expect(screen.getByText('Second paragraph')).toBeInTheDocument();
    expect(screen.getByText('Third paragraph')).toBeInTheDocument();
  });

  it('renders mixed content types', () => {
    const message = createAssistantMessage([
      createTextContent('Here is my analysis:'),
      createThinkingContent('Let me think...'),
      createToolCall('read', { path: '/data.json' }),
      createTextContent('Based on the file contents...'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('Here is my analysis:')).toBeInTheDocument();
    expect(screen.getByText('Thinking')).toBeInTheDocument();
    expect(screen.getByText('read')).toBeInTheDocument();
    expect(screen.getByText('Based on the file contents...')).toBeInTheDocument();
  });

  it('renders content blocks in correct order', () => {
    const message = createAssistantMessage([
      createTextContent('Block 1'),
      createTextContent('Block 2'),
      createTextContent('Block 3'),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    const contentBlocks = container.querySelector('.content-blocks');
    expect(contentBlocks).toBeInTheDocument();

    const paragraphs = contentBlocks?.querySelectorAll('p');
    expect(paragraphs?.[0]).toHaveTextContent('Block 1');
    expect(paragraphs?.[1]).toHaveTextContent('Block 2');
    expect(paragraphs?.[2]).toHaveTextContent('Block 3');
  });

  it('renders thinking followed by tool calls', () => {
    const message = createAssistantMessage([
      createThinkingContent('I need to read the file first'),
      createToolCall('read', { path: '/config.yaml' }, 'call-1'),
      createToolCall('write', { path: '/output.txt' }, 'call-2'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('Thinking')).toBeInTheDocument();
    expect(screen.getByText('read')).toBeInTheDocument();
    expect(screen.getByText('write')).toBeInTheDocument();
    expect(screen.getByText(/id: call-1/)).toBeInTheDocument();
    expect(screen.getByText(/id: call-2/)).toBeInTheDocument();
  });

  it('renders text with embedded code and images', () => {
    const message = createAssistantMessage([
      createTextContent('Here is a code example:\n\n```js\nconsole.log("hello");\n```'),
      createImageContent('imagedata', 'image/png'),
      createTextContent('The image above shows the output.'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('Here is a code example:')).toBeInTheDocument();
    expect(screen.getByRole('img')).toBeInTheDocument();
    expect(screen.getByText('The image above shows the output.')).toBeInTheDocument();
  });
});

// ============================================================================
// Edge Cases and Special Characters
// ============================================================================

describe('Edge cases', () => {
  it('handles empty string content', () => {
    const message = createUserMessage('');
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    // Should render without crashing
    expect(container).toBeInTheDocument();
  });

  it('handles empty content array', () => {
    const message = createAssistantMessage([]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    const contentBlocks = container.querySelector('.content-blocks');
    expect(contentBlocks).toBeInTheDocument();
    expect(contentBlocks?.children).toHaveLength(0);
  });

  it('handles special characters in text', () => {
    const message = createUserMessage(
      'Special chars: <>&"\' and unicode: \u00e9\u00e8\u00ea'
    );
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText(/Special chars:/)).toBeInTheDocument();
  });

  it('handles very long text content', () => {
    const longText = 'A'.repeat(10000);
    const message = createUserMessage(longText);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText(longText)).toBeInTheDocument();
  });

  it('handles text with only whitespace', () => {
    const message = createUserMessage('   \n\n   \t   ');
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    expect(container).toBeInTheDocument();
  });

  it('handles markdown with escaped characters', () => {
    const message = createUserMessage(
      'Use \\*asterisks\\* without formatting'
    );
    render(<ContentBlockRenderer message={message} />);

    // The asterisks should be rendered as literal characters
    expect(screen.getByText(/asterisks/)).toBeInTheDocument();
  });

  it('handles tool call with null/undefined in arguments', () => {
    const message = createAssistantMessage([
      createToolCall('test', { value: null, other: 'valid' } as Record<string, unknown>),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText(/"value": null/)).toBeInTheDocument();
    expect(screen.getByText(/"other": "valid"/)).toBeInTheDocument();
  });
});

// ============================================================================
// Text Content Block Tests
// ============================================================================

describe('TextContent blocks', () => {
  it('renders text content block with markdown', () => {
    const message = createAssistantMessage([
      createTextContent('This is **bold** and *italic*'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    expect(screen.getByText('bold').tagName).toBe('STRONG');
    expect(screen.getByText('italic').tagName).toBe('EM');
  });

  it('renders text content with code blocks', () => {
    const message = createAssistantMessage([
      createTextContent('Example:\n\n```\ncode here\n```'),
    ]);
    const { container } = render(
      <ContentBlockRenderer message={message} />
    );

    expect(screen.getByText('Example:')).toBeInTheDocument();
    expect(container.querySelector('pre')).toHaveTextContent('code here');
  });

  it('renders text content with links', () => {
    const message = createAssistantMessage([
      createTextContent('Visit [our docs](https://docs.example.com)'),
    ]);
    render(<ContentBlockRenderer message={message} />);

    const link = screen.getByRole('link', { name: 'our docs' });
    expect(link).toHaveAttribute('href', 'https://docs.example.com');
  });
});
