# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Detected stack
- Languages: Rust.
- Frameworks: none detected from the supported starter markers.

## Verification
- Run Rust verification from `rust/`: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`
- `src/` and `tests/` are both present; update both surfaces together when behavior changes.

## Repository shape
- `rust/` contains the Rust workspace and active CLI/runtime implementation.
- `src/` contains source files that should stay consistent with generated guidance and tests.
- `tests/` contains validation surfaces that should be reviewed alongside code changes.
- `web-ui/` *(personal-fork addition; PR #14)* — localhost-only single-user web app that wraps `claw` in a structured shell + xterm.js terminal. Python+FastAPI backend, vanilla HTML/JS frontend, tmux per session. See `web-ui/README.md` and `web-ui/PLAN.md`. Independent test suite — run `cd web-ui && .venv/bin/pytest server/tests` after editing it; the Rust verification commands above don't cover it.

## Working agreement
- Prefer small, reviewable changes and keep generated bootstrap files aligned with actual repo workflows.
- Keep shared defaults in `.claude.json`; reserve `.claude/settings.local.json` for machine-local overrides.
- Do not overwrite existing `CLAUDE.md` content automatically; update it intentionally when repo workflows change.

## This is a personal hardened fork
- Upstream is `ultraworkers/claw-code`. This fork (`prcdslnc13/claw-code`) ships additional permission and OAuth hardening that upstream does not target — see `patches/` and the merged PRs (#1, #2). Do not assume changes here are upstream-bound.
- Permission-policy invariant: `cl status` (or `claw status`) must report `Permission mode  read-only` from the repo root. If it shows `danger-full-access`, the cwd-precedence gotcha (see PR #2) is back; check the root `.claw.json` and the `WorkingDirectory` of any service that launches claw.
- Local operational plumbing (the `cl` wrapper, `cl-web` ttyd launcher, and systemd unit) is documented in `docs/local-setup.md`. As of 2026-04-29, `web-ui/` is the primary forward direction for browser access; the ttyd setup is still working but supplanted for daily web use.
