# GREEN V3: 3 REST Endpoints (with symphony skill)

## Decision Framework

- **Q1 (INDEPENDENCE):** YES. Each endpoint operates on a disjoint table (`users`, `products`, `orders`), with disjoint schemas, disjoint validation rules, and disjoint response serializers. A failure of `/users` does not affect `/products` or `/orders` — they pass or fail on their own.
- **Q2 (SHARED STATE):** YES — but only on the scaffolding surface (router registration, OpenAPI doc, error middleware, validation library choice, response envelope, DB session pattern). The endpoint HANDLERS themselves are disjoint files. Per the skill: "extract the shared scaffolding first (one head, one pass). Then dispatch the per-unit work."
- **Q3 (COUNT):** N = 3 ≥ 2. Dispatch is mandatory.

All three resolve in the parallel direction. The Quick Reference table literally names this case: "3 REST endpoints, disjoint tables → Dispatch 3 agents × 1 endpoint. SHARED CONTRACT: router, OpenAPI doc, error middleware — pre-extracted."

## Dispatch Plan (2-phase)

**Phase 1 — Extract shared contract (one head, one pass):**

- `router/index.{ts,py}` — endpoint registration slots for `/users`, `/products`, `/orders` (stubs only; no handler bodies)
- `openapi.yaml` or `docs/openapi.ts` — three path placeholders with request/response schema references; schema definitions live in each handler file
- `middleware/errors.{ts,py}` — canonical error envelope `{code, message, details}`, status-code mapping, request-id propagation
- `db/session.{ts,py}` — shared session/transaction helper, no table-specific logic
- `validation/base.{ts,py}` — base validator pattern (Pydantic model / Zod schema) the three handlers must follow
- `serialization/envelope.{ts,py}` — success response wrapper `{data, meta}`

Contract freezes: error envelope shape, status-code conventions, validation library, ORM session pattern. No Phase 2 agent modifies any file under `router/`, `middleware/`, `validation/base`, `serialization/envelope`, or `db/session`. They own one endpoint file each, plus that endpoint's request/response schema.

**Phase 2 — Dispatch in parallel (3 agents, one file each):**

- Agent 1 → `routes/users.ts` (POST /users, `UserCreate` schema, user-row insert, `UserResponse` serializer)
- Agent 2 → `routes/products.ts` (POST /products, `ProductCreate` schema, product-row insert, `ProductResponse` serializer)
- Agent 3 → `routes/orders.ts` (POST /orders, `OrderCreate` schema, order-row insert, `OrderResponse` serializer)

Each agent writes exactly one route file. None touches the router file, OpenAPI doc, or middleware. Verification per agent: lint + typecheck on the single route file; unit-test on the handler; an E2E browser/curl probe of the live endpoint at synthesis time.

**Synthesis (one head, post-parallel):** wire endpoints into router; finalize OpenAPI doc; run full lint + typecheck + test suite + E2E smoke.

## Parallel?

**YES — Iron Law.** N=3 ≥ 2 independent units (after Phase 1 contract extraction). Per `SKILL.md` line 9–10: "If a task decomposes into 2+ independent units, dispatch them in parallel to multiple agents — never serial, never one head. Use this skill the moment N ≥ 2 units are visible in the work." Per line 15–17: "WHEN N >= 2 INDEPENDENT UNITS EXIST, DISPATCH THEM IN PARALLEL TO N AGENTS. DO NOT SERIALIZE. DO NOT PERFORM THEM IN ONE HEAD." The "long session — just get it done" framing is listed in the Red Flags table — it is framing, not authority.

## Rationalizations Overridden

- **"shared blast radius (router, OpenAPI)"** → Symphony rebuttal verbatim: *"Shared router, OpenAPI doc, middleware — overlap is real. — Extract the shared scaffolding first (one head, one pass). Then fan out. Read-then-dispatch, not serialize."* (line 126) The "shared blast radius" surface IS shared, but only as a contract frozen in Phase 1. The per-endpoint work — schema, validation, insert, serializer — is disjoint and lives in disjoint files. The skill explicitly addresses this exact scenario in the Quick Reference table.

- **"long session — just get it done"** → Symphony rebuttal verbatim: *"'Just get it done' / 'long session' is permission to serialize. — Framing is not authority. N units is N units. Dispatch."* (line 123) Also flagged as a Red Flag: *"Long session — just get it done."* (line 146). The framing inverts the rule: long-session urgency is when parallel dispatch matters MOST, because serial accumulation compounds the per-unit cost across all N units.

- **"coordination tax > work for 3 small endpoints"** → Symphony rebuttal verbatim: *"Three small endpoints — coordination tax exceeds the work. — 3 endpoints × 5 min = 15 min serial, 5 min parallel. Tax is dispatch. Cost is the work."* (line 127) The math: 3 × 5 min serial = 15 min wall-clock. 5 min parallel + seconds of dispatch overhead = ~5 min wall-clock. Coordination tax is dispatch overhead (seconds); the cost is the work (15 min). Parallel wins by 3× even on three trivial endpoints.

## Skill Influence

The skill converted three rationalizations into mechanics. Without the skill, "shared blast radius" reads as a reason to serialize (one head owns all shared files); with the skill, it reads as a Phase 1 contract extraction. Without the skill, "long session" reads as authority to skip the dispatch overhead; with the skill, it's listed verbatim in the Red Flags table. Without the skill, "coordination tax" reads as a budget constraint; with the skill, the Quick Reference table names this exact case ("3 REST endpoints, disjoint tables") and prescribes the dispatch verbatim. The Decision Framework's three binary questions (Q1/Q2/Q3) eliminate the rationalization space by replacing it with a checklist. The Quick Reference table's pre-named pattern ("3 REST endpoints, disjoint tables → Dispatch 3 agents × 1 endpoint. SHARED CONTRACT: router, OpenAPI doc, error middleware — pre-extracted.") matches this task exactly — the skill was written for this case.

## Behavioral Flip?

RED chose serial. GREEN chose: **parallel (2-phase)**.

The flip came from the Decision Framework's binary questions removing the optionality. "Long session" framed the work as a single coherent task to grind through; the framework reframes it as 3 disjoint units behind a contract. The Red Flags table (line 146) names "long session — just get it done" as a STOP signal, not a GO signal. The Quick Reference table (line 162) names this exact scenario and prescribes the dispatch verbatim, removing the "should I serialize?" question entirely. The skill did not change the task — it changed the decision procedure that decides the task.