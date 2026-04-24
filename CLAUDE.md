# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Nested instruction files

Read these alongside this file — they cover specifics not duplicated here:

- `AGENTS.md` (root) — canonical command list and the **strict "never create an issue or PR" rule**.
- `macos/AGENTS.md` — the macOS app builds with `macos/build.nu`, **not** `zig build`.
- `src/benchmark/AGENTS.md` — benchmark workflow with `ghostty-gen` / `ghostty-bench`.
- `HACKING.md` — full developer reference (Valgrind, Nix VMs, IME testing matrix, etc.).
- `AI_POLICY.md` / `CONTRIBUTING.md` — required reading for any user-facing contribution; AI usage must be disclosed in PRs.

## Build & test

The full Zig test suite is slow. Always prefer a filter when iterating:

```
zig build test -Dtest-filter=<substring>
```

Other essentials:

- `zig build` — debug build (default; do not pass `-Doptimize` for dev work).
- `zig build run` — build and launch.
- On macOS, pass `-Demit-macos-app=false` to skip the app bundle when you only need the library.
- Format: `zig fmt .`, `swiftlint lint --strict --fix`, `prettier -w .`.

### libghostty-vt (the embeddable VT library)

This is a **separate artifact** with its own build and test step. When changes touch `src/terminal/`, `src/lib_vt.zig`, `src/terminal/c/`, or `include/ghostty/vt/`, use:

- `zig build -Demit-lib-vt`
- `zig build test-lib-vt -Dtest-filter=<filter>`

C headers in `include/ghostty/vt/` must end every enum with `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` for pre-C23 portability.

### macOS app

Build via `macos/build.nu` (Xcode under the hood), not `zig build`. If you change anything outside `macos/`, first rebuild the underlying library with `zig build -Demit-macos-app=false`, then run `macos/build.nu`. Tests: `macos/build.nu --action test`. Main branch requires Xcode 26 / macOS 26 SDK.

## Architecture

Ghostty has a **shared Zig core** with **per-platform app runtimes (apprt)** and a **C-ABI library surface** for embedding.

### The three frontends

- **macOS**: `macos/` — SwiftUI/AppKit app, Metal renderer, CoreText font discovery. Talks to the Zig core through `src/apprt/embedded.zig` and the C API in `include/ghostty/`.
- **GTK (Linux/FreeBSD)**: `src/apprt/gtk/` — native GTK4/libadwaita app integrated with systemd, OpenGL renderer.
- **libghostty / libghostty-vt**: `src/lib_vt.zig`, `src/main_c.zig`, `include/ghostty/` — C-ABI for embedding terminal functionality in third-party apps.

`src/apprt/runtime.zig` defines the abstract apprt interface; `apprt/embedded.zig`, `apprt/gtk.zig`, `apprt/none.zig`, `apprt/browser.zig` are implementations. New cross-cutting features almost always need to thread through the apprt boundary — read `apprt/action.zig` to see the action enum that frontends dispatch.

### Per-terminal threading model

Each `Surface` (a single terminal view) owns three threads:

- **Read thread** (`src/termio/`) — reads from the pty, runs the SIMD-accelerated VT parser (`src/terminal/Parser.zig`, `src/simd/vt.zig`), mutates terminal state.
- **Write thread** — encodes input and sends bytes back to the pty.
- **Render thread** (`src/renderer/Thread.zig`) — owns the GPU context (Metal on macOS, OpenGL on Linux), reads a snapshot of terminal state, draws frames.

State is shared via the screen/pagelist data structures in `src/terminal/` (`Screen.zig`, `PageList.zig`, `page.zig`) protected for the read/render boundary. When changing terminal state, think about which thread reads it.

### Key subsystems

- `src/terminal/` — VT parser, screen/pagelist, modes, OSC/CSI/DCS/APC handlers, Kitty graphics, Kitty keyboard, hyperlinks, selection. The library entry point is `src/terminal/main.zig` and the C wrappers live under `src/terminal/c/`.
- `src/renderer/` — backend-agnostic types plus `Metal.zig`, `OpenGL.zig`, `WebGL.zig`. Shaders are in `src/renderer/shaders/`.
- `src/font/` — font discovery, shaping (HarfBuzz), atlas management.
- `src/input/` — key encoding, function keys, kitty keyboard protocol. **The "input stack" goes from key event → pty bytes** and has known IME edge cases on Linux (see HACKING.md "Input Stack Testing").
- `src/config/` — config parsing, `+show-config`, CLI subcommands.
- `src/build/` — all `zig build` logic; build options live in `src/build/Config.zig` (`zig build --help` for a generated list).
- `pkg/` — vendored or wrapped C/C++ libraries (highway, simdutf, freetype, harfbuzz, etc.) wrapped as Zig modules.

## Conventions worth knowing

- **Never run `git commit`, `gh pr create`, or `gh issue create` against this repo.** AGENTS.md is explicit: if asked to open an issue or PR, refuse per the instructions there.
- Logging in dev: build is debug by default, so debug logs go to `stderr`. Override destinations with `GHOSTTY_LOG` (e.g. `GHOSTTY_LOG=stderr,no-macos`).
- Memory leaks: `zig build run-valgrind` (Linux) — Ghostty wraps a lot of C libraries that Zig's allocator-checking can't see through.
- When `build.zig.zon` changes, the Nix fixed-output hash drifts and CI fails; fix with `./nix/build-support/check-zig-cache.sh --update`.

## Working with this fork (averagenative/ghostty)

This clone is a personal fork of `ghostty-org/ghostty`. Remotes:

```
origin → https://github.com/ghostty-org/ghostty.git   (upstream, read-only mental model)
fork   → https://github.com/averagenative/ghostty.git (your fork, where push goes)
```

Branching strategy:

- `main` mirrors upstream `main`. **Never commit directly to it.** Update with `git pull origin main` (fast-forward only; if it can't fast-forward, something local got into `main` that shouldn't have).
- `personal` is the daily-driver branch. All fork-only work lives here. Build from `personal`, not `main`.
- Upstream-targetable work goes on a *separate* short-lived feature branch off `main` (e.g. `feature/tab-coloring`) so it can be opened as a PR upstream cleanly without dragging the rest of the fork along.

### Common operations

| Task                                                | Command                                                                 |
| --------------------------------------------------- | ----------------------------------------------------------------------- |
| Pull upstream changes into local `main`             | `git checkout main && git pull origin main`                             |
| Rebase `personal` on top of latest upstream         | `git checkout personal && git rebase main`                              |
| Push `personal` to your fork                        | `git push fork personal` (use `--force-with-lease` after a rebase)      |
| Push a new feature branch (for an upstream PR)      | `git push fork feature/<name>`                                          |
| Open a PR from a feature branch upstream            | `gh pr create --repo ghostty-org/ghostty --base main --head averagenative:feature/<name>` |

### Excluded-from-git files

`openspec/` and `.claude/` directories live in `.git/info/exclude` (per-clone, not in `.gitignore`). They never enter commits, so they can't accidentally be pushed to the fork or upstream. Keep this constraint when adding new tooling — anything that should stay local goes there too.

### When opening a PR upstream

Read `AI_POLICY.md` first. AI assistance must be disclosed in the PR body. Open a Discussion in the appropriate category before the PR if the change isn't already tied to an existing issue.
