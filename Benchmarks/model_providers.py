"""Built-in provider clients for the Vellum AI benchmark (stdlib only)."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable


READ_TOOLS = [
    {
        "name": "searchDocument",
        "description": "Search the FULL document text for a query and get back the pages that match, each with surrounding context. Use this to find where something is discussed before reading a page. Default is a case-insensitive literal substring match; set isRegex true to match a regular expression.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Text or regular expression to search for across every page."},
                "isRegex": {"type": "boolean", "description": "Treat query as a regular expression. Defaults to false."},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
    {
        "name": "getPageText",
        "description": "Read the full extracted text of a single page by its 1-indexed number. Use it after searchDocument, or when the user names a specific page.",
        "parameters": {
            "type": "object",
            "properties": {"pageNumber": {"type": "number", "description": "1-indexed page number to read."}},
            "required": ["pageNumber"],
            "additionalProperties": False,
        },
    },
]


@dataclass
class ProviderResult:
    answer: str
    usage: dict[str, Any]
    tool_calls: list[dict[str, Any]]
    retrieval_hits: list[dict[str, Any]]
    rounds: int


def _post(url: str, headers: dict[str, str], body: dict[str, Any], timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        payload = error.read().decode(errors="replace")[:1000]
        raise RuntimeError(f"provider HTTP {error.code}: {payload}") from error


def _add_usage(total: dict[str, Any], usage: dict[str, Any]) -> None:
    for key in ("input_tokens", "cached_input_tokens", "cache_write_tokens", "reasoning_tokens", "output_tokens"):
        total[key] = total.get(key, 0) + int(usage.get(key, 0) or 0)
    if usage.get("cost_usd") is not None:
        total["cost_usd"] = total.get("cost_usd", 0.0) + float(usage["cost_usd"])


def _openai_usage(raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "input_tokens": raw.get("input_tokens", 0),
        "cached_input_tokens": raw.get("input_tokens_details", {}).get("cached_tokens", 0),
        "reasoning_tokens": raw.get("output_tokens_details", {}).get("reasoning_tokens", 0),
        "output_tokens": raw.get("output_tokens", 0),
    }


def _chat_usage(raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "input_tokens": raw.get("prompt_tokens", 0),
        "cached_input_tokens": raw.get("prompt_tokens_details", {}).get("cached_tokens", 0),
        "cache_write_tokens": raw.get("prompt_tokens_details", {}).get("cache_write_tokens", 0) or raw.get("cache_creation_input_tokens", 0),
        "reasoning_tokens": raw.get("completion_tokens_details", {}).get("reasoning_tokens", 0),
        "output_tokens": raw.get("completion_tokens", 0),
        "cost_usd": raw.get("cost"),
    }


def _gemini_usage(raw: dict[str, Any]) -> dict[str, Any]:
    return {
        "input_tokens": raw.get("promptTokenCount", 0),
        "cached_input_tokens": raw.get("cachedContentTokenCount", 0),
        "reasoning_tokens": raw.get("thoughtsTokenCount", 0),
        "output_tokens": raw.get("candidatesTokenCount", 0),
    }


def run_provider(
    *,
    provider: str,
    model: str,
    system_prompt: str,
    user_prompt: str,
    image: dict[str, str] | None,
    execute_tool: Callable[[str, dict[str, Any]], tuple[str, list[dict[str, Any]]]],
    timeout: float,
    max_rounds: int,
    max_output_tokens: int,
    thinking: str,
    session_id: str,
) -> ProviderResult:
    if provider == "openai":
        return _run_openai(model, system_prompt, user_prompt, image, execute_tool, timeout, max_rounds, max_output_tokens, thinking, session_id)
    if provider == "openrouter":
        return _run_openrouter(model, system_prompt, user_prompt, image, execute_tool, timeout, max_rounds, max_output_tokens, thinking, session_id)
    if provider == "gemini":
        return _run_gemini(model, system_prompt, user_prompt, image, execute_tool, timeout, max_rounds, max_output_tokens, thinking)
    raise ValueError(f"unsupported provider: {provider}")


def _run_openai(model, system, prompt, image, execute_tool, timeout, max_rounds, max_output, thinking, session_id):
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise RuntimeError("OPENAI_API_KEY is not set")
    content: list[dict[str, Any]] = [{"type": "input_text", "text": prompt}]
    if image:
        content.append({"type": "input_image", "image_url": f"data:{image['media_type']};base64,{image['data']}"})
    inputs: list[dict[str, Any]] = [{"role": "user", "content": content}]
    usage: dict[str, Any] = {}
    records, retrieval, answer = [], [], ""
    for round_number in range(1, max_rounds + 1):
        body: dict[str, Any] = {
            "model": model, "instructions": system, "input": inputs,
            "tools": [{"type": "function", **tool} for tool in READ_TOOLS],
            "store": False, "max_output_tokens": max_output,
            "prompt_cache_key": f"vellum-benchmark-{session_id}",
        }
        if model.lower().startswith("gpt-5"):
            body["reasoning"] = {"effort": thinking}
        response = _post("https://api.openai.com/v1/responses", {"Authorization": f"Bearer {key}"}, body, timeout)
        _add_usage(usage, _openai_usage(response.get("usage", {})))
        calls = [item for item in response.get("output", []) if item.get("type") == "function_call"]
        texts = [part.get("text", "") for item in response.get("output", []) if item.get("type") == "message" for part in item.get("content", []) if part.get("type") == "output_text"]
        answer = "".join(texts).strip()
        if not calls:
            return ProviderResult(answer or "I couldn't produce a response.", usage, records, retrieval, round_number)
        for call in calls:
            arguments = json.loads(call.get("arguments") or "{}")
            output, hits = execute_tool(call.get("name", ""), arguments)
            records.append({"round": round_number, "name": call.get("name"), "arguments": arguments, "output_characters": len(output)})
            retrieval.extend(hits)
            inputs.extend([call, {"type": "function_call_output", "call_id": call.get("call_id"), "output": output}])
    raise RuntimeError(f"tool loop exhausted after {max_rounds} rounds")


def _run_openrouter(model, system, prompt, image, execute_tool, timeout, max_rounds, max_output, thinking, session_id):
    key = os.environ.get("OPENROUTER_API_KEY")
    if not key:
        raise RuntimeError("OPENROUTER_API_KEY is not set")
    stable, marker, volatile = prompt.partition("\n### Recent Conversation")
    volatile = ("### Recent Conversation" + volatile) if marker else ""
    user_content: Any = [
            {"type": "text", "text": stable, "cache_control": {"type": "ephemeral"}},
    ]
    if image:
        user_content.extend([
            {"type": "image_url", "image_url": {"url": f"data:{image['media_type']};base64,{image['data']}"}},
        ])
    if volatile:
        user_content.append({"type": "text", "text": volatile})
    messages: list[dict[str, Any]] = [{"role": "system", "content": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}]}, {"role": "user", "content": user_content}]
    usage: dict[str, Any] = {}
    records, retrieval, answer = [], [], ""
    tools = [{"type": "function", "function": tool} for tool in READ_TOOLS]
    for round_number in range(1, max_rounds + 1):
        body = {"model": model, "messages": messages, "tools": tools, "max_tokens": max_output, "usage": {"include": True}, "session_id": f"vellum-benchmark-{session_id}"}
        if thinking != "minimal":
            body["reasoning"] = {"effort": thinking}
        response = _post("https://openrouter.ai/api/v1/chat/completions", {"Authorization": f"Bearer {key}"}, body, timeout)
        _add_usage(usage, _chat_usage(response.get("usage", {})))
        message = response.get("choices", [{}])[0].get("message", {})
        answer = message.get("content") or ""
        calls = message.get("tool_calls") or []
        if not calls:
            return ProviderResult(answer.strip() or "I couldn't produce a response.", usage, records, retrieval, round_number)
        messages.append(message)
        for call in calls:
            function = call.get("function", {})
            arguments = json.loads(function.get("arguments") or "{}")
            output, hits = execute_tool(function.get("name", ""), arguments)
            records.append({"round": round_number, "name": function.get("name"), "arguments": arguments, "output_characters": len(output)})
            retrieval.extend(hits)
            messages.append({"role": "tool", "tool_call_id": call.get("id"), "content": output})
    raise RuntimeError(f"tool loop exhausted after {max_rounds} rounds")


def _run_gemini(model, system, prompt, image, execute_tool, timeout, max_rounds, max_output, thinking):
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("GEMINI_API_KEY is not set")
    parts: list[dict[str, Any]] = [{"text": prompt}]
    if image:
        parts.append({"inlineData": {"mimeType": image["media_type"], "data": image["data"]}})
    contents: list[dict[str, Any]] = [{"role": "user", "parts": parts}]
    usage: dict[str, Any] = {}
    records, retrieval, answer = [], [], ""
    endpoint = f"https://generativelanguage.googleapis.com/v1beta/models/{urllib.parse.quote(model, safe='')}:generateContent?key={urllib.parse.quote(key)}"
    for round_number in range(1, max_rounds + 1):
        config: dict[str, Any] = {"maxOutputTokens": max_output}
        if "gemini-3" in model.lower():
            config["thinkingConfig"] = {"thinkingLevel": thinking if thinking in {"low", "medium", "high"} else "minimal"}
        body = {
            "systemInstruction": {"parts": [{"text": system}]},
            "contents": contents,
            "tools": [{"functionDeclarations": [{k: v for k, v in tool.items() if k != "parameters"} | {"parameters": {k: v for k, v in tool["parameters"].items() if k != "additionalProperties"}} for tool in READ_TOOLS]}],
            "generationConfig": config,
        }
        response = _post(endpoint, {}, body, timeout)
        _add_usage(usage, _gemini_usage(response.get("usageMetadata", {})))
        model_parts = response.get("candidates", [{}])[0].get("content", {}).get("parts", [])
        calls = [part["functionCall"] for part in model_parts if "functionCall" in part]
        answer = "".join(part.get("text", "") for part in model_parts if not part.get("thought")).strip()
        if not calls:
            return ProviderResult(answer or "I couldn't produce a response.", usage, records, retrieval, round_number)
        contents.append({"role": "model", "parts": model_parts})
        response_parts = []
        for call in calls:
            arguments = call.get("args", {})
            output, hits = execute_tool(call.get("name", ""), arguments)
            records.append({"round": round_number, "name": call.get("name"), "arguments": arguments, "output_characters": len(output)})
            retrieval.extend(hits)
            function_response = {"name": call.get("name"), "response": {"result": output}}
            if call.get("id") is not None:
                function_response["id"] = call["id"]
            response_parts.append({"functionResponse": function_response})
        contents.append({"role": "user", "parts": response_parts})
    raise RuntimeError(f"tool loop exhausted after {max_rounds} rounds")
