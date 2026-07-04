The codex-cli computer-use is much better, since we are building a desktop application I want you to use codex-cli to verify your work. Make sure that whatever changes you've made or asked your sub-agents to make are giving the correct behaviour.   
Additionally instead absolutely required prefer spinning up Sonnet, Opus or Codex models. I would like it if you do not spin up a bunch of Fable models since they use up a bunch of tokens. 

## Picking the right models for workflows and subagents

Rankings, higher = better. Cost reflects what I actually pay (OpenAI has really generous limits although I am using the 20 dollar plan so do not use it unless necessary), not list price. Intelligence is how hard a problem you can hand the model unsupervised. Taste covers UI/UX, code quality, API design, and copy.
How to apply:
- These are defaults, not limits. You have standing permission to override them: if a cheaper model's output doesn't meet the bar, rerun or redo the work with a smarter model without asking. Judge the output, not the price tag. Escalating costs less than shipping mediocre work.
- Cost is a tie-breaker only; when axes conflict for anything that ships, intelligence > taste > cost.
- Bulk/mechanical work (clear-spec implementation, data analysis, migrations): gpt-5.5 - it's effectively free.
- Anything user-facing (UI, copy, API design) needs taste ≥ 7.
- Reviews of plans/implementations: fable-5 or opus-4.8, optionally gpt-5.5 as an extra independent perspective.
- Never use Haiku.
- Mechanics: gpt-5.5 is only reachable through the Codex CLI - 'codex exec' / 'codex review' (my ~/.codex/config.toml defaults to gpt-5.5). Use the codex-implementation, codex-review, and codex-computer-use skills; for work they don't cover (investigation, data analysis), run 'codex exec -s read-only' directly with a self-contained prompt.
- Codex models (sonnet-5, opus-4.8, fable-5) run via the Agent/Workflow model parameter.
Using gpt-5.5 inside workflows and subagents (the model parameter only takes Codex models, so use a wrapper):
- Spawn a thin Codex wrapper agent with 'model: 'sonnet', effort: 'low' whose prompt instructs it to write a self-contained codex prompt, run 'codex exec' via Bash, and return
