# 21. Agent conventions

Status: Accepted (2026-09-28)

## Context

Much of the implementation is done by AI coding agents, one plan step per session. Each session starts cold.
Without written conventions every session re-derives style, layering and test rules, and they drift apart
(one session raises from an operation, another returns Results; one mocks the DB, another doesn't). The
original checklist lived in a local, git-ignored working folder, invisible both to agents in a fresh checkout
and to reviewers.

## Chosen

A committed `CLAUDE.md` at the repo root, loaded automatically by the agent. It distils the working
conventions: commands (everything via `docker compose exec web`, `bin/ci` as the gate), commit rules,
layering, naming and style, linting, testing. It also includes the rule that an agent that finds a lint rule or
convention too strict must **ask the user** rather than disable or work around it.

## Discarded (why)

- **Pointing agents at the git-ignored checklist**: not versioned, and invisible to reviewers.

## Consequences

- Reviewers can see exactly what the agents were told.
- Conventions change through commits to `CLAUDE.md`, not through each session's own interpretation.
