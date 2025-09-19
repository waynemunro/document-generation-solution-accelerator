## Copilot Instructions for This Repository

Purpose: Enable AI coding agents to make correct, production‑aligned changes quickly in the Document Generation Solution Accelerator.

### 1. Architecture at a Glance
- Backend: `Quart` async app (`src/app.py`) exposing chat, template, section generation, history, and search enrichment routes. Central streaming logic lives in `send_chat_request` (handles browse vs template/section modes, streaming deltas, citation mapping, run step post‑processing).
- Agents: Lazy singleton factories in `src/backend/api/agent/*_agent_factory.py` (`Browse`, `Template`, `Section`) built on `azure.ai.projects` (AI Foundry) + Azure AI Agents tools. Each factory: async singleton guarded by an `asyncio.Lock`, includes cleanup via `delete_agent` in `@app.after_serving`.
- Data Layer / Grounding: Azure AI Search index (vector + semantic hybrid). Index schema created by scripts (`scripts/prepdocs.py` or `scripts/data_preparation.py`). Content chunks store `content`, `title`, `filepath`, `url`, `metadata`, optional `contentVector`.
- Conversation History: Optional Cosmos DB via `CosmosConversationClient` (`backend/history/cosmosdbservice.py`); feature toggled by presence of `AZURE_COSMOSDB_*` env vars.
- Settings & Config: Centralized in `src/backend/settings.py` using Pydantic models. Access through global `app_settings`—never re-parse env manually. Embedding dependency logic encapsulated in `_AzureOpenAISettings.extract_embedding_dependency()`.
- Telemetry: Application Insights via `azure.monitor.opentelemetry.configure_azure_monitor` if `APPLICATIONINSIGHTS_CONNECTION_STRING` present; custom events through `track_event_if_configured` in `event_utils.py`.

### 2. Critical Developer Workflows
- Run backend locally: Ensure `.env` (see `.env.example` if present) then `pip install -r src/requirements.txt && ./src/start.sh` (Quart + gunicorn). For Windows use `start.cmd`.
- Ingest / (Re)build search index: `python scripts/prepdocs.py --searchservice <name> --index <index> --formrecognizerservice <fr> --formrecognizerkey <key> [--embeddingendpoint <embed-endpoint>]` OR advanced multi-source ingestion via `scripts/data_preparation.py --config config.json`.
- Tests: Backend tests expected under `src/tests` (GitHub Action `tests.yml`). Frontend tests (if present) run from `src/frontend` with Node 20 (`npm test -- --coverage`). Coverage gates target ≥80%.
- Deployment: `azd up` (see `azure.yaml` / `app-azure.yaml` + `infra/`). Teardown with `azd down` or delete resource group.
- Regenerate agents after env/model change: Call factory `delete_agent()` then next request re-creates (or restart app).

### 3. Key Conventions & Patterns
- Do not construct service endpoints ad hoc; derive from `app_settings`. Example: use `app_settings.azure_ai.agent_endpoint` instead of hardcoding.
- Agent naming pattern: `DG-<Type>Agent-{solution_name}`; keep consistent if adding new agent types.
- Index naming in browse factory: `project-index-{connection_name}-{index}` — maintain when extending to avoid duplicate asset churn.
- All new environment-driven options should extend the appropriate Pydantic settings class; avoid scattering `os.getenv` reads.
- Streaming: Preserve marker handling (regex `r'【(\d+:\d+)†source】'`) and incremental citation resolution. If modifying `send_chat_request`, ensure citation replacement still yields stable numbering and yields final citations after stream end.
- Section content generation length cap enforced in settings prompt (≤2000 chars). Respect or update prompt constant centrally.
- Cosmos history: Wrap failures (network/auth) but do not block user answer; follow existing try/except pattern in `init_cosmosdb_client` and history routes.

### 4. Integration Points (Must Know Before Editing)
- Azure AI Agents: Factories create or reuse agents; tools configured (e.g., `AzureAISearchTool`) with vector semantic hybrid search. Index asset created if absent.
- Azure AI Search: Hybrid query types—respect `query_type` normalization (`to_snake`) and `top_k`/`strictness` from settings. Any schema changes must mirror ingestion scripts & factory field mapping.
- Embeddings: Provided via embedding dependency resolution; do not call embedding endpoints directly in application flow unless extending ingestion logic.
- Auth Modes: API keys vs Managed Identity handled in `_AzureSearchSettings.set_authentication`; extend there if introducing new auth flows.

### 5. Safe Extension Guidelines
- Adding a new agent: Create `<name>_agent_factory.py` subclassing `BaseAgentFactory`; follow pattern of listing existing agents first to avoid duplicates; include deletion logic.
- Adding a new route: Import `bp` and keep async; return streaming via `format_stream_response` / `format_non_streaming_response` style if aligning with existing semantics.
- Modifying prompts: Change ONLY in `settings.py` constants to keep a single source of truth.
- New env vars: Add field + validation to the relevant settings model; document in `README_LOCAL.md` or deployment guide.

### 6. Common Pitfalls (Avoid)
- Bypassing factories (creating agents directly in routes) — leads to resource leaks and inconsistent cleanup.
- Hardcoding index names/connection names — breaks multi-environment deployments.
- Emitting partial citation markers without final consolidation — verify post-stream citation extraction still runs when altering stream logic.
- Introducing blocking I/O in async routes (prefer `async` SDKs already in use).

### 7. When Opening a PR (AI Agent Behavior)
- Confirm affected settings via search: e.g. changing index field requires updating: ingestion (`prepdocs.py` / `data_preparation.py`), factories, and citation mapping logic.
- Run/describe minimal repro for stream changes (include example user prompt + expected streamed chunk sequence).
- Maintain ≥80% coverage threshold when adding backend logic (add/adjust tests under `src/tests`).

### 8. Example: Adding a New Retrieval Filter
1. Extend `_SearchCommonSettings` with new field (e.g., `doc_type: Optional[str]`).
2. In `_AzureSearchSettings.construct_payload_configuration`, append to `parameters` only if set.
3. Adjust ingestion to populate field & index schema (`create_search_index`).
4. Update browse agent factory `field_mapping` if surfaced to the agent.

Keep this file pragmatic—reflect actual patterns, not aspirations. If uncertain, inspect `src/app.py` and related factory modules before large edits.
