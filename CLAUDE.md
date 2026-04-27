# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is **CrewAI** — a standalone Python framework for orchestrating role-playing autonomous AI agents. It is built from scratch (no LangChain dependency) and exposes two complementary paradigms:

- **Crews** (`src/crewai/crew.py`): teams of autonomous `Agent`s collaborating on `Task`s under a `Process` (`sequential` or `hierarchical`).
- **Flows** (`src/crewai/flow/flow.py`): event-driven workflows built from methods decorated with `@start`, `@listen`, `@router`, combined with `or_`/`and_`. Flows can host Crews as steps.

The published package is `crewai` (PyPI). The CLI entry point `crewai = "crewai.cli.cli:crewai"` (defined in `pyproject.toml`) scaffolds and runs end-user crew/flow projects via templates in `src/crewai/cli/templates/`.

## Development Commands

This project uses **UV** for dependency management. All commands assume you are at the repo root.

```bash
# Setup
uv sync --dev --all-extras       # install everything (matches CI)
uv venv                          # create a virtualenv if needed
pre-commit install               # install ruff hook from .pre-commit-config.yaml

# Tests (network is blocked in CI; VCR cassettes live in tests/cassettes/)
uv run pytest .                                 # full suite
uv run pytest tests/test_crew.py                # one file
uv run pytest tests/test_crew.py::test_name     # one test
uv run pytest -k "keyword"                      # filter by name
uv run pytest -m telemetry                      # only telemetry-marked tests (telemetry NOT mocked)
uv run pytest --block-network --timeout=30 -n auto   # mimic CI exactly

# Lint / format / types
uvx ruff check .                 # lint (config: .ruff.toml — excludes templates/, __init__.py)
uvx ruff format .                # format
uvx mypy src                     # type-check (config in pyproject.toml; excludes cli/templates)

# Build
uv build                         # produces wheel + sdist (excludes docs/ per pyproject.toml)
```

CI (`.github/workflows/`) runs tests across Python 3.10–3.13 split into 8 groups via `pytest-split` (`--splits 8 --group N`). The `linter.yml` workflow only lints **changed** `.py` files (excluding `src/crewai/cli/templates/`); `type-checker.yml` runs `mypy src` on Python 3.11.9.

## Test Conventions

`tests/conftest.py` is critical to understand before writing tests:

- An autouse fixture sets `CREWAI_STORAGE_DIR` to a temp dir and `CREWAI_TESTING=true` for every test, so memory/SQLite storage is isolated per test.
- Telemetry is **auto-mocked** for every test by default. To exercise real telemetry behavior, mark a test `@pytest.mark.telemetry` or place it under a path containing `telemetry/` — the fixture detects both and skips mocking.
- `vcr_config` records to `tests/cassettes/` with `record_mode="new_episodes"` and scrubs `authorization` headers. CI uses `--block-network`, so any new LLM-touching test must commit a cassette.
- The CI test job uses `pytest-xdist` (`-n auto`), `pytest-randomly`, `pytest-timeout` (30s), and `--maxfail=3`; flaky/order-dependent tests will surface here.

## Architecture

### Top-level package surface (`src/crewai/__init__.py`)
Public API: `Agent`, `Crew`, `CrewOutput`, `Process`, `Task`, `LLM`, `BaseLLM`, `Flow`, `Knowledge`, `TaskOutput`, `LLMGuardrail`. Version is read from `src/crewai/__init__.py` (`[tool.hatch.version]`).

### Core domain modules
- **`agent.py`** — concrete `Agent` extending `agents/agent_builder/base_agent.py`. Execution is delegated to `agents/crew_agent_executor.py`; tool dispatch lives in `agents/tools_handler.py` and `tools/tool_usage.py`. Alternative adapters in `agents/agent_adapters/` (LangGraph, OpenAI Agents) let external agent runtimes plug in via `BaseAgentAdapter`.
- **`crew.py`** — orchestrates agents+tasks. Honors `Process.sequential` vs `Process.hierarchical` (manager auto-assigned). Wires up memory, knowledge, callbacks (`@before_kickoff`/`@after_kickoff`), guardrails, telemetry spans, and the event bus.
- **`task.py`** + `tasks/` — `Task`, `ConditionalTask`, `TaskOutput`, `LLMGuardrail`. Tasks support `output_pydantic` / `output_json` (mutually exclusive), `context` chaining, `guardrail`, `max_retries`, `output_file`.
- **`lite_agent.py`** — minimal standalone agent runtime used outside full Crew orchestration.
- **`llm.py`** + `llms/` — single `LLM` wrapper around **litellm** (pinned `litellm==1.74.9`). `BaseLLM` in `llms/base_llm.py` is the extension point for custom LLM backends; `llms/third_party/` holds bridges like aisuite.

### Decorator-based project pattern (`src/crewai/project/`)
End-user projects (and the templates that scaffold them) use `@CrewBase` on a class plus `@agent`, `@task`, `@crew`, `@before_kickoff`, `@after_kickoff`, `@tool`, `@llm`, `@callback`, `@output_json`, `@output_pydantic`, `@cache_handler`. `crew_base.py` introspects the decorated methods, loads `config/agents.yaml` and `config/tasks.yaml` relative to the class file, and resolves string references (e.g. an agent's `tools: [my_tool]` gets bound to the `@tool`-decorated method `my_tool`). When editing the decorator framework, keep this YAML→method binding intact — it is the contract every scaffolded project depends on.

### Flows (`src/crewai/flow/`)
`flow.py` defines `Flow[StateT]` where `StateT` is `dict` or a `BaseModel` subclass. State automatically gets a `id` (UUID). `flow.kickoff()` / `kickoff_async()` are the entry points; `flow.plot()` renders an HTML graph via `flow_visualizer.py`. Persistence lives in `flow/persistence/` (the `@persist` decorator). Flow execution emits events through `crewai_event_bus`.

### Memory & RAG
- **`memory/`** — `short_term/` (ChromaDB RAG over current run), `long_term/` (SQLite via `storage/ltm_sqlite_storage.py`), `entity/` (RAG over named entities), `contextual/` (composes the others into the agent prompt), `external/` (Mem0 integration in `storage/mem0_storage.py`).
- **`rag/`** — abstraction layer (`core/`, `chromadb/`, `embeddings/`, `storage/`) used by both memory and knowledge.
- **`knowledge/`** — user-supplied document grounding; sources in `knowledge/source/` (PDF, text, CSV, JSON, etc.) feed `Knowledge` which is attached to `Agent` or `Crew`.

Storage location is controlled by `CREWAI_STORAGE_DIR` (defaults to platform-specific `appdirs` path). Tests always override this; production code must not assume a fixed path.

### Tools (`src/crewai/tools/`)
`BaseTool` (Pydantic `args_schema`-driven) and `@tool` decorator are the public extension points. `tool_usage.py` mediates between agents and tools, emitting `tool_usage_events`. The optional `crewai-tools` package (extras `[tools]`) ships ready-made tools.

### Event bus (`src/crewai/utilities/events/`)
Singleton `crewai_event_bus` in `crewai_event_bus.py` is the spine for observability. Every major lifecycle (crew kickoff, task start/end, agent execution, LLM call, tool usage, memory query, knowledge query, flow method) emits typed events from the corresponding `*_events.py`. `event_listener.py` and `listeners/` (notably `listeners/tracing/`) subscribe for printing, telemetry, and trace collection. Add a new lifecycle hook by defining the event in the appropriate `*_events.py`, emitting via `crewai_event_bus.emit(...)`, and (if needed) registering a listener.

### Telemetry (`src/crewai/telemetry/`)
OpenTelemetry-based, opt-out via `OTEL_SDK_DISABLED=true` or `CREWAI_DISABLE_TELEMETRY=true`. Anonymous by default; richer data only when a user sets `share_crew=True` on a `Crew`. The `__init__.py` of the package fires a one-shot Scarf install pixel in a daemon thread — also gated on the same disable flag.

### Security (`src/crewai/security/`)
`fingerprint.py` (per-agent identity) and `security_config.py` are attached to `Agent`/`Crew` and surface in events for audit trails.

### CLI (`src/crewai/cli/`)
`cli.py` is the click root. Subcommands: `create crew|flow`, `run`, `train`, `replay`, `test`, `install`, `update`, `kickoff`, `plot`, `chat`, `reset-memories`, `deploy`, `tools`, `org`, `login`, `signup`, `enterprise configure`. Templates rendered by `create_crew.py` / `create_flow.py` live under `cli/templates/{crew,flow,tool}/` — these are **excluded** from ruff/mypy/bandit and are user-facing scaffolds, so prefer real code edits over template churn unless you specifically intend to change the generated project layout.

### Experimental (`src/crewai/experimental/`)
Currently houses the `evaluation/` framework for grading agent/crew outputs. Treat as unstable.

## Conventions Worth Knowing

- **Indent for `*.py` is 2 spaces** per `.editorconfig` (note: differs from PEP 8 default; ruff-format respects editorconfig). Don't reformat to 4 spaces.
- Ruff/mypy explicitly ignore `cli/templates/` and `__init__.py`. New code outside those paths is expected to pass both clean.
- Public re-exports go through `src/crewai/__init__.py`. Internal-only modules should not be added to `__all__` there.
- When adding a new Crew/Flow lifecycle stage, prefer extending the event bus over passing callbacks through constructors — the rest of the codebase (telemetry, tracing, CLI printing) plugs in via listeners.
- `litellm` is pinned exactly (`==1.74.9`); upgrading it has historically broken streaming and tool-calling shapes. Verify against `tests/test_llm.py` and `tests/test_custom_llm.py` after any bump.
