"""Tests for scripts/lamp_manifest.py against a local server that imitates MBTA's S3 bucket.

Run: python -m unittest discover -s scripts/tests
"""
import csv
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import lamp_manifest  # noqa: E402

DAYS = ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22"]


class Bucket(BaseHTTPRequestHandler):
    files = {}        # name -> size
    index = None      # index.csv text, or None for 403

    def _answer(self, body):
        name = self.path.rsplit("/", 1)[-1]
        if name == "index.csv" and self.index is not None:
            data = self.index.encode()
        elif name in self.files:
            data = b"x" * self.files[name]
        else:
            self.send_response(403)  # what S3 returns for a missing key without list access
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Last-Modified", "Thu, 22 Oct 2026 18:26:47 GMT")
        self.end_headers()
        if body:
            self.wfile.write(data)

    def do_GET(self):
        self._answer(True)

    def do_HEAD(self):
        self._answer(False)

    def log_message(self, *args):
        pass


def name(day):
    return f"{day}-subway-on-time-performance-v1.parquet"


class ManifestTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Bucket)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/lamp"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_manifest(self):
        tmp = tempfile.mkdtemp()
        out, gaps = os.path.join(tmp, "index.csv"), os.path.join(tmp, "gaps.json")
        code = lamp_manifest.main([out, gaps, "--base", self.base, "--days", "4", "--end", DAYS[-1],
                                   "--attempts", "1", "--wait", "0"])
        rows = list(csv.DictReader(open(out))) if code == 0 else []
        return code, rows, (json.load(open(gaps)) if code == 0 else None)

    def test_missing_index_and_missing_day(self):
        Bucket.index = None
        Bucket.files = {name(d): 20_000 for d in DAYS if d != "2026-10-21"}
        code, rows, gaps = self.run_manifest()
        self.assertEqual(code, 0)
        self.assertEqual([r["service_date"] for r in rows], ["2026-10-19", "2026-10-20", "2026-10-22"])
        self.assertEqual(rows[0]["last_modified"], "2026-10-22 18:26:47+00:00")
        self.assertTrue(rows[0]["file_url"].endswith(name("2026-10-19")))
        self.assertEqual(gaps["list_source"], "file probe")
        self.assertEqual(gaps["not_published"], ["2026-10-21"])
        self.assertEqual(gaps["latest_published"], "2026-10-22")

    def test_empty_day_is_listed_and_flagged(self):
        Bucket.index = None
        Bucket.files = {name(d): (3286 if d == "2026-10-20" else 20_000) for d in DAYS}
        code, rows, gaps = self.run_manifest()
        self.assertEqual(len(rows), 4)
        self.assertEqual(gaps["published_empty"], ["2026-10-20"])
        self.assertEqual(gaps["not_published"], [])

    def test_index_used_when_back(self):
        Bucket.files = {}
        Bucket.index = ("size_bytes,last_modified,service_date,file_url\n"
                        f"20000,2026-10-22 18:26:47+00:00,2026-10-22,{self.base}/{name('2026-10-22')}\n")
        code, rows, gaps = self.run_manifest()
        self.assertEqual(code, 0)
        self.assertEqual(gaps["list_source"], "index.csv")
        self.assertEqual([r["service_date"] for r in rows], ["2026-10-22"])

    def test_nothing_published_fails(self):
        Bucket.index, Bucket.files = None, {}
        code, _, _ = self.run_manifest()
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
