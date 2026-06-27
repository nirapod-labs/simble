<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 Nirapod Labs
-->

# Contributing

SimBLE is PR-driven. Everything lands through a pull request that a maintainer
reviews. Nothing goes straight to `main` after the repository seed.

## Basics

- Branch off `main` and keep the branch focused.
- Use conventional commit subjects. The allowed types and scopes are in
  `.commitlintrc.json`.
- Keep PRs small enough to review in one sitting.
- CI must be green before merge.
- The release is cut from a version tag on merged `main`.

## Building

Run:

```sh
make bootstrap
make build
make test
```

## Design changes

If your PR changes the BLE routing mechanism, wire protocol, security model, or
platform limits, describe the design in the PR before the code, so a reviewer can
check the approach first.
