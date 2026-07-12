# Vellum AI benchmark

This is a reproducible terminal benchmark for comparing AI models running through Vellum's document prompt and `searchDocument`/`getPageText` tool loop. Questions are curated with hidden gold pages and answer claims. It also retains a free retrieval-only diagnostic for checking the corpus and gold labels.

## Quick start

```bash
python3 Benchmarks/vellum_bench.py doctor
python3 Benchmarks/vellum_bench.py model --provider openrouter --model YOUR_MODEL --tag smoke --cost-stop-usd 0.25
python3 -m unittest Benchmarks/test_vellum_bench.py
```

`doctor` extracts each PDF with PDFKit—the same `PDFPage.string` path used by Vellum—into a fingerprinted `.benchmark-cache/` entry and validates every gold page. On non-macOS systems it falls back to Poppler. The baseline mirrors `AiToolEngine.searchDocument`: case-insensitive literal matching, first match per page, eight hits, 200 characters of surrounding context, and a 100,000-character page scan cap.

Provider credentials are read from `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, or `GEMINI_API_KEY`. They are never stored in reports. OpenRouter supplies provider-reported cost. OpenAI and Gemini require explicit current pricing so the report can estimate cost:

```bash
python3 Benchmarks/vellum_bench.py model \
  --provider openai --model YOUR_MODEL --tag smoke \
  --input-cost-per-million INPUT_PRICE \
  --output-cost-per-million OUTPUT_PRICE \
  --cost-stop-usd 0.25
```

Each report records per-case and aggregate latency, retrieval hit rate/MRR, answer-claim accuracy, whether the model selected the required tools, ordered tool calls, model rounds, tokens, cache usage, and cost. Compare runs with:

```bash
python3 Benchmarks/vellum_bench.py compare benchmark-results/grep.json benchmark-results/rag.json
```

## Cost-effective run ladder

1. Run `doctor`, then the free `run` diagnostic to validate corpus/gold retrieval.
2. Use `model --tag smoke --max-cases 2` for the first paid provider check. `--cost-stop-usd` is checked between cases; per-request spend is bounded separately by output tokens and tool rounds.
3. Run one cheap model once, inspect failures, then use the full suite only for release comparisons.
4. Repeat cases 3-5 times only when measuring variance or latency; deterministic retrieval needs one pass.
5. Render only `visual_pages`. Never upload every page of a book.

The built-in `model` command supports OpenAI, OpenRouter, and Gemini. The lower-level adapter interface remains available for future Vellum-native, RAG, voice, or local-model runners and will never execute without both `--allow-paid` and a dollar ceiling:

```bash
python3 Benchmarks/vellum_bench.py run \
  --name my-model \
  --tag smoke \
  --agent-command './path/to/adapter' \
  --adapter-id 'rag-v1/openrouter/model-name' \
  --allow-paid \
  --max-cost-usd 0.25 \
  --output benchmark-results/my-model.json
```

An adapter reads one JSON request from stdin and writes exactly one JSON object to stdout:

```json
{
  "answer": "...",
  "tool_calls": [{"name": "searchDocument", "arguments": {"text": "..."}, "latency_seconds": 0.02}],
  "retrieval_hits": [{"page": 1, "score": 0.91, "snippet": "..."}],
  "usage": {"input_tokens": 1234, "cached_input_tokens": 800, "output_tokens": 90, "cost_usd": 0.0012},
  "metadata": {"provider": "openrouter", "model": "...", "retriever": "vellum-grep"}
}
```

The request contains the complete case, absolute source path, baseline retrieval hits, remaining dollar budget, and `image_paths` for visual cases. The adapter must reject a request it cannot finish inside `remaining_cost_budget_usd`; an error or timeout stops the suite immediately because its cost is unknown. The harness validates reported cost and never starts another request once the ceiling is reached, but the adapter/provider remains responsible for honoring the per-request remaining budget. A Vellum CLI bridge can therefore report the app's real `AiUsage` and tool receipts; a RAG adapter can return `retrieval_hits` from its own index without changing the dataset.

## Dataset rules

Cases live in `cases.jsonl`. Each contains a stable ID, source, modality, model-visible question, deliberately selected current page, evaluator-only retrieval query, gold physical PDF pages, minimum expected reads, answer claims, and tags. The evaluator-only query is never sent to the model. Page numbers are PDF page indices, matching PDFKit and Vellum—not printed book labels.

The included `webpages.txt` currently contains four URLs rather than article text. It is deliberately excluded: benchmark inputs must be immutable local snapshots, otherwise site edits and network failures destroy reproducibility. Add saved HTML/text snapshots with source URL and capture date before adding blog cases.

For serious answer-quality comparisons, keep the cheap term scorer as a regression signal but add blind human ratings (correctness, citation support, completeness, and diagram understanding). LLM-as-judge should be optional because it adds cost and model bias.

## Extending the benchmark

- RAG: implement an adapter that indexes the same files, returns answer/tool/usage JSON, and includes retrieved page IDs in `metadata`.
- Models/providers: keep the case set and adapter version fixed; change only model/provider metadata.
- Voice: add immutable audio fixtures plus transcript/semantic gold fields; report transcription latency, time-to-first-audio, completion latency, WER, interruptions, and audio cost.
- Visuals: add diagram/table/chart cases with explicit `visual_pages`, text-only and image-enabled runs, and human-scored claims grounded in the figure.
- Tool behavior: report ordered calls and arguments so the run can measure unnecessary calls, page-read count, failed calls, and whether cited evidence was actually retrieved.
