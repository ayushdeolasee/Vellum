#!/usr/bin/env python3
"""Cost-guarded terminal benchmark for Vellum retrieval and AI pipelines."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import platform
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from model_providers import run_provider


ROOT = Path(__file__).resolve().parents[1]
BENCHMARKS = Path(__file__).resolve().parent
DEFAULT_CORPUS = ROOT / "Tests" / "Texts"
DEFAULT_CASES = BENCHMARKS / "cases.jsonl"
DEFAULT_CACHE = ROOT / ".benchmark-cache"
SCHEMA_VERSION = 1


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}") from error
    return rows


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_manifest(cases_path: Path, sources: list[Path]) -> dict[str, Any]:
    def git(*arguments: str) -> str | None:
        completed = subprocess.run(["git", *arguments], cwd=ROOT, text=True, capture_output=True)
        return completed.stdout.strip() if completed.returncode == 0 else None

    diff = git("diff", "--binary", "HEAD") or ""
    untracked_names = (git("ls-files", "--others", "--exclude-standard") or "").splitlines()
    untracked: dict[str, str] = {}
    for name in untracked_names:
        path = ROOT / name
        if path.is_file():
            untracked[name] = sha256_file(path)

    def display_path(path: Path) -> str:
        try:
            return str(path.relative_to(ROOT))
        except ValueError:
            return str(path)

    return {
        "git_commit": git("rev-parse", "HEAD"),
        "working_tree_fingerprint": hashlib.sha256((diff + "\n" + json.dumps(untracked, sort_keys=True)).encode()).hexdigest(),
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "cases_sha256": sha256_file(cases_path),
        "documents": {display_path(path): sha256_file(path) for path in sorted(set(sources))},
        "benchmark_schema_version": SCHEMA_VERSION,
        "extraction": "PDFKit/PDFPage.string" if sys.platform == "darwin" and shutil.which("swiftc") else "Poppler/pdftotext fallback",
    }


def normalized(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip().casefold()


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int((len(ordered) - 1) * fraction)))
    return ordered[index]


@dataclass
class Page:
    number: int
    text: str


class Corpus:
    def __init__(self, corpus_dir: Path, cache_dir: Path):
        self.corpus_dir = corpus_dir
        self.cache_dir = cache_dir

    def source(self, name: str) -> Path:
        path = (self.corpus_dir / name).resolve()
        if self.corpus_dir.resolve() not in path.parents or not path.is_file():
            raise ValueError(f"corpus source does not exist: {name}")
        return path

    def pages(self, name: str) -> tuple[list[Page], bool]:
        source = self.source(name)
        if source.suffix.casefold() == ".pdf":
            return self._pdf_pages(source), False
        text = source.read_text(encoding="utf-8", errors="replace")
        # A URL-only file is a manifest, not locally benchmarkable article text.
        url_only = bool(text.strip()) and all(
            not line.strip() or re.match(r"^-?\s*https?://", line.strip())
            for line in text.splitlines()
        )
        return [Page(1, text)], url_only

    def _pdf_pages(self, source: Path) -> list[Page]:
        extractor = self._pdfkit_extractor()
        if extractor is None and not shutil.which("pdftotext"):
            raise RuntimeError("PDF extraction requires Swift/PDFKit or pdftotext")
        stat = source.stat()
        backend = "pdfkit-v1" if extractor else "pdftotext-v1"
        fingerprint = hashlib.sha256(
            f"{backend}:{source.resolve()}:{stat.st_size}:{stat.st_mtime_ns}".encode()
        ).hexdigest()[:20]
        output = self.cache_dir / "text" / f"{fingerprint}.json"
        if not output.exists():
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = output.with_suffix(".tmp")
            if extractor:
                subprocess.run([str(extractor), str(source), str(temporary)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            else:
                with tempfile.TemporaryDirectory() as directory:
                    text_output = Path(directory) / "pages.txt"
                    subprocess.run(["pdftotext", "-layout", str(source), str(text_output)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                    pages = text_output.read_text(encoding="utf-8", errors="replace").split("\f")
                    temporary.write_text(json.dumps(pages), encoding="utf-8")
            temporary.replace(output)
        values = json.loads(output.read_text(encoding="utf-8"))
        return [Page(index, value) for index, value in enumerate(values, 1)]

    def _pdfkit_extractor(self) -> Path | None:
        source = BENCHMARKS / "pdfkit_extract.swift"
        compiler = shutil.which("swiftc")
        if sys.platform != "darwin" or not compiler or not source.exists():
            return None
        digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
        binary = self.cache_dir / "bin" / f"pdfkit-extract-{digest}"
        if not binary.exists():
            binary.parent.mkdir(parents=True, exist_ok=True)
            temporary = binary.with_suffix(".tmp")
            subprocess.run([compiler, str(source), "-o", str(temporary)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            temporary.replace(binary)
        return binary

    def render_page(self, name: str, page: int) -> Path:
        source = self.source(name)
        if source.suffix.casefold() != ".pdf":
            raise ValueError("visual page rendering currently supports PDF sources")
        if not shutil.which("pdftoppm"):
            raise RuntimeError("pdftoppm is required (install Poppler with `brew install poppler`)")
        stat = source.stat()
        fingerprint = hashlib.sha256(
            f"{source.resolve()}:{stat.st_size}:{stat.st_mtime_ns}".encode()
        ).hexdigest()[:20]
        prefix = self.cache_dir / "images" / f"{fingerprint}-p{page}"
        output = prefix.with_suffix(".png")
        if not output.exists():
            output.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["pdftoppm", "-f", str(page), "-l", str(page), "-singlefile", "-png", "-r", "144", str(source), str(prefix)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        return output


def grep_retrieve(pages: list[Page], query: str, limit: int = 8, radius: int = 200) -> list[dict[str, Any]]:
    """Mirror AiToolEngine: case-insensitive literal search, first hit per page."""
    collapsed = re.sub(r"\s+", " ", query).strip()
    if not collapsed:
        return []
    needle = collapsed.casefold()
    hits: list[dict[str, Any]] = []
    for page in pages:
        text = re.sub(r"\s+", " ", page.text).strip()[:100_000]
        index = text.casefold().find(needle)
        if index < 0:
            continue
        start, end = max(0, index - radius), min(len(text), index + len(collapsed) + radius)
        hits.append({"page": page.number, "score": 1.0, "snippet": text[start:end]})
        if len(hits) >= limit:
            break
    return hits


def regex_retrieve(pages: list[Page], query: str, limit: int = 8, radius: int = 200) -> list[dict[str, Any]]:
    try:
        pattern = re.compile(query, re.IGNORECASE)
    except re.error as error:
        raise ValueError(f"invalid regular expression: {error}") from error
    hits: list[dict[str, Any]] = []
    for page in pages:
        text = normalized_page_text(page.text)[:100_000]
        match = pattern.search(text)
        if not match:
            continue
        start, end = max(0, match.start() - radius), min(len(text), match.end() + radius)
        hits.append({"page": page.number, "score": 1.0, "snippet": text[start:end]})
        if len(hits) >= limit:
            break
    return hits


def normalized_page_text(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def tool_output(hits: list[dict[str, Any]], query: str) -> str:
    if not hits:
        return f'No matches for "{query}" in the document.'
    lines = [f"Found {len(hits)} page{'s' if len(hits) != 1 else ''} with a match:"]
    lines.extend(f'page {hit["page"]} — "…{hit["snippet"]}…"' for hit in hits)
    output = "\n".join(lines)
    return output[:4_000] + ("\n…[truncated]" if len(output) > 4_000 else "")


def score_retrieval(hits: list[dict[str, Any]], relevant_pages: list[int]) -> dict[str, Any]:
    relevant = set(relevant_pages)
    ranks = [index for index, hit in enumerate(hits, 1) if hit.get("page") in relevant]
    found = {hit.get("page") for hit in hits} & relevant
    return {
        "hit": bool(ranks),
        "recall": len(found) / len(relevant) if relevant else None,
        "reciprocal_rank": 1 / min(ranks) if ranks else 0.0,
    }


def score_answer(answer: str, expected: dict[str, Any] | None) -> dict[str, Any] | None:
    if not expected:
        return None
    haystack = normalized(answer)
    required = [normalized(item) for item in expected.get("all", [])]
    alternatives = [normalized(item) for item in expected.get("any", [])]
    def asserted(item: str) -> bool:
        if item not in haystack:
            return False
        return re.search(rf"\b(?:not|isn't|is not|doesn't|does not)\b[^.!?]{{0,32}}{re.escape(item)}", haystack) is None

    required_score = sum(asserted(item) for item in required) / len(required) if required else 1.0
    alternative_score = float(any(asserted(item) for item in alternatives)) if alternatives else 1.0
    return {"exactness": required_score * alternative_score, "required_terms": required_score, "alternative_hit": bool(alternative_score)}


def validate_cases(cases: list[dict[str, Any]], corpus: Corpus) -> list[str]:
    errors: list[str] = []
    ids: set[str] = set()
    for case in cases:
        case_id = case.get("id", "<missing>")
        if case_id in ids:
            errors.append(f"{case_id}: duplicate id")
        ids.add(case_id)
        for key in ("id", "source", "question", "modality"):
            if not case.get(key):
                errors.append(f"{case_id}: missing {key}")
        try:
            pages, url_only = corpus.pages(case.get("source", ""))
            page_numbers = {page.number for page in pages}
            for page in case.get("relevant_pages", []):
                if page not in page_numbers:
                    errors.append(f"{case_id}: relevant page {page} is outside extracted pages")
            query = case.get("retrieval_query") or case.get("question", "")
            hits = grep_retrieve(pages, query)
            if case.get("relevant_pages") and not score_retrieval(hits, case["relevant_pages"])["hit"]:
                errors.append(f"{case_id}: retrieval query does not hit a gold page")
            if url_only:
                errors.append(f"{case_id}: source contains URLs only; snapshot article text before benchmarking")
        except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
            errors.append(f"{case_id}: {error}")
    return errors


def select_cases(cases: list[dict[str, Any]], args: argparse.Namespace) -> list[dict[str, Any]]:
    selected = cases
    if args.case:
        wanted = set(args.case)
        selected = [case for case in selected if case["id"] in wanted]
    if args.tag:
        selected = [case for case in selected if set(args.tag) <= set(case.get("tags", []))]
    if args.modality:
        selected = [case for case in selected if case.get("modality") == args.modality]
    if args.max_cases is not None:
        selected = selected[: args.max_cases]
    return selected


def invoke_agent(command: str, request: dict[str, Any], timeout: float) -> dict[str, Any]:
    process = subprocess.Popen(
        command,
        shell=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(json.dumps(request), timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, 15)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, 9)
            process.wait()
        raise
    if process.returncode:
        raise RuntimeError(f"agent exited {process.returncode}: {stderr.strip()[:500]}")
    try:
        response = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("agent must write exactly one JSON object to stdout") from error
    if not isinstance(response, dict):
        raise RuntimeError("agent response must be a JSON object")
    return response


def run_benchmark(args: argparse.Namespace) -> int:
    cases = select_cases(read_jsonl(args.cases), args)
    if not cases:
        raise SystemExit("no cases selected")
    if args.agent_command and not args.allow_paid:
        raise SystemExit("agent execution is disabled by default; add --allow-paid and --max-cost-usd")
    if args.agent_command and args.max_cost_usd is None:
        raise SystemExit("--max-cost-usd is required for agent runs")
    if args.agent_command and not args.adapter_id:
        raise SystemExit("--adapter-id is required for agent runs")
    if args.max_cost_usd is not None and (not math.isfinite(args.max_cost_usd) or args.max_cost_usd < 0):
        raise SystemExit("--max-cost-usd must be a finite, non-negative number")

    corpus = Corpus(args.corpus, args.cache)
    results: list[dict[str, Any]] = []
    total_cost = 0.0
    started = time.perf_counter()
    for case in cases:
        if args.agent_command and total_cost >= args.max_cost_usd:
            print(f"Cost ceiling reached (${total_cost:.4f}); stopping before the next request.", file=sys.stderr)
            break
        case_started = time.perf_counter()
        pages, url_only = corpus.pages(case["source"])
        if url_only:
            results.append({"case_id": case["id"], "status": "skipped", "reason": "URL manifest has no local article text"})
            continue
        query = case.get("retrieval_query") or case["question"]
        retrieval_started = time.perf_counter()
        hits = grep_retrieve(pages, query)
        retrieval_seconds = time.perf_counter() - retrieval_started
        request: dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "case": {key: value for key, value in case.items() if key not in {"retrieval_query", "relevant_pages", "expected_answer", "expected_min_reads"}},
            "source_path": str(corpus.source(case["source"])),
            "remaining_cost_budget_usd": (args.max_cost_usd - total_cost) if args.max_cost_usd is not None else 0,
        }
        if args.agent_command and case["modality"] == "visual":
            request["image_paths"] = [str(corpus.render_page(case["source"], page)) for page in case.get("visual_pages", case.get("relevant_pages", []))]

        response: dict[str, Any] = {}
        status, error = "ok", None
        if args.agent_command:
            try:
                response = invoke_agent(args.agent_command, request, args.timeout)
            except (RuntimeError, subprocess.TimeoutExpired) as caught:
                status, error = "error", str(caught)
        usage = response.get("usage", {})
        reported_cost = usage.get("cost_usd")
        if reported_cost is not None:
            try:
                numeric_cost = float(reported_cost)
                if not math.isfinite(numeric_cost) or numeric_cost < 0:
                    raise ValueError
                total_cost += numeric_cost
            except (TypeError, ValueError):
                status, error = "error", "usage.cost_usd must be a finite, non-negative number"
        elif args.agent_command:
            status, error = "error", "agent response must report usage.cost_usd (use 0 for free/local models)"

        evaluated_hits = response.get("retrieval_hits", hits)
        result = {
            "case_id": case["id"],
            "source": case["source"],
            "modality": case["modality"],
            "status": status,
            "error": error,
            "latency_seconds": time.perf_counter() - case_started,
            "retrieval_latency_seconds": retrieval_seconds,
            "baseline_retrieval": {"hits": hits, "metrics": score_retrieval(hits, case.get("relevant_pages", []))},
            "retrieval": {"hits": evaluated_hits, "metrics": score_retrieval(evaluated_hits, case.get("relevant_pages", []))},
            "answer": response.get("answer"),
            "answer_metrics": score_answer(response.get("answer", ""), case.get("expected_answer")) if args.agent_command else None,
            "tool_calls": response.get("tool_calls", []),
            "usage": usage,
            "metadata": response.get("metadata", {}),
        }
        results.append(result)
        print(f"{case['id']}: {status} retrieval_hit={result['retrieval']['metrics']['hit']} {result['latency_seconds']:.3f}s")
        if args.agent_command and status == "error":
            print("Agent cost is unknown after an error; stopping to prevent further spend.", file=sys.stderr)
            break
        if args.agent_command and total_cost > args.max_cost_usd:
            print(f"Cost ceiling exceeded (${total_cost:.4f} > ${args.max_cost_usd:.4f}); stopping.", file=sys.stderr)
            break

    latencies = [item["latency_seconds"] for item in results if item.get("status") == "ok"]
    retrieval_metrics = [item["retrieval"]["metrics"] for item in results if item.get("status") == "ok"]
    answer_scores = [item["answer_metrics"]["exactness"] for item in results if item.get("status") == "ok" and item.get("answer_metrics")]
    usages = [item.get("usage", {}) for item in results if item.get("status") == "ok"]
    summary = {
        "cases_requested": len(cases),
        "cases_completed": sum(item.get("status") == "ok" for item in results),
        "retrieval_hit_rate": statistics.fmean(float(item["hit"]) for item in retrieval_metrics) if retrieval_metrics else None,
        "retrieval_mrr": statistics.fmean(item["reciprocal_rank"] for item in retrieval_metrics) if retrieval_metrics else None,
        "answer_exactness": statistics.fmean(answer_scores) if answer_scores else None,
        "latency_p50_seconds": percentile(latencies, 0.5),
        "latency_p95_seconds": percentile(latencies, 0.95),
        "total_cost_usd": total_cost,
        "total_tool_calls": sum(len(item.get("tool_calls", [])) for item in results),
        "total_input_tokens": sum(int(usage.get("input_tokens", 0)) for usage in usages),
        "total_cached_input_tokens": sum(int(usage.get("cached_input_tokens", 0)) for usage in usages),
        "total_output_tokens": sum(int(usage.get("output_tokens", 0)) for usage in usages),
        "wall_seconds": time.perf_counter() - started,
    }
    report = {
        "schema_version": SCHEMA_VERSION,
        "run": {
            "name": args.name,
            "adapter_id": args.adapter_id if args.agent_command else "vellum-grep",
            "agent_command": bool(args.agent_command),
            "agent_command_sha256": hashlib.sha256(args.agent_command.encode()).hexdigest() if args.agent_command else None,
        },
        "manifest": run_manifest(args.cases, [corpus.source(case["source"]) for case in cases]),
        "summary": summary,
        "results": results,
    }
    write_json(args.output, report)
    print(f"Report: {args.output}")
    print(json.dumps(summary, indent=2))
    return 0 if all(item.get("status") in {"ok", "skipped"} for item in results) else 1


def build_user_prompt(case: dict[str, Any], pages: list[Page], image_attached: bool) -> str:
    current_page = int(case.get("current_page", 1))
    page_map = {page.number: normalized_page_text(page.text) for page in pages}
    current_text = page_map.get(current_page, "")[:120_000]
    context = "\n".join([
        f"Document title: {case['source']}",
        f"Total pages: {len(pages)}",
        f"Current page: {current_page}",
        "",
        f"Current page text (page {current_page}):",
        current_text or "(no extractable text on this page — it may be scanned; request a page image, or search other pages)",
        "",
        "Current page annotations:", "(none)", "",
        f"Visible pages: {current_page}",
        f"Current page image: {'attached' if image_attached else 'none'}",
        "", "User-referenced context (the user explicitly attached these to this message — prioritize them):", "(none)",
    ])
    return "\n".join([
        "### Document Context", context, "",
        "### Recent Conversation", "(start of conversation)", "",
        "### Latest User Request", case["question"],
    ])


def run_model_benchmark(args: argparse.Namespace) -> int:
    cases = select_cases(read_jsonl(args.cases), args)
    if not cases:
        raise SystemExit("no cases selected")
    if not math.isfinite(args.cost_stop_usd) or args.cost_stop_usd <= 0:
        raise SystemExit("--cost-stop-usd must be a finite number greater than zero")
    if args.provider != "openrouter" and (args.input_cost_per_million is None or args.output_cost_per_million is None):
        raise SystemExit("OpenAI/Gemini runs require --input-cost-per-million and --output-cost-per-million")
    system_prompt = (ROOT / "Vellum/Resources/prompts/tool-mode-native.md").read_text(encoding="utf-8").strip()
    corpus = Corpus(args.corpus, args.cache)
    results: list[dict[str, Any]] = []
    total_cost = 0.0
    started = time.perf_counter()
    for case in cases:
        if total_cost >= args.cost_stop_usd:
            print(f"Cost stop reached (${total_cost:.4f}); stopping before another case.", file=sys.stderr)
            break
        pages, url_only = corpus.pages(case["source"])
        if url_only:
            results.append({"case_id": case["id"], "status": "skipped", "reason": "URL manifest has no local article text"})
            continue
        case_started = time.perf_counter()
        image_payload = None
        if case["modality"] == "visual":
            image_page = int(case.get("visual_pages", case.get("relevant_pages", [1]))[0])
            image_path = corpus.render_page(case["source"], image_page)
            image_payload = {"media_type": "image/png", "data": base64.b64encode(image_path.read_bytes()).decode()}
        prompt = build_user_prompt(case, pages, image_payload is not None)
        reads = 0

        def execute_tool(name: str, arguments: dict[str, Any]) -> tuple[str, list[dict[str, Any]]]:
            nonlocal reads
            if reads >= 16:
                return "Skipped: document-read limit reached for this response.", []
            reads += 1
            if name == "searchDocument":
                query = str(arguments.get("query") or arguments.get("text") or "").strip()
                if not query:
                    return "Skipped searchDocument: empty query.", []
                try:
                    hits = regex_retrieve(pages, query) if arguments.get("isRegex") else grep_retrieve(pages, query)
                except ValueError as error:
                    return f"Skipped searchDocument: {error}", []
                return tool_output(hits, query), hits
            if name == "getPageText":
                try:
                    requested = int(round(float(arguments.get("pageNumber", 1))))
                except (TypeError, ValueError):
                    requested = 1
                page_number = min(len(pages), max(1, requested))
                text = normalized_page_text(pages[page_number - 1].text)
                if not text:
                    return f"Page {page_number} has no extractable text (it may be a scanned image).", [{"page": page_number, "score": 1.0, "snippet": ""}]
                bounded = text[:20_000] + ("\n…[truncated: this page exceeds the per-read limit]" if len(text) > 20_000 else "")
                return f"Page {page_number}:\n{bounded}", [{"page": page_number, "score": 1.0, "snippet": bounded[:400]}]
            return f"Skipped unknown tool: {name}.", []

        status, error = "ok", None
        try:
            provider_result = run_provider(
                provider=args.provider, model=args.model, system_prompt=system_prompt,
                user_prompt=prompt, image=image_payload, execute_tool=execute_tool,
                timeout=args.timeout, max_rounds=args.max_rounds,
                max_output_tokens=args.max_output_tokens, thinking=args.thinking,
                session_id=case["id"],
            )
            usage = provider_result.usage
            cost = usage.get("cost_usd")
            cost_source = "provider"
            if cost is None:
                cost = (
                    int(usage.get("input_tokens", 0)) * args.input_cost_per_million
                    + int(usage.get("output_tokens", 0)) * args.output_cost_per_million
                ) / 1_000_000
                usage["cost_usd"] = cost
                cost_source = "estimated"
            cost = float(cost)
            if not math.isfinite(cost) or cost < 0:
                raise RuntimeError("provider returned invalid cost")
            total_cost += cost
            answer = provider_result.answer
            tool_calls = provider_result.tool_calls
            retrieval_hits = provider_result.retrieval_hits
            rounds = provider_result.rounds
        except Exception as caught:
            status, error = "error", str(caught)
            usage, answer, tool_calls, retrieval_hits, rounds, cost_source = {}, None, [], [], 0, "unknown"
        metrics = score_retrieval(retrieval_hits, case.get("relevant_pages", []))
        expected_reads = int(case.get("expected_min_reads", 0))
        result = {
            "case_id": case["id"], "source": case["source"], "modality": case["modality"],
            "status": status, "error": error, "latency_seconds": time.perf_counter() - case_started,
            "answer": answer, "answer_metrics": score_answer(answer or "", case.get("expected_answer")) if status == "ok" else None,
            "retrieval": {"hits": retrieval_hits, "metrics": metrics},
            "tool_calls": tool_calls, "tool_metrics": {"read_calls": len(tool_calls), "met_expected_minimum": len(tool_calls) >= expected_reads},
            "usage": usage, "cost_source": cost_source, "rounds": rounds,
        }
        results.append(result)
        print(f"{case['id']}: {status} answer={result['answer_metrics']['exactness'] if result['answer_metrics'] else '-'} retrieval_hit={metrics['hit']} tools={len(tool_calls)}")
        if status == "error":
            print("Stopping after provider error because request cost may be unknown.", file=sys.stderr)
            break
    completed = [item for item in results if item.get("status") == "ok"]
    summary = {
        "cases_requested": len(cases), "cases_completed": len(completed),
        "answer_exactness": statistics.fmean(item["answer_metrics"]["exactness"] for item in completed) if completed else None,
        "retrieval_hit_rate": statistics.fmean(float(item["retrieval"]["metrics"]["hit"]) for item in completed) if completed else None,
        "tool_selection_rate": statistics.fmean(float(item["tool_metrics"]["met_expected_minimum"]) for item in completed) if completed else None,
        "latency_p50_seconds": percentile([item["latency_seconds"] for item in completed], .5),
        "latency_p95_seconds": percentile([item["latency_seconds"] for item in completed], .95),
        "total_tool_calls": sum(len(item["tool_calls"]) for item in completed),
        "total_input_tokens": sum(int(item["usage"].get("input_tokens", 0)) for item in completed),
        "total_cached_input_tokens": sum(int(item["usage"].get("cached_input_tokens", 0)) for item in completed),
        "total_cache_write_tokens": sum(int(item["usage"].get("cache_write_tokens", 0)) for item in completed),
        "total_output_tokens": sum(int(item["usage"].get("output_tokens", 0)) for item in completed),
        "total_cost_usd": total_cost, "wall_seconds": time.perf_counter() - started,
    }
    report = {
        "schema_version": SCHEMA_VERSION,
        "run": {"name": args.name, "provider": args.provider, "model": args.model, "thinking": args.thinking, "max_rounds": args.max_rounds, "max_output_tokens": args.max_output_tokens},
        "manifest": run_manifest(args.cases, [corpus.source(case["source"]) for case in cases]),
        "summary": summary, "results": results,
    }
    write_json(args.output, report)
    print(f"Report: {args.output}\n{json.dumps(summary, indent=2)}")
    return 0 if len(completed) == len([item for item in results if item.get("status") != "skipped"]) else 1


def compare_reports(paths: list[Path]) -> int:
    print("run\tcases\thit_rate\tMRR\tanswer\tp50_s\tcost_usd")
    for path in paths:
        report = json.loads(path.read_text(encoding="utf-8"))
        summary = report["summary"]
        values = [
            report.get("run", {}).get("name") or path.stem,
            summary.get("cases_completed"),
            summary.get("retrieval_hit_rate"),
            summary.get("retrieval_mrr"),
            summary.get("answer_exactness"),
            summary.get("latency_p50_seconds"),
            summary.get("total_cost_usd"),
        ]
        print("\t".join("-" if value is None else f"{value:.4f}" if isinstance(value, float) else str(value) for value in values))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    common.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    common.add_argument("--cache", type=Path, default=DEFAULT_CACHE)

    doctor = subparsers.add_parser("doctor", parents=[common], help="validate dependencies, corpus, and case schema")
    doctor.set_defaults(handler=doctor_command)

    run = subparsers.add_parser("run", parents=[common], help="run the free grep baseline or an agent adapter")
    run.add_argument("--name", default="grep-baseline")
    run.add_argument("--output", type=Path, default=Path("benchmark-results/grep-baseline.json"))
    run.add_argument("--case", action="append", help="case id; repeat to select several")
    run.add_argument("--tag", action="append", help="required tag; repeat to intersect")
    run.add_argument("--modality", choices=["text", "visual", "audio"])
    run.add_argument("--max-cases", type=int, default=None)
    run.add_argument("--agent-command", help="command reading one request JSON from stdin and writing one result JSON")
    run.add_argument("--adapter-id", help="stable retriever/provider/model/config identity for reports")
    run.add_argument("--allow-paid", action="store_true", help="explicit opt-in required for all agent commands")
    run.add_argument("--max-cost-usd", type=float, help="stop after cumulative provider-reported cost exceeds this ceiling")
    run.add_argument("--timeout", type=float, default=120)
    run.set_defaults(handler=run_benchmark)

    model = subparsers.add_parser("model", parents=[common], help="benchmark a real AI provider/model with Vellum's read-tool loop")
    model.add_argument("--provider", required=True, choices=["openai", "openrouter", "gemini"])
    model.add_argument("--model", required=True)
    model.add_argument("--name", default="model-run")
    model.add_argument("--output", type=Path, default=Path("benchmark-results/model-run.json"))
    model.add_argument("--case", action="append")
    model.add_argument("--tag", action="append")
    model.add_argument("--modality", choices=["text", "visual", "audio"])
    model.add_argument("--max-cases", type=int, default=None)
    model.add_argument("--thinking", choices=["minimal", "low", "medium", "high"], default="low")
    model.add_argument("--max-rounds", type=int, default=4)
    model.add_argument("--max-output-tokens", type=int, default=1200)
    model.add_argument("--cost-stop-usd", required=True, type=float, help="soft stop checked between cases; one case can exceed it")
    model.add_argument("--input-cost-per-million", type=float, help="required for providers that do not report USD cost")
    model.add_argument("--output-cost-per-million", type=float, help="required for providers that do not report USD cost")
    model.add_argument("--timeout", type=float, default=120)
    model.set_defaults(handler=run_model_benchmark)

    compare = subparsers.add_parser("compare", help="print a compact comparison table")
    compare.add_argument("reports", nargs="+", type=Path)
    compare.set_defaults(handler=lambda args: compare_reports(args.reports))
    return parser


def doctor_command(args: argparse.Namespace) -> int:
    cases = read_jsonl(args.cases)
    corpus = Corpus(args.corpus, args.cache)
    errors = validate_cases(cases, corpus)
    print(f"Python: {sys.version.split()[0]}")
    print(f"pdftotext: {shutil.which('pdftotext') or 'MISSING'}")
    print(f"pdftoppm: {shutil.which('pdftoppm') or 'MISSING'}")
    print(f"swiftc/PDFKit parity extractor: {shutil.which('swiftc') or 'MISSING (pdftotext fallback)'}")
    print(f"Cases: {len(cases)}")
    print(f"Corpus files: {len([path for path in args.corpus.iterdir() if path.is_file()])}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Benchmark inputs are valid.")
    return 0


if __name__ == "__main__":
    parsed = build_parser().parse_args()
    raise SystemExit(parsed.handler(parsed))
