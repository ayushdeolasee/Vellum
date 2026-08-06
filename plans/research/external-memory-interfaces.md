# What external AI tools accept as a memory or profile interface

Research for [Vellum#173](https://github.com/ayushdeolasee/Vellum/issues/173), part of the knowledge-base map ([Vellum#170](https://github.com/ayushdeolasee/Vellum/issues/170)).

The vault's primary job is that *other* tools consume it. This documents what the receiving end actually wants. The choice itself is [Vellum#177](https://github.com/ayushdeolasee/Vellum/issues/177).

## Hermes — identified, high confidence

**Hermes Agent, by Nous Research.** Open-source, MIT, released February 2026. Self-hosted; "an agent that lives on your machine and gets smarter every day." Source at [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), docs at [hermes-agent.nousresearch.com/docs](https://hermes-agent.nousresearch.com/docs/).

Confidence is high rather than certain. There are unrelated things called Hermes — Nous Research's *Hermes model family*, Meta's *Hermes* JavaScript engine — but only this one is a personal AI agent with a memory system you would "connect to… to give a better picture of themselves." The description matches the ask exactly.

### Hermes memory is markdown files on disk

From [the official memory documentation](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/memory.md):

Two files in `~/.hermes/memories/`:

| File | Purpose | Limit |
|---|---|---|
| `MEMORY.md` | "Agent's personal notes — environment facts, conventions, things learned" | **2,200 chars** (~800 tokens) |
| `USER.md` | "User profile — your preferences, communication style, expectations" | **1,375 chars** (~500 tokens) |

Entries within a file are separated by a `§` (section sign) delimiter. Multiline entries are supported. The rendered form injected into the system prompt looks like:

```
MEMORY (your personal notes) [67% — 1,474/2,200 chars]
User's project is a Rust web service at ~/code/myapi using Axum + SQLx
§
This machine runs Ubuntu 22.04, has Docker and Podman installed
```

Loading is a **frozen snapshot**: "The system prompt injection is captured once at session start and never changes mid-session." Writes during a session "are persisted to disk immediately but won't appear in the system prompt until the next session starts."

The agent's own `memory` tool has three actions — `add`, `replace`, `remove` — and notably **no `read`**, "because memory content is automatically injected into the system prompt at session start."

### The consequence Vellum has to design around

**`USER.md` holds 1,375 characters.** That is roughly a long paragraph.

A reading knowledge base accumulated over months cannot be piped into Hermes. Whatever Vellum exposes to it must be an aggressively compressed digest — a few hundred characters of "who this person is as a reader" — not the vault. Any design that assumes the consumer will ingest and retrieve over the whole corpus is wrong for this consumer.

This also means the vault and the export are **different artifacts**. The vault can be as large as it likes; the Hermes-facing projection is budgeted in characters.

### No documented external write path

The memory docs describe no supported mechanism for an external program to write into Hermes' memory. In practice the files are plain markdown on disk in a known location, so writing them directly is possible — but it is unsanctioned, races with Hermes' own writes, and must respect the `§` delimiter and the character cap.

There was a feature request, [hermes-agent#10835](https://github.com/NousResearch/hermes-agent/issues/10835), to expose memory over MCP. It records that `hermes mcp serve` "exposes 10 conversation/messaging tools but zero memory tools," and proposes a CRUD interface over `MEMORY.md`/`USER.md` with "proper `§`-delimited section handling and char limit enforcement," atomic writes, file locking and injection scanning. **The issue is closed** (opened 2026-04-16, priority P3); a preliminary PR #10833 is referenced but the closure reason is not visible in the issue body. Treat MCP-based memory writing to Hermes as **not currently available**.

Hermes does ship external memory provider plugins (Honcho, Mem0, Supermemory and others per the [community directory](https://github.com/0xNyk/awesome-hermes-agent)). That is a second possible integration surface — becoming a memory provider rather than writing the files — and was not investigated.

## MCP as the delivery mechanism

From the [MCP specification, 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/architecture): a client-host-server architecture over JSON-RPC. A host runs multiple clients; each client holds one stateful session with one server. Servers "expose resources, tools and prompts via MCP primitives" and "can be local processes or remote services."

Design principles worth noting for a personal knowledge base: servers "should not be able to read the whole conversation, nor 'see into' other servers," and the host "enforces security policies and consent requirements."

### Transports

Two are defined ([transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)); "Clients **SHOULD** support stdio whenever possible."

**stdio** — "The client launches the MCP server as a subprocess." The server reads JSON-RPC from stdin, writes to stdout, and "**MUST NOT** write anything to its `stdout` that is not a valid MCP message."

This is the decisive detail for Vellum. Under stdio the *client* launches the server as a subprocess. That means the MCP server would be a **separate executable**, not the Vellum app — which neatly dissolves the "only works while Vellum is running" problem, but introduces a new one: a helper binary that reads the vault, shipped and updated alongside a sandboxed Mac app.

**Streamable HTTP** — the server is "an independent process that can handle multiple client connections," on a single endpoint supporting POST and GET, optionally with SSE. Security requirements are normative:

> 1. Servers **MUST** validate the `Origin` header on all incoming connections to prevent DNS rebinding attacks
> 2. When running locally, servers **SHOULD** bind only to localhost (127.0.0.1) rather than all network interfaces (0.0.0.0)
> 3. Servers **SHOULD** implement proper authentication for all connections

> "Without these protections, attackers could use DNS rebinding to interact with local MCP servers from remote websites."

This is the option where Vellum itself hosts the server in-process — and it is the one that only works while Vellum is open, and that carries a real local-network attack surface exposing a profile of the user.

**Not established:** whether a sandboxed, App Store-distributed macOS app may host a listening socket or ship a launchable helper binary for stdio. Vellum already runs `OAuthLoopbackServer`, which is evidence that localhost listening is at least possible in the current configuration, but that is a transient loopback for an OAuth redirect, not a persistent service. This needs verification against App Review guidelines before the interface decision is finalised.

### Primitive choice

Resources, tools and prompts differ in who initiates. A knowledge base maps naturally to **resources** (client/host decides what to pull in) rather than tools (model decides to call). Not investigated in depth; relevant to the interface design if MCP is chosen.

## Plain files as the interface

The strongest argument for files is now empirical rather than aesthetic: **the named consumer's memory is already markdown files on disk.** Hermes reads `~/.hermes/memories/*.md`. Claude Code and other agents read `CLAUDE.md` / `AGENTS.md` from the working directory. Hermes' own repo carries an [`AGENTS.md`](https://github.com/NousResearch/hermes-agent/blob/main/AGENTS.md).

Files require no protocol, no running process, no authentication, no sandbox negotiation, and work when Vellum is closed. They are also directly inspectable and editable by the user, which the vault design already demands for its own reasons.

### Obsidian frontmatter as the metadata convention

If entries carry structured metadata, Obsidian's Properties format is the widest-adopted markdown convention ([Obsidian Properties](https://obsidian.md/help/properties)): a YAML block delimited by `---` at the very top of the file, property names separated from values by a colon and a space, each name unique within a note.

Six types: Text, List, Number, Checkbox, Date (`YYYY-MM-DD`), Date & time (`YYYY-MM-DDTHH:MM:SS`). Three reserved names: `tags`, `cssclasses`, `aliases`.

One trap worth recording: "Internal links in text properties must be surrounded with quotes." A `[[wikilink]]` written bare into frontmatter is invalid YAML.

Conforming to this buys Obsidian compatibility for free and costs nothing, since YAML frontmatter is what any parser would reach for anyway.

## Emerging standards for portable personal context

`agentskills.io` surfaced as an open standard Hermes' *skills* conform to, per secondary sources. **Not verified against a primary source** and it concerns reusable skill documents rather than personal profile data, so it is probably not the right shape. Recorded as a lead, not a finding.

No mature cross-vendor standard for portable personal context was identified. The de facto convention is markdown files in a known location.

## What this leaves for the decision

1. The named consumer already reads markdown files. Files-as-interface is not the low-ambition option here; it is the one that actually works with Hermes today.
2. MCP memory access to Hermes specifically is **not currently available** — the request for it is closed.
3. Whatever the interface, a **character-budgeted digest** is required alongside the full vault. 1,375 characters is the design constraint, and it is small enough to change what the vault stores, not just how it is exported.
4. If MCP is pursued, stdio implies a separate helper executable and HTTP implies Vellum must be running plus a real security burden. Sandbox viability is unverified either way.
