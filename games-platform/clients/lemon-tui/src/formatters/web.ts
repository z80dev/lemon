/**
 * Formatters for web tools (webfetch, websearch).
 *
 * Handles formatting of web fetch and search arguments and results,
 * including URL shortening, HTTP status display, and search result lists.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { truncateText, truncateLines, extractText, formatBytes } from './base.js';

/** Maximum length for URL in summary */
const URL_SUMMARY_MAX_LENGTH = 50;

/** Maximum lines of content preview */
const CONTENT_PREVIEW_MAX_LINES = 5;

/** Maximum search results to show in details */
const MAX_SEARCH_RESULTS = 10;

/**
 * Arguments structure for webfetch tool.
 */
interface WebFetchArgs {
  url: string;
  format?: 'text' | 'markdown' | 'html';
  timeout?: number;
}

/**
 * Result structure from webfetch tool.
 */
interface WebFetchResult {
  content?: Array<{ type: string; text: string }>;
  details?: {
    status?: number;
    content_type?: string;
    byte_count?: number;
  };
}

/**
 * Arguments structure for websearch tool.
 */
interface WebSearchArgs {
  query: string;
  max_results?: number;
  region?: string;
}

/**
 * Search result item structure.
 */
interface SearchResultItem {
  title: string;
  url: string;
  snippet?: string;
}

/**
 * Result structure from websearch tool.
 */
interface WebSearchResult {
  content?: Array<{ type: string; text: string }>;
  details?: {
    results?: SearchResultItem[];
  };
}

/**
 * Shortens a URL for display, showing domain and truncated path.
 *
 * @param url - The full URL to shorten
 * @returns Shortened URL (domain + path start), truncated to 50 chars
 */
export function shortenUrl(url: string): string {
  if (!url) {
    return '';
  }

  try {
    const parsed = new URL(url);
    const domain = parsed.hostname;
    const path = parsed.pathname + parsed.search;

    // Combine domain and path
    const shortened = path && path !== '/' ? `${domain}${path}` : domain;

    return truncateText(shortened, URL_SUMMARY_MAX_LENGTH);
  } catch {
    // If URL parsing fails, just truncate the raw string
    return truncateText(url, URL_SUMMARY_MAX_LENGTH);
  }
}

/**
 * Extracts the domain from a URL.
 *
 * @param url - The URL to extract domain from
 * @returns The hostname/domain
 */
function getDomain(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

/**
 * Formats HTTP status code with standard text.
 *
 * @param status - The HTTP status code
 * @returns Formatted status string (e.g., "200 OK")
 */
function formatStatus(status: number): string {
  const statusTexts: Record<number, string> = {
    200: 'OK',
    201: 'Created',
    204: 'No Content',
    301: 'Moved Permanently',
    302: 'Found',
    304: 'Not Modified',
    400: 'Bad Request',
    401: 'Unauthorized',
    403: 'Forbidden',
    404: 'Not Found',
    500: 'Internal Server Error',
    502: 'Bad Gateway',
    503: 'Service Unavailable',
  };

  const text = statusTexts[status] || '';
  return text ? `${status} ${text}` : String(status);
}

/**
 * Formatter for webfetch tool.
 */
const webFetchFormatter: ToolFormatter = {
  tools: ['webfetch'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const fetchArgs = args as unknown as WebFetchArgs;
    const url = fetchArgs.url || '';

    // Summary: shortened URL
    const summary = shortenUrl(url);

    // Details: full URL and options
    const details: string[] = [];
    details.push(`URL: ${url}`);

    if (fetchArgs.format) {
      details.push(`Format: ${fetchArgs.format}`);
    }

    if (fetchArgs.timeout !== undefined) {
      details.push(`Timeout: ${fetchArgs.timeout}ms`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const fetchResult = result as WebFetchResult;
    const fetchArgs = args as unknown as WebFetchArgs | undefined;

    // Extract details
    const status = fetchResult?.details?.status;
    const contentType = fetchResult?.details?.content_type;
    const byteCount = fetchResult?.details?.byte_count;

    // Build summary
    const summaryParts: string[] = [];

    if (status !== undefined) {
      summaryParts.push(`[${status}]`);
    }

    if (byteCount !== undefined) {
      summaryParts.push(formatBytes(byteCount));
    }

    if (fetchArgs?.url) {
      summaryParts.push(`from ${getDomain(fetchArgs.url)}`);
    }

    const summary = summaryParts.join(' ') || 'Fetched';

    // Build details
    const details: string[] = [];

    if (status !== undefined) {
      details.push(`Status: ${formatStatus(status)}`);
    }

    if (contentType) {
      details.push(`Type: ${contentType}`);
    }

    // Extract content text for preview
    const text = extractText(fetchResult);
    if (text) {
      details.push('---');

      const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
      const previewLines = truncateLines(lines, CONTENT_PREVIEW_MAX_LINES, false);
      details.push(...previewLines);

      if (lines.length > CONTENT_PREVIEW_MAX_LINES) {
        details.push('... (truncated)');
      }
    }

    // Determine if error based on status code
    const isError = status !== undefined && status >= 400;

    return {
      summary,
      details,
      isError,
    };
  },
};

/**
 * Formatter for websearch tool.
 */
const webSearchFormatter: ToolFormatter = {
  tools: ['websearch'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const searchArgs = args as unknown as WebSearchArgs;
    const query = searchArgs.query || '';

    // Summary: query in quotes
    const summary = `"${truncateText(query, 60)}"`;

    // Details: query and options
    const details: string[] = [];
    details.push(`Query: ${query}`);

    if (searchArgs.max_results !== undefined) {
      details.push(`Max results: ${searchArgs.max_results}`);
    }

    if (searchArgs.region) {
      details.push(`Region: ${searchArgs.region}`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const searchResult = result as WebSearchResult;
    const searchArgs = args as unknown as WebSearchArgs | undefined;

    // Try to get results from details
    const results = searchResult?.details?.results;

    // Build summary and details
    if (results && results.length > 0) {
      const query = searchArgs?.query ? ` for "${truncateText(searchArgs.query, 30)}"` : '';
      const summary = `${results.length} result${results.length === 1 ? '' : 's'}${query}`;

      // Build numbered list of results
      const details: string[] = [];
      const displayResults = results.slice(0, MAX_SEARCH_RESULTS);

      for (let i = 0; i < displayResults.length; i++) {
        const item = displayResults[i];
        const domain = getDomain(item.url);
        details.push(`${i + 1}. ${item.title} - ${domain}`);
      }

      if (results.length > MAX_SEARCH_RESULTS) {
        details.push(`... (${results.length - MAX_SEARCH_RESULTS} more)`);
      }

      return {
        summary,
        details,
      };
    }

    // Fall back to extracting text if no structured results
    const text = extractText(searchResult);
    if (text) {
      // Try to count results from text (look for numbered items)
      const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
      const numberedLines = lines.filter((line) => /^\d+\./.test(line.trim()));

      const resultCount = numberedLines.length || lines.length;
      const query = searchArgs?.query ? ` for "${truncateText(searchArgs.query, 30)}"` : '';
      const summary = `${resultCount} result${resultCount === 1 ? '' : 's'}${query}`;

      // Use numbered lines if available, otherwise first few lines
      const detailLines = numberedLines.length > 0 ? numberedLines : lines;
      const details = truncateLines(detailLines, MAX_SEARCH_RESULTS);

      return {
        summary,
        details,
      };
    }

    // No results
    const query = searchArgs?.query ? ` for "${truncateText(searchArgs.query, 30)}"` : '';
    return {
      summary: `No results${query}`,
      details: [],
    };
  },
};

/**
 * Combined formatter for all web tools.
 *
 * Routes formatting to the appropriate specialized formatter based on tool name.
 */
export const webFormatter: ToolFormatter = {
  tools: ['webfetch', 'websearch'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    // Detect which tool based on args
    if ('url' in args) {
      return webFetchFormatter.formatArgs(args);
    }
    if ('query' in args) {
      return webSearchFormatter.formatArgs(args);
    }
    // Default to search formatter
    return webSearchFormatter.formatArgs(args);
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    // Detect which tool based on args
    if (args && 'url' in args) {
      return webFetchFormatter.formatResult(result, args);
    }
    if (args && 'query' in args) {
      return webSearchFormatter.formatResult(result, args);
    }
    // Try to detect from result structure
    const res = result as Record<string, unknown>;
    if (res?.details && typeof res.details === 'object') {
      const details = res.details as Record<string, unknown>;
      if ('status' in details || 'content_type' in details || 'byte_count' in details) {
        return webFetchFormatter.formatResult(result, args);
      }
      if ('results' in details) {
        return webSearchFormatter.formatResult(result, args);
      }
    }
    // Default to search formatter
    return webSearchFormatter.formatResult(result, args);
  },
};

// Export individual formatters for direct use
export { webFetchFormatter, webSearchFormatter };

export default webFormatter;
