import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


MODULE_PATH = Path(__file__).with_name("vellum_bench.py")
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("vellum_bench", MODULE_PATH)
bench = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = bench
SPEC.loader.exec_module(bench)
import model_providers


class BenchmarkTests(unittest.TestCase):
    def test_grep_retrieval_matches_first_hit_per_page(self):
        pages = [bench.Page(1, "before Needle after needle"), bench.Page(2, "NEEDLE two")]
        hits = bench.grep_retrieve(pages, "needle")
        self.assertEqual([hit["page"] for hit in hits], [1, 2])

    def test_retrieval_metrics(self):
        metrics = bench.score_retrieval([{"page": 4}, {"page": 7}], [7, 8])
        self.assertTrue(metrics["hit"])
        self.assertEqual(metrics["recall"], 0.5)
        self.assertEqual(metrics["reciprocal_rank"], 0.5)

    def test_answer_scoring_is_case_and_whitespace_insensitive(self):
        score = bench.score_answer("It was 10,000 parameters and\n3 TIMES memory.", {"all": ["10,000", "3 times"]})
        self.assertEqual(score["exactness"], 1.0)

    def test_url_manifest_detection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "links.txt").write_text("- https://example.com/a\nhttps://example.com/b\n")
            pages, url_only = bench.Corpus(root, root / "cache").pages("links.txt")
            self.assertEqual(len(pages), 1)
            self.assertTrue(url_only)

    def test_openai_provider_runs_search_tool_loop(self):
        responses = [
            {
                "output": [{"type": "function_call", "name": "searchDocument", "call_id": "call-1", "arguments": '{"query":"LoRA"}'}],
                "usage": {"input_tokens": 10, "output_tokens": 2},
            },
            {
                "output": [{"type": "message", "content": [{"type": "output_text", "text": "Found it."}]}],
                "usage": {"input_tokens": 15, "output_tokens": 4},
            },
        ]

        def execute(name, arguments):
            self.assertEqual(name, "searchDocument")
            self.assertEqual(arguments["query"], "LoRA")
            return "page 1 — LoRA", [{"page": 1, "score": 1.0, "snippet": "LoRA"}]

        with patch.dict("os.environ", {"OPENAI_API_KEY": "fixture"}), patch("model_providers._post", side_effect=responses):
            result = model_providers.run_provider(
                provider="openai", model="gpt-5-fixture", system_prompt="system", user_prompt="question",
                image=None, execute_tool=execute, timeout=1, max_rounds=4, max_output_tokens=100, thinking="low",
                session_id="fixture",
            )
        self.assertEqual(result.answer, "Found it.")
        self.assertEqual(result.rounds, 2)
        self.assertEqual(result.usage["input_tokens"], 25)
        self.assertEqual(result.tool_calls[0]["name"], "searchDocument")
        self.assertEqual(result.retrieval_hits[0]["page"], 1)


if __name__ == "__main__":
    unittest.main()
