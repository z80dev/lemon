/**
 * ErrorBoundary — catches React render errors and shows a recovery UI.
 */

import React from 'react';
import { Box, Text } from 'ink';

interface ErrorBoundaryProps {
  children: React.ReactNode;
  fallbackMessage?: string;
}

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

export class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: React.ErrorInfo): void {
    // Log to stderr so it doesn't interfere with TUI rendering
    process.stderr.write(
      `[ErrorBoundary] ${error.message}\n${errorInfo.componentStack || ''}\n`
    );
  }

  render(): React.ReactNode {
    if (this.state.hasError) {
      const message = this.props.fallbackMessage || 'A component encountered an error';
      return (
        <Box flexDirection="column" borderStyle="round" borderColor="red" paddingX={1}>
          <Text bold color="red">
            {'\u26A0'} {message}
          </Text>
          {this.state.error && (
            <Text color="gray">
              {this.state.error.message.slice(0, 200)}
            </Text>
          )}
          <Text dimColor>
            The error has been logged. The rest of the UI should still work.
          </Text>
        </Box>
      );
    }

    return this.props.children;
  }
}
