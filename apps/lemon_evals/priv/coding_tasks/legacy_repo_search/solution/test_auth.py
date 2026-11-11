import os
import unittest
from unittest.mock import patch
from service.auth import token


class CredentialTests(unittest.TestCase):
    def test_reads_current_credential(self):
        with patch.dict(os.environ, {"API_TOKEN_V2": "local-test-token"}, clear=True):
            self.assertEqual(token(), "local-test-token")

    def test_missing_credential(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(token())
