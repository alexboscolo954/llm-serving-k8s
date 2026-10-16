# Every claim is proven or labelled

This repo is a public portfolio, so a reader must be able to tell which claims are backed by evidence. Every feature carries one **Proof level**: **CI-proven** (runs end-to-end on the CPU kind cluster in CI), **Benchmarked** (executed in a recorded GPU benchmark session on rented hardware, results committed with the exact setup), or **Render-only** (rendered and schema/policy-checked in CI, never executed). Nothing ships without a level, and the README says which level each feature has.

## Considered Options

- **CI-proven only**: rejected, it would exclude everything GPU-specific, which is the point of the repo.
- **Self-hosted GPU runner in CI**: rejected, an always-on GPU costs too much for a personal project, and a public repo with a self-hosted runner lets any fork's PR run code on that machine.
- **Unlabelled GPU manifests**: rejected, YAML that was never run reads as the same thing as YAML that was, and a reviewer can't tell them apart.

## Consequences

- New features are designed so a CPU-sized version can run in CI (small model, low replica counts) whenever possible.
- Benchmarked results go stale when versions change. Every results table records the image tags, model, GPU, and date.
