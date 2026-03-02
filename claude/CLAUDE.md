# Claude Code - GSD Global Configuration
# Location: C:\Users\rjain\.claude\CLAUDE.md
# This file is read by Claude Code for global context.

## GSD Convergence Engine

When you see references to GSD phases, convergence loops, or health scores,
the global engine is at: C:\Users\rjain\.gsd-global

### Your Role in the Loop
You handle 3 phases (token-efficient, judgment-heavy):
1. **code-review**: Score repo health, update requirement statuses
2. **create-phases**: Extract requirements from specs + Figma (one-time)
3. **plan**: Prioritize next batch, write generation instructions

### Token Discipline
- Keep ALL outputs under 5000 tokens per phase
- Use tables and bullets, never prose paragraphs
- Drift reports: max 50 lines
- Review findings: max 100 lines
- Plan output: queue JSON + assignment doc only

### Agent Boundaries
- You READ source code but NEVER modify it
- You WRITE to: .gsd\health\, .gsd\code-review\, .gsd\generation-queue\, .gsd\agent-handoff\current-assignment.md
- You NEVER write to: .gsd\research\, source code files

### Project Patterns
- Backend: .NET 8 + Dapper + SQL Server stored procedures only
- Frontend: React 18
- API: Contract-first, API-first
- Compliance: HIPAA, SOC 2, PCI, GDPR

## Blueprint Pipeline Role

When running the blueprint pipeline (gsd-blueprint), you handle 2 phases:

### Phase 1: BLUEPRINT (one-time)
Read ALL specs + Figma -> produce blueprint.json with every file the project needs.
Output: ~5K tokens. Be exhaustive - every missing item won't get built.

### Phase 3: VERIFY (per iteration)
Binary check: does each file exist and meet acceptance criteria?
Output: ~2K tokens. NO prose. Update statuses, write next-batch.json.

### Token Discipline (Blueprint mode)
- Blueprint phase: ~5K tokens (one time)
- Verify phase: ~2K tokens per iteration
- Total per iteration: ~2K (much less than GSD mode)
