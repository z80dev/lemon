/**
 * MarkdownRenderer — renders markdown text as Ink Text components.
 *
 * Two-pass renderer:
 * 1. Block pass: classify lines into headers, code blocks, lists, blockquotes, hr, paragraphs
 * 2. Inline pass: bold, italic, inline code, links within text blocks
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';

interface MarkdownRendererProps {
  content: string;
}

// ============================================================================
// Block types
// ============================================================================

type Block =
  | { type: 'header'; level: number; text: string }
  | { type: 'code'; language: string; lines: string[] }
  | { type: 'paragraph'; text: string }
  | { type: 'unordered-list'; items: string[] }
  | { type: 'ordered-list'; items: string[] }
  | { type: 'blockquote'; text: string }
  | { type: 'table'; headers: string[]; alignments: ('left' | 'center' | 'right')[]; rows: string[][] }
  | { type: 'hr' };

// ============================================================================
// Block pass — classify lines into blocks
// ============================================================================

function parseBlocks(content: string): Block[] {
  const lines = content.split('\n');
  const blocks: Block[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Code fence
    const fenceMatch = line.match(/^(`{3,}|~{3,})(\w*)/);
    if (fenceMatch) {
      const fence = fenceMatch[1];
      const lang = fenceMatch[2] || '';
      const codeLines: string[] = [];
      i++;
      while (i < lines.length) {
        if (lines[i].startsWith(fence)) {
          i++;
          break;
        }
        codeLines.push(lines[i]);
        i++;
      }
      blocks.push({ type: 'code', language: lang, lines: codeLines });
      continue;
    }

    // Blank line — skip
    if (line.trim() === '') {
      i++;
      continue;
    }

    // Horizontal rule
    if (/^(\s{0,3})([-*_])\s*(\2\s*){2,}$/.test(line)) {
      blocks.push({ type: 'hr' });
      i++;
      continue;
    }

    // Header
    const headerMatch = line.match(/^(#{1,3})\s+(.+)$/);
    if (headerMatch) {
      blocks.push({ type: 'header', level: headerMatch[1].length, text: headerMatch[2] });
      i++;
      continue;
    }

    // Blockquote
    if (line.startsWith('> ') || line === '>') {
      const quoteLines: string[] = [];
      while (i < lines.length && (lines[i].startsWith('> ') || lines[i] === '>')) {
        quoteLines.push(lines[i].replace(/^>\s?/, ''));
        i++;
      }
      blocks.push({ type: 'blockquote', text: quoteLines.join('\n') });
      continue;
    }

    // Unordered list
    if (/^\s*[-*+]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*[-*+]\s+/, ''));
        i++;
      }
      blocks.push({ type: 'unordered-list', items });
      continue;
    }

    // Ordered list
    if (/^\s*\d+[.)]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*\d+[.)]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*\d+[.)]\s+/, ''));
        i++;
      }
      blocks.push({ type: 'ordered-list', items });
      continue;
    }

    // Table — pipe-delimited rows with separator line
    if (
      line.includes('|') &&
      i + 1 < lines.length &&
      /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(lines[i + 1])
    ) {
      const parseRow = (row: string): string[] =>
        row.split('|').map((c) => c.trim()).filter((_, idx, arr) => {
          // Remove empty first/last cells from leading/trailing pipes
          if (idx === 0 && arr[idx] === '') return false;
          if (idx === arr.length - 1 && arr[idx] === '') return false;
          return true;
        });

      const headers = parseRow(line);
      const sepCells = parseRow(lines[i + 1]);
      const alignments: ('left' | 'center' | 'right')[] = sepCells.map((cell) => {
        const trimmed = cell.trim();
        if (trimmed.startsWith(':') && trimmed.endsWith(':')) return 'center';
        if (trimmed.endsWith(':')) return 'right';
        return 'left';
      });

      i += 2; // Skip header and separator
      const rows: string[][] = [];
      while (i < lines.length && lines[i].includes('|') && lines[i].trim() !== '') {
        rows.push(parseRow(lines[i]));
        i++;
      }

      blocks.push({ type: 'table', headers, alignments, rows });
      continue;
    }

    // Paragraph — collect consecutive non-special lines
    const paraLines: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() !== '' &&
      !lines[i].match(/^(`{3,}|~{3,})/) &&
      !lines[i].match(/^#{1,3}\s+/) &&
      !lines[i].startsWith('> ') &&
      !/^\s*[-*+]\s+/.test(lines[i]) &&
      !/^\s*\d+[.)]\s+/.test(lines[i]) &&
      !/^(\s{0,3})([-*_])\s*(\2\s*){2,}$/.test(lines[i])
    ) {
      paraLines.push(lines[i]);
      i++;
    }
    if (paraLines.length > 0) {
      blocks.push({ type: 'paragraph', text: paraLines.join('\n') });
    }
  }

  return blocks;
}

// ============================================================================
// Inline pass — parse inline formatting into React nodes
// ============================================================================

interface InlineContext {
  accent: string;
  muted: string;
}

function renderInline(text: string, ctx: InlineContext): React.ReactNode[] {
  const nodes: React.ReactNode[] = [];
  // Match: **bold**, *italic*, `code`, [text](url)
  const pattern = /(\*\*(.+?)\*\*|\*(.+?)\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\))/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  let key = 0;

  while ((match = pattern.exec(text)) !== null) {
    // Text before match
    if (match.index > lastIndex) {
      nodes.push(<Text key={key++}>{text.slice(lastIndex, match.index)}</Text>);
    }

    if (match[2] !== undefined) {
      // **bold**
      nodes.push(<Text key={key++} bold>{match[2]}</Text>);
    } else if (match[3] !== undefined) {
      // *italic*
      nodes.push(<Text key={key++} dimColor>{match[3]}</Text>);
    } else if (match[4] !== undefined) {
      // `code`
      nodes.push(<Text key={key++} color={ctx.accent}>{match[4]}</Text>);
    } else if (match[5] !== undefined && match[6] !== undefined) {
      // [text](url)
      nodes.push(
        <Text key={key++}>
          <Text underline>{match[5]}</Text>
          <Text dimColor> ({match[6]})</Text>
        </Text>
      );
    }

    lastIndex = match.index + match[0].length;
  }

  // Remaining text
  if (lastIndex < text.length) {
    nodes.push(<Text key={key++}>{text.slice(lastIndex)}</Text>);
  }

  return nodes.length > 0 ? nodes : [<Text key={0}>{text}</Text>];
}

// ============================================================================
// Block renderers
// ============================================================================

function renderBlock(block: Block, index: number, ctx: InlineContext & { primary: string; border: string }): React.ReactNode {
  switch (block.type) {
    case 'header':
      return (
        <Box key={index} marginTop={index > 0 ? 1 : 0}>
          <Text bold color={ctx.primary}>
            {renderInline(block.text, ctx)}
          </Text>
        </Box>
      );

    case 'code': {
      const gutterWidth = String(block.lines.length).length;
      return (
        <Box key={index} flexDirection="column" marginLeft={1}>
          {block.language && (
            <Text color={ctx.muted}>{'\u250C'} {block.language}</Text>
          )}
          {block.lines.map((line, li) => {
            const lineNum = String(li + 1).padStart(gutterWidth, ' ');
            return (
              <Box key={li}>
                <Text color={ctx.muted}>{lineNum} {'\u2502'} </Text>
                <Text color={ctx.accent}>{line}</Text>
              </Box>
            );
          })}
        </Box>
      );
    }

    case 'paragraph':
      return (
        <Box key={index}>
          <Text>{renderInline(block.text, ctx)}</Text>
        </Box>
      );

    case 'unordered-list':
      return (
        <Box key={index} flexDirection="column">
          {block.items.map((item, li) => (
            <Box key={li}>
              <Text>  {'\u2022'} </Text>
              <Text>{renderInline(item, ctx)}</Text>
            </Box>
          ))}
        </Box>
      );

    case 'ordered-list':
      return (
        <Box key={index} flexDirection="column">
          {block.items.map((item, li) => (
            <Box key={li}>
              <Text>  {li + 1}. </Text>
              <Text>{renderInline(item, ctx)}</Text>
            </Box>
          ))}
        </Box>
      );

    case 'blockquote':
      return (
        <Box key={index} marginLeft={1}>
          <Text color={ctx.border}>{'\u2502'} </Text>
          <Text dimColor>{renderInline(block.text, ctx)}</Text>
        </Box>
      );

    case 'table': {
      // Calculate column widths
      const colCount = block.headers.length;
      const colWidths: number[] = new Array(colCount).fill(0);
      for (let c = 0; c < colCount; c++) {
        colWidths[c] = Math.max(colWidths[c], (block.headers[c] || '').length);
        for (const row of block.rows) {
          colWidths[c] = Math.max(colWidths[c], (row[c] || '').length);
        }
      }

      const padCell = (text: string, width: number, align: 'left' | 'center' | 'right'): string => {
        const pad = width - text.length;
        if (pad <= 0) return text;
        if (align === 'right') return ' '.repeat(pad) + text;
        if (align === 'center') {
          const left = Math.floor(pad / 2);
          return ' '.repeat(left) + text + ' '.repeat(pad - left);
        }
        return text + ' '.repeat(pad);
      };

      const renderTableRow = (cells: string[], bold: boolean, key: string) => (
        <Box key={key}>
          <Text color={ctx.border}>{'\u2502'}</Text>
          {cells.map((cell, c) => (
            <React.Fragment key={c}>
              <Text bold={bold}>
                {' '}{padCell(cell || '', colWidths[c], block.alignments[c] || 'left')}{' '}
              </Text>
              <Text color={ctx.border}>{'\u2502'}</Text>
            </React.Fragment>
          ))}
        </Box>
      );

      const separator = (
        <Box key={`${index}-sep`}>
          <Text color={ctx.border}>
            {'\u251C'}{colWidths.map((w) => '\u2500'.repeat(w + 2)).join('\u253C')}{'\u2524'}
          </Text>
        </Box>
      );

      return (
        <Box key={index} flexDirection="column">
          {renderTableRow(block.headers, true, `${index}-h`)}
          {separator}
          {block.rows.map((row, ri) => renderTableRow(row, false, `${index}-r${ri}`))}
        </Box>
      );
    }

    case 'hr':
      return (
        <Box key={index}>
          <Text color={ctx.border}>{'\u2500'.repeat(40)}</Text>
        </Box>
      );
  }
}

// ============================================================================
// Component
// ============================================================================

export function MarkdownRenderer({ content }: MarkdownRendererProps) {
  const theme = useTheme();

  const rendered = React.useMemo(() => {
    const blocks = parseBlocks(content);
    const ctx = {
      primary: theme.primary,
      accent: theme.accent,
      muted: theme.muted,
      border: theme.border,
    };
    return blocks.map((block, i) => renderBlock(block, i, ctx));
  }, [content, theme.primary, theme.accent, theme.muted, theme.border]);

  return (
    <Box flexDirection="column">
      {rendered}
    </Box>
  );
}
