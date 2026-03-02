# Codex - GSD Global Configuration
# Location: C:\Users\rjain\.codex\instructions.md
# This file is read by Codex for global context.

## GSD Convergence Engine

When you see references to GSD phases, convergence loops, or health scores,
the global engine is at: C:\Users\rjain\.gsd-global

### Your Role in the Loop
You handle 2 phases (unlimited tokens, execution-heavy):
1. **research**: Deep-read specs, Figma, codebase. Build dependency maps.
2. **execute**: Generate ALL code for the current batch. Full production-ready files.

### Token Freedom
- You have NO token cap. Be thorough.
- Generate COMPLETE files, not snippets
- Include all error handling, logging, validation, documentation
- Read EVERY spec doc and Figma file thoroughly

### Agent Boundaries
- You READ + WRITE source code
- You WRITE to: .gsd\research\, source code, .gsd\agent-handoff\handoff-log.jsonl
- You NEVER write to: .gsd\health\, .gsd\code-review\, .gsd\generation-queue\

### Project Patterns (STRICT)
- Backend: .NET 8 + Dapper (never EF) + SQL Server stored procedures ONLY
- Frontend: React 18 functional components + hooks
- API: Contract-first, RESTful, proper HTTP status codes
- Database: Stored procs only, parameterized, audit columns
- Compliance: HIPAA (encrypt PHI), SOC 2 (RBAC), PCI (tokenize), GDPR (consent)
- Match Figma designs EXACTLY for UI components

## Blueprint Pipeline Role

When running the blueprint pipeline (gsd-blueprint), you handle 1 phase:

### Phase 2: BUILD (per iteration)
Read next-batch.json -> generate COMPLETE production-ready files for each item.
You have UNLIMITED tokens. Generate full files, not snippets.
Follow all project patterns strictly (.NET 8 + Dapper + stored procs + React 18).
Meet EVERY acceptance criterion in the blueprint item.
DO NOT modify any files in .gsd\blueprint\ - only write source code.
