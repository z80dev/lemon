"""Conservative edit/patch failure attribution from production tool events.

Sites are verified against Lemon 4d94b3c8e. Forwarded errors explicitly name the
propagation site, not a fabricated origin. Raw error text never enters reports.
"""
import re

import arena

BASE = 'apps/coding_agent/lib/coding_agent/tools/'
# (tool, class, message signature, source file, line, attribution)
RULES = [
    ('edit', 'text_not_found', r'Could not find the exact text', 'edit.ex', 492, 'producer'),
    ('edit', 'ambiguous_text', r'Found \d+ occurrences', 'edit.ex', 499, 'producer'),
    ('edit', 'no_change', r'No changes made', 'edit.ex', 508, 'producer'),
    ('edit', 'unseen_lines', r'Unseen lines', 'edit.ex', 437, 'producer'),
    ('edit', 'stale_read', r'has been modified on disk since', 'edit.ex', 372, 'producer'),
    ('edit', 'preflight_changed', r'File changed after edit preflight', 'edit.ex', 389, 'producer'),
    ('edit', 'snapshot_path', r'Snapshot header path', 'edit.ex', 340, 'producer'),
    ('edit', 'invalid_parameters', r'Missing required parameter|must be a string|old_text must not be empty', 'edit.ex', 529, 'producer'),
    ('edit', 'invalid_mode', r'mode=|mode must be', 'edit.ex', 348, 'producer'),
    ('edit', 'file_not_found', r'File not found:', 'edit.ex', 489, 'producer'),
    ('edit', 'permission_denied', r'Permission denied:', 'edit.ex', 490, 'producer'),
    ('edit', 'anchored_rejected', r'(?i)snapshot|anchor|hash|start_line|end_line', 'edit.ex', 413, 'propagation'),
    ('patch', 'ambiguous_context', r'Ambiguous patch hunk', 'patch.ex', 1756, 'producer'),
    ('patch', 'context_not_found', r'Context not found for patch hunk', 'patch.ex', 1756, 'producer'),
    ('patch', 'invalid_patch', r'Invalid unified diff|Invalid patch syntax|Invalid Add File|No patch operations|Update File requires', 'patch.ex', 649, 'producer'),
    ('patch', 'stale_read', r'has been modified on disk since', 'patch.ex', 1100, 'producer'),
    ('patch', 'preflight_changed', r'File changed after patch preflight', 'patch.ex', 1130, 'producer'),
    ('patch', 'invalid_parameters', r'patch_text is required|patch_text must be a string', 'patch.ex', 287, 'producer'),
    ('patch', 'file_not_found', r'File not found:', 'patch.ex', 348, 'producer'),
    ('patch', 'file_exists', r'File already exists:', 'patch.ex', 337, 'producer'),
    ('patch', 'file_exists', r'Move destination already exists:', 'patch.ex', 465, 'producer'),
    ('patch', 'path_security', r'Path contains|Path exceeds|Path cannot|Cannot modify', 'patch.ex', 509, 'producer'),
    ('patch', 'newline_mismatch', r'no-newline marker|final-newline marker', 'patch.ex', 1713, 'producer'),
]


def classify(tool, text):
    for name, category, signature, file, line, attribution in RULES:
        if name == tool and re.search(signature, text):
            return {'class': category, 'site': f'{BASE}{file}#L{line}', 'attribution': attribution}
    return {'class': 'unclassified_tool_error',
            'site': f'{BASE}{"edit.ex#L511" if tool == "edit" else "patch.ex#L181"}',
            'attribution': 'propagation'}


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return '\n'.join(text_content(part) for part in value)
    if isinstance(value, dict):
        return '\n'.join(text_content(value[key]) for key in ('text', 'content', 'message', 'error') if key in value)
    return ''


def target_key(tool, args):
    if tool == 'edit':
        return args.get('path') or args.get('file_path')
    text = args.get('patch_text') or args.get('patch') or ''
    paths = re.findall(r'^(?:\*\*\* (?:Update|Add|Delete) File: |\+\+\+ (?:b/)?)(.+)$', text, re.M)
    return tuple(sorted(paths)) or None


def edit_attempts(agent, output):
    """Retries = next same-tool/same-target call following a rejected call.

    One patch call (possibly many hunks) is one edit attempt. Paths are used only
    in memory; neither arguments, paths nor error text are published.
    """
    started, completed, seen = {}, [], set()
    for event in arena.json_lines(output):
        if agent == 'omp':
            if event.get('type') == 'tool_execution_start':
                started[event.get('toolCallId')] = (event.get('toolName'), event.get('args') or {})
            if event.get('type') != 'tool_execution_end':
                continue
            identifier = event.get('toolCallId')
            name, args = started.get(identifier, (event.get('toolName'), {}))
            failed = event.get('isError') is True
            text = text_content(event.get('result'))
        else:
            if event.get('event') != 'agent':
                continue
            payload = event.get('payload')
            if not isinstance(payload, dict) or payload.get('type') != 'tool_use':
                continue
            action = payload.get('action')
            if not isinstance(action, dict):
                continue
            detail = action.get('detail') or {}
            if not isinstance(detail, dict):
                continue
            identifier = detail.get('tool_call_id')
            if payload.get('phase') == 'started':
                started[identifier] = (detail.get('name'), detail.get('args') or {})
            if payload.get('phase') != 'completed' or not identifier:
                continue
            name, args = started.get(identifier, (detail.get('name'), detail.get('args') or {}))
            failed = payload.get('ok') is False
            text = text_content(detail.get('result'))
        if name not in ('edit', 'patch') or not identifier or identifier in seen:
            continue
        seen.add(identifier)
        completed.append((name, args, failed, text))
    pending, result = set(), []
    for tool, args, failed, text in completed:
        target = target_key(tool, args)
        key = (tool, target)
        retry = key in pending if target is not None else None
        if target is not None:
            if failed:
                pending.add(key)
            else:
                pending.discard(key)
        entry = {'tool': tool, 'failed': failed, 'retry': retry}
        if failed:
            entry.update(classify(tool, text) if agent == 'lemon' else
                         {'class': 'omp_tool_error', 'site': None, 'attribution': 'external_reference'})
        result.append(entry)
    return result
