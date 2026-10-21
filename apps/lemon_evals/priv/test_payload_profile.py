"""Offline profiler contracts. Run with cached tiktoken; network is forbidden.

All usage below comes from explicitly synthetic provider SSE fixtures, not a
measurement of the operator's real campaign or a model response.
"""
import json
from pathlib import Path
import socket
import unittest
from unittest.mock import patch

with patch.object(socket.socket, 'connect', side_effect=AssertionError('offline tokenizer cache required')), \
        patch.object(socket, 'getaddrinfo', side_effect=AssertionError('offline tokenizer cache required')):
    import payload_profile as profiler

FIXTURES = Path(__file__).resolve().parents[2] / 'lemon_ai/test/fixtures/openai_completions'


def fixture_usage(name):
    events = [json.loads(line[6:]) for line in (FIXTURES / name).read_text().splitlines()
              if line.startswith('data: ') and line != 'data: [DONE]']
    return next(event['usage'] for event in events if isinstance(event.get('usage'), dict))


class PayloadProfileTests(unittest.TestCase):
    def test_complete_compatible_usage_has_disjoint_cache_and_reasoning_subset(self):
        usage = profiler.sanitize_usage(fixture_usage('compatible_complete.sse'))
        self.assertEqual({key: usage[key] for key in (
            'input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens',
            'total_tokens', 'reasoning_output_tokens')}, {
                'input_tokens': 70, 'output_tokens': 30, 'cache_read_tokens': 20,
                'cache_write_tokens': 10, 'total_tokens': 130, 'reasoning_output_tokens': 12})
        self.assertEqual(sum(usage[key] for key in (
            'input_tokens', 'cache_read_tokens', 'cache_write_tokens', 'output_tokens')), 130)

    def test_zai_optional_write_absence_is_not_a_zero_measurement(self):
        usage = profiler.sanitize_usage(fixture_usage('zai_usage_only.sse'))
        self.assertEqual(usage['cache_read_tokens'], 20)
        self.assertEqual(usage['output_tokens'], 30)
        self.assertEqual(usage['total_tokens'], 130)
        self.assertIsNone(usage['cache_write_tokens'])
        self.assertIsNone(usage['input_tokens'])

    def test_missing_partial_and_responses_usage_never_invent_counters(self):
        self.assertTrue(all(profiler.sanitize_usage({})[key] is None for key in (
            'input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens', 'total_tokens')))
        partial = profiler.sanitize_usage({'completion_tokens': 7})
        self.assertEqual(partial['output_tokens'], 7)
        self.assertIsNone(partial['input_tokens'])
        self.assertIsNone(partial['total_tokens'])
        response = profiler.sanitize_usage({
            'input_tokens': 100, 'output_tokens': 30, 'total_tokens': 130,
            'input_tokens_details': {'cached_tokens': 20, 'cache_write_tokens': 10},
            'output_tokens_details': {'reasoning_tokens': 12}})
        self.assertEqual(response, profiler.sanitize_usage(fixture_usage('compatible_complete.sse')))

    def test_chat_payload_measurements_include_actual_messages_and_tool_names_without_text(self):
        secret = 'private fixture conversation bytes'
        body = {'messages': [{'role': 'system', 'content': secret},
                             {'role': 'user', 'content': secret},
                             {'role': 'tool', 'tool_call_id': 'private-id', 'content': secret}],
                'tools': [{'type': 'function', 'function': {'name': 'read', 'parameters': {}}}]}
        measured = profiler.measure(body, {})
        self.assertEqual(measured['tool_schemas'][0]['name'], 'read')
        self.assertEqual([item['category'] for item in measured['input_items']], ['user_text', 'tool_output'])
        self.assertGreater(measured['instructions_bytes'], 0)
        self.assertNotIn(secret, json.dumps(measured))
        self.assertNotIn('private-id', json.dumps(measured))
        self.assertIn('tokens_estimate', measured['tool_schemas'][0])


if __name__ == '__main__':
    unittest.main()
