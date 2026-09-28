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

The README is written **outside-in**. It opens with the challenge in plain words, then describes the
solution from the client's point of view (all-or-nothing bulks, safe retries, what each status means), and
only then goes into running it, how it works, guarantees, operations, architecture and development. Readers
from product, reviewers and debrief interviewers can each stop at the depth they need, and the technical
sections read as the justification of the product behaviour described above them.

## Discarded (why)

- **A separate `docs/DEBRIEF.md`**: splits the reviewer's reading across two entry points.
- **Local-only notes**: invisible to the reviewers.
- **Technical-first README** (setup and API first, reasoning after): faster for someone who only wants to run
  it, but the reader meets the mechanics before understanding the problem they solve. A one-line "Run it"
  pointer at the top covers that reader instead.

## Consequences

- The README is long; its section order goes from broad to deep, and a pointer at the top links straight to
  the setup section.
- The README and the decision records must be kept consistent when a decision changes.
