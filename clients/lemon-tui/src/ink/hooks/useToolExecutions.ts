/**
 * Tool execution selector hooks.
 */

import { useAppSelector } from './useAppState.js';
import type { ToolExecution } from '../../state.js';

export function useToolExecutions(): Map<string, ToolExecution> {
  return useAppSelector((s) => s.toolExecutions);
}

export function useActiveToolExecutions(): ToolExecution[] {
  const toolExecutions = useToolExecutions();
  return Array.from(toolExecutions.values()).filter((t) => !t.endTime);
}
