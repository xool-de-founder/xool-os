# Xool OS

A fast, native macOS browser (WebKit) with AI agents: local models first
(Ollama, LM Studio), cloud models with your own API key as an option.

Based on [Search](https://github.com/driceroland/Search) by Office Commun (MIT).
The plan and architecture are in [docs/PLAN.md](docs/PLAN.md).

## Build

```bash
./build.sh          # release build → build/Xool OS.app
./build.sh debug    # faster debug build
open "build/Xool OS.app"
```

Needs the Swift 6 toolchain and macOS 14+. Command-line tools are enough:
`@State`/`@Entry` of the macOS 27 SDK are macros whose plugin ships with Xcode
only, so the sources use `@XState` (Sources/XoolOS/StateShim.swift) instead.

`scripts/shot.sh NAME` saves a screenshot of the Xool OS window to docs/shots.

`upstream` stays a git remote to pull fixes from Search.
