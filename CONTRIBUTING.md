<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Contributing

SimBLE is PR-driven. Everything lands through a pull request that a maintainer
reviews. Nothing goes straight to `main`.

## The basics

- Branch off `main` and keep the branch focused on one thing.
- Conventional commits, lowercase subject after the type and scope. The allowed
  types and scopes are in `.commitlintrc.json`, and the commit-msg hook checks
  them, so a bad message will not commit.
- The PR title becomes the squash subject on `main`, so it has to be a valid
  conventional subject too. GitHub appends ` (#N)` and `subject-max-length` is
  50, so keep the title around 45 characters. commitlint runs on the PR.
- Small PRs. If a reviewer cannot hold the whole change in their head, split it.
- CI has to be green before merge: lint, build, and the relevant tests.

## Hooks

Run `pnpm install` and `pnpm exec lefthook install` once. After that, formatting
and the commit-message check run on commit, and the no-direct-main guard runs on
push. If a hook blocks you and you genuinely need around it, that is a
conversation with a maintainer, not a quiet `--no-verify`.

## Building

`make bootstrap` from a fresh clone, then `make build` and `make test`. The
toolchain and every `make` target are in [docs/development.md](docs/development.md).

## Design before code

If a change touches the BLE routing mechanism, the wire protocol, the security
model, or the platform limits, describe the design in the PR before the code, so
a reviewer can check the approach first. Not the other way around.
