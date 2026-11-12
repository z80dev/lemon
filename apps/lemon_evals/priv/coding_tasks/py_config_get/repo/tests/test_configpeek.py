import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from configpeek.cli import main
from configpeek.lookup import resolve
from configpeek.storage import DocumentError, load_document


class ConfigpeekTests(unittest.TestCase):
    def test_nested_value(self):
        self.assertEqual(resolve({"database": {"host": "localhost"}}, "database.host"), "localhost")

    def test_missing_value(self):
        with self.assertRaises(KeyError):
            resolve({"database": {}}, "database.host")

    def test_command(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.json"
            path.write_text(json.dumps({"service": {"port": 8080}}))
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                status = main([str(path), "service.port"])
            self.assertEqual((status, stdout.getvalue(), stderr.getvalue()), (0, "8080\n", ""))

    def test_document_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(DocumentError):
                load_document(str(Path(directory) / "absent.json"))
