/**
 * Tests for web formatters (webfetch, websearch).
 */

import { describe, expect, it } from 'vitest';
import { webFormatter, webFetchFormatter, webSearchFormatter, shortenUrl } from './web.js';

describe('shortenUrl', () => {
  it('returns empty string for empty input', () => {
    expect(shortenUrl('')).toBe('');
  });

  it('returns domain only for root URLs', () => {
    expect(shortenUrl('https://example.com')).toBe('example.com');
    expect(shortenUrl('https://example.com/')).toBe('example.com');
  });

  it('combines domain and path', () => {
    expect(shortenUrl('https://example.com/path/to/resource')).toBe('example.com/path/to/resource');
  });

  it('includes query string', () => {
    expect(shortenUrl('https://example.com/api?foo=bar')).toBe('example.com/api?foo=bar');
  });

  it('truncates long URLs to 50 characters', () => {
    const longUrl = 'https://example.com/this/is/a/very/long/path/that/exceeds/the/maximum/length/limit';
    const result = shortenUrl(longUrl);
    expect(result.length).toBeLessThanOrEqual(50);
    expect(result).toContain('...');
  });

  it('handles invalid URLs gracefully', () => {
    expect(shortenUrl('not a valid url')).toBe('not a valid url');
  });

  it('strips protocol from display', () => {
    const result = shortenUrl('https://secure.example.com/page');
    expect(result).not.toContain('https://');
    expect(result).toContain('secure.example.com');
  });
});

describe('webFetchFormatter.formatArgs', () => {
  it('shows shortened URL in summary', () => {
    const result = webFetchFormatter.formatArgs({
      url: 'https://docs.example.com/api/reference/guide',
    });

    expect(result.summary).toContain('docs.example.com');
    expect(result.summary).toContain('/api/reference/guide');
  });

  it('shows full URL in details', () => {
    const url = 'https://example.com/full/path';
    const result = webFetchFormatter.formatArgs({ url });

    expect(result.details).toContain(`URL: ${url}`);
  });

  it('shows format option when provided', () => {
    const result = webFetchFormatter.formatArgs({
      url: 'https://example.com',
      format: 'markdown',
    });

    expect(result.details).toContain('Format: markdown');
  });

  it('shows timeout option when provided', () => {
    const result = webFetchFormatter.formatArgs({
      url: 'https://example.com',
      timeout: 30000,
    });

    expect(result.details).toContain('Timeout: 30000ms');
  });

  it('handles missing URL gracefully', () => {
    const result = webFetchFormatter.formatArgs({});
    expect(result.summary).toBe('');
  });

  it('shows all options together', () => {
    const result = webFetchFormatter.formatArgs({
      url: 'https://example.com/page',
      format: 'text',
      timeout: 10000,
    });

    expect(result.details).toContain('URL: https://example.com/page');
    expect(result.details).toContain('Format: text');
    expect(result.details).toContain('Timeout: 10000ms');
  });
});

describe('webFetchFormatter.formatResult', () => {
  it('shows status, size, and domain in summary', () => {
    const result = webFetchFormatter.formatResult(
      {
        details: {
          status: 200,
          byte_count: 5120,
        },
      },
      { url: 'https://api.example.com/data' }
    );

    expect(result.summary).toContain('[200]');
    expect(result.summary).toContain('5.0 KB');
    expect(result.summary).toContain('from api.example.com');
  });

  it('formats status line with text for known codes', () => {
    const result = webFetchFormatter.formatResult({
      details: { status: 200 },
    });

    expect(result.details).toContain('Status: 200 OK');
  });

  it('formats 404 status correctly', () => {
    const result = webFetchFormatter.formatResult({
      details: { status: 404 },
    });

    expect(result.details).toContain('Status: 404 Not Found');
    expect(result.isError).toBe(true);
  });

  it('formats 500 status correctly', () => {
    const result = webFetchFormatter.formatResult({
      details: { status: 500 },
    });

    expect(result.details).toContain('Status: 500 Internal Server Error');
    expect(result.isError).toBe(true);
  });

  it('shows content type in details', () => {
    const result = webFetchFormatter.formatResult({
      details: {
        status: 200,
        content_type: 'application/json',
      },
    });

    expect(result.details).toContain('Type: application/json');
  });

  it('shows content preview', () => {
    const result = webFetchFormatter.formatResult({
      content: [
        {
          type: 'text',
          text: 'Line 1\nLine 2\nLine 3',
        },
      ],
      details: { status: 200 },
    });

    expect(result.details).toContain('---');
    expect(result.details).toContain('Line 1');
    expect(result.details).toContain('Line 2');
  });

  it('truncates long content preview', () => {
    const result = webFetchFormatter.formatResult({
      content: [
        {
          type: 'text',
          text: 'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8',
        },
      ],
      details: { status: 200 },
    });

    expect(result.details).toContain('... (truncated)');
  });

  it('detects error status (>= 400)', () => {
    expect(
      webFetchFormatter.formatResult({ details: { status: 400 } }).isError
    ).toBe(true);
    expect(
      webFetchFormatter.formatResult({ details: { status: 401 } }).isError
    ).toBe(true);
    expect(
      webFetchFormatter.formatResult({ details: { status: 403 } }).isError
    ).toBe(true);
    expect(
      webFetchFormatter.formatResult({ details: { status: 500 } }).isError
    ).toBe(true);
    expect(
      webFetchFormatter.formatResult({ details: { status: 503 } }).isError
    ).toBe(true);
  });

  it('does not mark success status as error', () => {
    expect(
      webFetchFormatter.formatResult({ details: { status: 200 } }).isError
    ).toBe(false);
    expect(
      webFetchFormatter.formatResult({ details: { status: 201 } }).isError
    ).toBe(false);
    expect(
      webFetchFormatter.formatResult({ details: { status: 301 } }).isError
    ).toBe(false);
  });

  it('handles missing details gracefully', () => {
    const result = webFetchFormatter.formatResult({});
    expect(result.summary).toBe('Fetched');
  });

  it('handles unknown status codes', () => {
    const result = webFetchFormatter.formatResult({
      details: { status: 418 },
    });

    expect(result.details).toContain('Status: 418');
    expect(result.isError).toBe(true);
  });

  it('formats various byte sizes correctly', () => {
    expect(
      webFetchFormatter.formatResult({ details: { status: 200, byte_count: 500 } }).summary
    ).toContain('500 B');

    expect(
      webFetchFormatter.formatResult({ details: { status: 200, byte_count: 2048 } }).summary
    ).toContain('2.0 KB');

    expect(
      webFetchFormatter.formatResult({ details: { status: 200, byte_count: 1048576 } }).summary
    ).toContain('1.0 MB');
  });
});

describe('webSearchFormatter.formatArgs', () => {
  it('shows query in quotes in summary', () => {
    const result = webSearchFormatter.formatArgs({
      query: 'vitest testing framework',
    });

    expect(result.summary).toBe('"vitest testing framework"');
  });

  it('truncates long queries in summary', () => {
    const longQuery = 'This is a very long search query that exceeds the maximum display length for summaries';
    const result = webSearchFormatter.formatArgs({ query: longQuery });

    expect(result.summary.length).toBeLessThanOrEqual(65); // quotes + truncated
    expect(result.summary).toContain('...');
  });

  it('shows full query in details', () => {
    const query = 'search query here';
    const result = webSearchFormatter.formatArgs({ query });

    expect(result.details).toContain(`Query: ${query}`);
  });

  it('shows max_results option when provided', () => {
    const result = webSearchFormatter.formatArgs({
      query: 'test',
      max_results: 5,
    });

    expect(result.details).toContain('Max results: 5');
  });

  it('shows region option when provided', () => {
    const result = webSearchFormatter.formatArgs({
      query: 'test',
      region: 'us-en',
    });

    expect(result.details).toContain('Region: us-en');
  });

  it('handles missing query gracefully', () => {
    const result = webSearchFormatter.formatArgs({});
    expect(result.summary).toBe('""');
  });
});

describe('webSearchFormatter.formatResult', () => {
  it('shows result count and query in summary', () => {
    const result = webSearchFormatter.formatResult(
      {
        details: {
          results: [
            { title: 'Result 1', url: 'https://example1.com/page' },
            { title: 'Result 2', url: 'https://example2.com/page' },
            { title: 'Result 3', url: 'https://example3.com/page' },
          ],
        },
      },
      { query: 'test query' }
    );

    expect(result.summary).toBe('3 results for "test query"');
  });

  it('handles singular result correctly', () => {
    const result = webSearchFormatter.formatResult(
      {
        details: {
          results: [{ title: 'Only Result', url: 'https://example.com' }],
        },
      },
      { query: 'specific search' }
    );

    expect(result.summary).toBe('1 result for "specific search"');
  });

  it('shows numbered result list with title and domain', () => {
    const result = webSearchFormatter.formatResult({
      details: {
        results: [
          { title: 'First Result', url: 'https://first.example.com/page' },
          { title: 'Second Result', url: 'https://second.example.com/doc' },
        ],
      },
    });

    expect(result.details).toContain('1. First Result - first.example.com');
    expect(result.details).toContain('2. Second Result - second.example.com');
  });

  it('extracts domain correctly from URLs', () => {
    const result = webSearchFormatter.formatResult({
      details: {
        results: [
          { title: 'Docs', url: 'https://docs.example.com/api/v2/reference?param=value' },
        ],
      },
    });

    // Check that a detail line contains the domain
    expect(result.details.some((d) => d.includes('docs.example.com'))).toBe(true);
    // Query params should not be included (domain extraction strips them)
    expect(result.details.some((d) => d.includes('?param=value'))).toBe(false);
  });

  it('limits displayed results to 10', () => {
    const manyResults = Array.from({ length: 15 }, (_, i) => ({
      title: `Result ${i + 1}`,
      url: `https://example${i + 1}.com`,
    }));

    const result = webSearchFormatter.formatResult({
      details: { results: manyResults },
    });

    expect(result.details.some((d) => d.startsWith('1. Result 1'))).toBe(true);
    expect(result.details.some((d) => d.startsWith('10. Result 10'))).toBe(true);
    expect(result.details.some((d) => d.startsWith('11. Result 11'))).toBe(false);
    expect(result.details.some((d) => d.includes('(5 more)'))).toBe(true);
  });

  it('handles no results', () => {
    const result = webSearchFormatter.formatResult(
      { details: { results: [] } },
      { query: 'obscure query' }
    );

    expect(result.summary).toContain('No results');
    expect(result.summary).toContain('obscure query');
  });

  it('falls back to text content when no structured results', () => {
    const result = webSearchFormatter.formatResult({
      content: [
        {
          type: 'text',
          text: '1. First item\n2. Second item\n3. Third item',
        },
      ],
    });

    expect(result.summary).toContain('3 result');
    expect(result.details).toContain('1. First item');
  });

  it('truncates long query in summary', () => {
    const longQuery = 'This is a very long search query that should be truncated in the summary display';
    const result = webSearchFormatter.formatResult(
      {
        details: {
          results: [{ title: 'Result', url: 'https://example.com' }],
        },
      },
      { query: longQuery }
    );

    expect(result.summary).toContain('...');
  });

  it('handles missing args gracefully', () => {
    const result = webSearchFormatter.formatResult({
      details: {
        results: [{ title: 'Result', url: 'https://example.com' }],
      },
    });

    expect(result.summary).toBe('1 result');
  });
});

describe('webFormatter (combined)', () => {
  it('routes formatArgs to webfetch for URL args', () => {
    const result = webFormatter.formatArgs({
      url: 'https://example.com/page',
    });

    expect(result.summary).toContain('example.com');
  });

  it('routes formatArgs to websearch for query args', () => {
    const result = webFormatter.formatArgs({
      query: 'search term',
    });

    expect(result.summary).toBe('"search term"');
  });

  it('routes formatResult to webfetch when args have url', () => {
    const result = webFormatter.formatResult(
      { details: { status: 200 } },
      { url: 'https://example.com' }
    );

    expect(result.details).toContain('Status: 200 OK');
  });

  it('routes formatResult to websearch when args have query', () => {
    const result = webFormatter.formatResult(
      { details: { results: [] } },
      { query: 'test' }
    );

    expect(result.summary).toContain('No results');
  });

  it('detects webfetch from result structure', () => {
    const result = webFormatter.formatResult({
      details: { status: 404, byte_count: 100 },
    });

    expect(result.isError).toBe(true);
  });

  it('detects websearch from result structure', () => {
    const result = webFormatter.formatResult({
      details: {
        results: [{ title: 'Test', url: 'https://test.com' }],
      },
    });

    expect(result.summary).toContain('1 result');
  });

  it('includes both tools in tools array', () => {
    expect(webFormatter.tools).toContain('webfetch');
    expect(webFormatter.tools).toContain('websearch');
  });
});

describe('realistic scenarios', () => {
  it('formats a successful API documentation fetch', () => {
    const args = {
      url: 'https://api.github.com/repos/vitest-dev/vitest',
      format: 'text' as const,
      timeout: 30000,
    };

    const argsResult = webFetchFormatter.formatArgs(args);
    expect(argsResult.summary).toContain('api.github.com');

    const fetchResult = webFetchFormatter.formatResult(
      {
        content: [
          {
            type: 'text',
            text: '{"name": "vitest", "full_name": "vitest-dev/vitest", "description": "A Vite-native testing framework"}',
          },
        ],
        details: {
          status: 200,
          content_type: 'application/json; charset=utf-8',
          byte_count: 15234,
        },
      },
      args
    );

    expect(fetchResult.summary).toContain('[200]');
    expect(fetchResult.summary).toContain('from api.github.com');
    expect(fetchResult.isError).toBe(false);
  });

  it('formats a 404 error response', () => {
    const result = webFetchFormatter.formatResult(
      {
        content: [{ type: 'text', text: 'Page not found' }],
        details: {
          status: 404,
          byte_count: 14,
        },
      },
      { url: 'https://example.com/nonexistent' }
    );

    expect(result.summary).toContain('[404]');
    expect(result.isError).toBe(true);
    expect(result.details).toContain('Status: 404 Not Found');
  });

  it('formats search results for documentation query', () => {
    const args = {
      query: 'vitest mock functions guide',
      max_results: 5,
    };

    const argsResult = webSearchFormatter.formatArgs(args);
    expect(argsResult.summary).toBe('"vitest mock functions guide"');

    const searchResult = webSearchFormatter.formatResult(
      {
        details: {
          results: [
            {
              title: 'Mocking | Guide | Vitest',
              url: 'https://vitest.dev/guide/mocking.html',
              snippet: 'When writing tests it is common to mock functions...',
            },
            {
              title: 'Mock Functions | Vitest',
              url: 'https://vitest.dev/api/mock.html',
              snippet: 'Create a spy on a function...',
            },
            {
              title: 'Vitest Testing Tutorial - Dev.to',
              url: 'https://dev.to/vitest-testing-guide',
              snippet: 'Complete guide to testing with Vitest...',
            },
          ],
        },
      },
      args
    );

    expect(searchResult.summary).toBe('3 results for "vitest mock functions guide"');
    expect(searchResult.details.some((d) => d.includes('Mocking | Guide | Vitest') && d.includes('vitest.dev'))).toBe(true);
    expect(searchResult.details.some((d) => d.includes('Mock Functions | Vitest') && d.includes('vitest.dev'))).toBe(true);
    expect(searchResult.details.some((d) => d.includes('Vitest Testing Tutorial') && d.includes('dev.to'))).toBe(true);
  });
});
