# 22. Debrief in the README

Status: Accepted (2026-09-28)

## Context

The submission is reviewed like a pull request, followed by a 90-minute debrief with engineers. The brief asks
for a document describing the solution, the approach, issues faced, potential improvements and how to run it.
The debrief will probe the operational questions: which transaction prevents a double spend, what happens on a
crash on either side of the commit, how idempotency works across instances, how to scale to 10k requests per
second or very large bulks, where observability goes, and what was deliberately left out.

## Chosen

The debrief answers live in the README, in dedicated sections: **Operational scenarios**, **Scaling** and
**Not built yet**, next to the technical sections (setup, `bin/ci`, API walkthrough, architecture,
invariants). Decision records hold the detailed trade-offs, and the README links to them.

## Discarded (why)

- **A separate `docs/DEBRIEF.md`**: splits the reviewer's reading across two entry points.
- **Local-only notes**: invisible to the reviewers.

## Consequences

- The README is long, so it leads with setup and the API, and puts reasoning after.
- The README and the decision records must be kept consistent when a decision changes.
