import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import type {
  Message,
  ContentBlock,
  TextContent,
  ThinkingContent,
  ToolCall,
  ImageContent,
} from '@lemon-web/shared';

interface ContentBlockRendererProps {
  message: Message;
}

export function ContentBlockRenderer({ message }: ContentBlockRendererProps) {
  if (typeof message.content === 'string') {
    return <MarkdownBlock text={message.content} />;
  }

  if (!Array.isArray(message.content)) {
    return <p className="muted">Unsupported content.</p>;
  }

  return (
    <div className="content-blocks">
      {message.content.map((block, index) => (
        <ContentBlock key={`${block.type}-${index}`} block={block} />
      ))}
    </div>
  );
}

function ContentBlock({ block }: { block: ContentBlock }) {
  switch (block.type) {
    case 'text':
      return <MarkdownBlock text={(block as TextContent).text} />;
    case 'thinking':
      return <ThinkingBlock block={block as ThinkingContent} />;
    case 'tool_call':
      return <ToolCallBlock block={block as ToolCall} />;
    case 'image':
      return <ImageBlock block={block as ImageContent} />;
    default:
      return <p className="muted">Unknown content block.</p>;
  }
}

function MarkdownBlock({ text }: { text: string }) {
  return (
    <ReactMarkdown remarkPlugins={[remarkGfm]}>{text}</ReactMarkdown>
  );
}

function ThinkingBlock({ block }: { block: ThinkingContent }) {
  return (
    <details className="thinking-block">
      <summary>Thinking</summary>
      <pre>{block.thinking}</pre>
    </details>
  );
}

function ToolCallBlock({ block }: { block: ToolCall }) {
  return (
    <div className="tool-call-block">
      <div className="tool-call-block__header">
        Tool: <strong>{block.name}</strong>
        <span className="tool-call-block__id">id: {block.id}</span>
      </div>
      <pre>{JSON.stringify(block.arguments, null, 2)}</pre>
    </div>
  );
}

function ImageBlock({ block }: { block: ImageContent }) {
  const src = `data:${block.mime_type};base64,${block.data}`;
  return (
    <figure className="image-block">
      <img src={src} alt="Assistant supplied" />
    </figure>
  );
}
