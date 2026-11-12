import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from configpeek.cli import main
from configpeek.lookup import resolve
from configpeek.storage import DocumentError, load_document


class ConfigContracts(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.file = Path(self.directory.name) / "settings space.json"

    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-m", "configpeek", *map(str, args)], capture_output=True, text=True, encoding="utf-8")

    def write(self, value):
        self.file.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")

    def test_all_present_values(self):
        values = [None, False, 0, "", [], {}, "雪\nquoted \"value\"", {"z": 0, "a": {"z": False, "a": 1}}, [1, None, False]]
        for value in values:
            with self.subTest(value=value):
                self.write({"service": {"value": value}})
                process = self.run_cli(self.file, "service.value")
                self.assertEqual((process.returncode, process.stdout, process.stderr), (0, json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", ""))
                self.assertEqual(resolve({"service": {"value": value}}, "service.value"), value)

    def test_dictionary_only_literal_segments(self):
        document = {"0": {" spaced ": "yes"}, "list": [{"x": 1}], "null": None, "scalar": 2, "a.b": 1, "Case": 9}
        self.write(document)
        result = self.run_cli(self.file, "0. spaced ")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '"yes"\n', ""))
        for key in ("list.0.x", "null.x", "scalar.x", "a.b", "case", "missing"):
            with self.subTest(key=key):
                result = self.run_cli(self.file, key)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (3, "", f"configpeek: key not found: {key}\n"))
                with self.assertRaises(KeyError) as caught:
                    resolve(document, key)
                self.assertEqual(caught.exception.args, (key,))

    def test_root_values(self):
        for value in (None, False, 4, "text", [], [3]):
            self.write(value)
            result = self.run_cli(self.file, "x")
            self.assertEqual((result.returncode, result.stdout, result.stderr), (3, "", "configpeek: key not found: x\n"))

    def test_invalid_documents(self):
        invalid = [b"{", b"", b"[] trailing", b'{"x": \xff}', b'{"x": NaN}', b'{"x": Infinity}', b'{"x": -Infinity}']
        for data in invalid:
            with self.subTest(data=data):
                self.file.write_bytes(data)
                self.assert_document_failure(self.file)
        self.assert_document_failure(Path(self.directory.name) / "missing.json")
        self.assert_document_failure(Path(self.directory.name))

    def assert_document_failure(self, path):
        filename = str(path)
        result = self.run_cli(filename, "x")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", f"configpeek: cannot read JSON: {filename}\n"))
        with self.assertRaises(DocumentError) as caught:
            load_document(filename)
        self.assertIsInstance(caught.exception, ValueError)
        self.assertEqual(caught.exception.filename, filename)
        self.assertEqual(str(caught.exception), f"cannot read JSON: {filename}")

    def test_invalid_invocations_before_file_access(self):
        for key in ("", ".a", "a.", "a..b", "."):
            with self.subTest(key=key):
                with self.assertRaises(ValueError) as caught:
                    resolve({}, key)
                self.assertEqual(str(caught.exception), "invalid key path")
                result = self.run_cli(self.file, key)
                self.assertEqual((result.returncode, result.stdout), (2, ""))
                self.assertTrue(result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertNotIn("cannot read JSON", result.stderr)
        for args in ([], [str(self.file)], [str(self.file), "key", "extra"]):
            result = self.run_cli(*args)
            self.assertEqual((result.returncode, result.stdout), (2, ""))
            self.assertIn("usage:", result.stderr)
        result = self.run_cli("--help")
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        self.assertIn("usage:", result.stdout)

    def test_reusable_main(self):
        self.write({"x": None})
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = main([str(self.file), "x"])
        self.assertEqual((result, stdout.getvalue(), stderr.getvalue()), (0, "null\n", ""))
        self.assertEqual(load_document(str(self.file)), {"x": None})
