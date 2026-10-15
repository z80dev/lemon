#!/usr/bin/env python3
"""In-memory request measurement; output contains counts/hashes, never payload text."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tiktoken

ENCODER = tiktoken.get_encoding('o200k_base')
NUMBERS = ('input_tokens', 'output_tokens', 'cached_tokens', 'cache_write_tokens')


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def count(text):
    return len(ENCODER.encode(text, disallowed_special=()))


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def numeric(value):
    return {key: value[key] for key in NUMBERS if isinstance(value.get(key), (int, float)) and not isinstance(value[key], bool)}


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def strip_opaque(value):
    opaque = 0
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == 'encrypted_content':
                opaque += len(str(item).encode('utf-8'))
            else:
                result[key], size = strip_opaque(item)
                opaque += size
        return result, opaque
    if isinstance(value, list):
        result = []
        for item in value:
            clean, size = strip_opaque(item)
            result.append(clean)
            opaque += size
        return result, opaque
    return value, 0


def category(item):
    kind = item.get('type', 'message')
    if kind == 'function_call_output': return 'tool_output'
    if kind == 'function_call': return 'tool_arguments'
    if kind == 'reasoning': return 'assistant_reasoning'
    if kind == 'message': return 'user_text' if item.get('role') == 'user' else 'assistant_text'
    return 'other'


def instructions_sections(text):
    groups = {}
    section = 'core_instructions'
    for line in text.splitlines(keepends=True):
        if line.startswith('#'):
            heading = line.lower()
            if any(term in heading for term in ('agents.md', 'claude.md', 'project instruction', 'project memory')): section = 'project_instructions'
            elif 'tool' in heading: section = 'tool_instructions'
            elif 'skill' in heading: section = 'skill_metadata'
            elif any(term in heading for term in ('workspace', 'identity', 'user.md', 'memory.md')): section = 'workspace_bootstrap'
            elif any(term in heading for term in ('environment', 'working directory', 'runtime')): section = 'environment'
            else: section = 'core_instructions'
        groups.setdefault(section, []).append(line)
    return {key: {'bytes': len(''.join(lines).encode('utf-8')), 'tokens_estimate': count(''.join(lines))} for key, lines in groups.items()}


def measure(body, previous):
    instructions = body.get('instructions') or ''
    if not isinstance(instructions, str): instructions = encoded(instructions)
    tools = body.get('tools') or []
    tools_text = encoded(tools)
    common = os.path.commonprefix([previous.get('instructions', ''), instructions])
    old_items = previous.setdefault('item_hashes', set())
    estimates = {'instructions': count(instructions), 'tool_schemas': count(tools_text)}
    items = []
    repeated = 0
    opaque_bytes = 0
    calls = {item.get('call_id'): item.get('name', 'unknown') for item in body.get('input') or [] if item.get('type') == 'function_call'}
    for index, item in enumerate(body.get('input') or []):
        clean, opaque = strip_opaque(item)
        opaque_bytes += opaque
        text = encoded(clean)
        fingerprint = digest(text)
        bucket = category(clean)
        tokens = count(text)
        estimates[bucket] = estimates.get(bucket, 0) + tokens
        was_seen = fingerprint in old_items
        if was_seen: repeated += tokens
        old_items.add(fingerprint)
        row = {'index': index, 'category': bucket, 'bytes': len(text.encode('utf-8')), 'tokens_estimate': tokens, 'hash': fingerprint, 'repeated': was_seen}
        for key in ('id', 'call_id'):
            if isinstance(clean.get(key), str): row[key + '_hash'] = digest(clean[key])
        if bucket == 'tool_arguments': row['tool'] = clean.get('name', 'unknown')
        if bucket == 'tool_output': row['tool'] = calls.get(clean.get('call_id'), 'unknown')
        items.append(row)
    tool_rows = [{'name': tool.get('name', 'unknown'), 'bytes': len(encoded(tool).encode('utf-8')), 'tokens_estimate': count(encoded(tool))} for tool in tools]
    output = {'tokenizer': 'o200k_base', 'estimates': estimates,
              'repeated_estimates': {'instructions': count(common), 'tool_schemas': count(tools_text) if previous.get('tools_hash') == digest(tools_text) else 0, 'input': repeated},
              'instructions_bytes': len(instructions.encode('utf-8')), 'instruction_sections': instructions_sections(instructions),
              'tool_schemas': tool_rows, 'tools_catalog_digest': digest(tools_text),
              'input_items': items, 'opaque_replay_bytes': opaque_bytes,
              'reasoning': (body.get('reasoning') or {}).get('effort', 'provider_default')}
    previous['instructions'] = instructions
    previous['tools_hash'] = digest(tools_text)
    return output


def sanitize_usage(usage):
    attribution = usage.get('attribution') or {}
    fields = attribution.get('request_fields') or {}
    items = attribution.get('items') or {}
    return {'input_tokens': number(usage.get('input_tokens')), 'output_tokens': number(usage.get('output_tokens')), 'total_tokens': number(usage.get('total_tokens')),
            'cache_read_tokens': number((usage.get('input_tokens_details') or {}).get('cached_tokens')),
            'cache_write_tokens': number((usage.get('input_tokens_details') or {}).get('cache_write_tokens')),
            'reasoning_output_tokens': number((usage.get('output_tokens_details') or {}).get('reasoning_tokens')),
            'request_fields': {key: numeric(value) for key, value in fields.items() if key in ('instructions', 'tools', 'input') and isinstance(value, dict)},
            'item_usage': [{'id_hash': digest(key), **numeric(value)} for key, value in items.items() if isinstance(value, dict)]}


def main():
    output = Path(sys.argv[1])
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    state = {}
    with os.fdopen(descriptor, 'w', encoding='utf-8') as destination:
        print(json.dumps({'event': 'ready'}), flush=True)
        for line in sys.stdin:
            packet = json.loads(line)
            metadata = packet['metadata']
            key = (metadata.get('run_id'), metadata.get('session_id'))
            previous = state.setdefault(key, {'request_index': 0})
            event = packet['event']
            if event == 'payload':
                previous['request_index'] += 1
                details = measure(packet['data'], previous)
            elif event == 'usage':
                details = {'provider_usage': sanitize_usage(packet['data'])}
            elif event == 'disclosure_applied':
                data = packet['data']
                details = {'profile': data['profile'] if data.get('profile') in ('coding', 'legacy') else None,
                           'active': data.get('active') if type(data.get('active')) is bool else None}
                details['diagnostic_events_version'] = 1 if data.get('diagnostic_events_version') == 1 else None
                catalog = data.get('catalog_digest')
                details['catalog_digest'] = catalog if isinstance(catalog, str) and len(catalog) == 64 and all(character in '0123456789abcdef' for character in catalog) else None
                for key in ('estimated_tokens', 'disclosed_tokens', 'hidden_count', 'disclosed_count'):
                    details[key] = number(data.get(key))
            elif event == 'disclosure_search':
                data = packet['data']
                details = {'status': data.get('status') if data.get('status') in ('ok', 'error') else None,
                           'matched_count': number(data.get('matched_count'))}
            elif event == 'disclosure_rejected':
                data = packet['data']
                details = {'reason': data.get('reason') if data.get('reason') in ('unknown_tool', 'invalid_arguments', 'invalid_request') else None}
            elif event == 'disclosure_invoke':
                data = packet['data']
                target = data.get('resolved_tool_digest', '')
                details = {'resolved_tool_digest': target if len(target) == 64 and all(character in '0123456789abcdef' for character in target) else None,
                           'status': data.get('status') if data.get('status') in ('ok', 'error') else None,
                           'duration_us': number(data.get('duration_us'))}
            else:
                raise ValueError('unsupported profiler event')
            record = {'event': event, **metadata, 'request_index': previous['request_index'], **details}
            destination.write(json.dumps(record, ensure_ascii=False) + '\n')
            destination.flush()
            print(json.dumps({'event': 'recorded'}), flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print(json.dumps({'event': 'error', 'kind': 'profiling_failed'}), flush=True)
        sys.exit(1)
