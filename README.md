# Xool OS

A fast, native macOS browser (WebKit) with AI agents: local models first
(Ollama, LM Studio), cloud models with your own API key as an option.

Based on [Search](https://github.com/driceroland/Search) by Office Commun (MIT).
The plan and architecture are in [docs/PLAN.md](docs/PLAN.md).

## Set up local AI (one command)

On a Mac with Apple silicon, in Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/xool-de-founder/xool-os/main/scripts/xool-setup.sh | bash
```

It looks at your Mac, picks a model (48 GB and up: `qwen3.6:35b`, otherwise
`gpt-oss:20b`), installs Ollama if it is missing, gives it a 64k context, pulls
the model, tests tool calling and sets up the voice (Whisper and Piper) in
`~/Library/Application Support/Xool/voice`. It deletes nothing and never asks
for your password.

```bash
... | bash -s -- --check            # only look, change nothing
... | bash -s -- --model qwen3.6:27b   # another model
... | bash -s -- --yes              # don't ask
... | bash -s -- --no-voice         # skip the voice
```

In the app: **Settings › Models › Set up local AI** runs the same script and
shows its steps.

## Talk to an agent

Hold **fn** (or **⌥ Space**, your choice in Settings › Models › Voice) and
speak: the words go to the agent you used last, which works with its browser
tabs as if you had typed. Its answer is read aloud sentence by sentence while
it is still being written. Press the key or talk over it and it stops at once.
The mic button in a thread does the same by click; right-click it for
hands-free. Without the setup above, Xool OS uses the Mac's own speech
recognition and voices (push to talk only).

Talking while another app is in front needs Input Monitoring for Xool OS
(System Settings › Privacy & Security). The microphone prompt appears the
first time you talk.

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
