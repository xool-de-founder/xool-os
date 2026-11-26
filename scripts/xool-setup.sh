#!/bin/bash
# =============================================================================
#  Xool OS – set up local AI on this Mac with one command
#
#  What it does:
#    1. Looks at your Mac (chip, memory).
#    2. Picks a model that fits: 48 GB and up -> qwen3.6:35b, otherwise gpt-oss:20b.
#    3. Checks for Ollama and installs it if it is missing (no admin password).
#    4. Gives Ollama a 64k context (OLLAMA_CONTEXT_LENGTH=65536).
#    5. Pulls the model and tests that it can call a tool.
#    6. Sets up the voice (Whisper, Piper) in
#       ~/Library/Application Support/Xool/voice
#
#  It deletes nothing and never asks for your password.
#
#  Run it (in Terminal):
#    curl -fsSL https://raw.githubusercontent.com/xool-de-founder/xool-os/main/scripts/xool-setup.sh | bash
#
#  Only check, change nothing:        ... | bash -s -- --check
#  Force a model:                     ... | bash -s -- --model qwen3.6:27b
#  Don't ask, answer yes:             ... | bash -s -- --yes
#  Skip the voice:                    ... | bash -s -- --no-voice
#  Only the voice (no Ollama, no model): ... | bash -s -- --only-voice
#
#  Based on scripts/jarvis-mac.sh and scripts/jarvis-stimme.sh of
#  github.com/Paulito12209/jarvis-on-nod (see THIRD_PARTY_NOTICES.md).
#
#  Exit code: 0 all good, 3 done but something needs a look, 1 stopped.
# =============================================================================

set -u

# ----- Settings --------------------------------------------------------------
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-65536}"
MODEL_BIG="qwen3.6:35b"       # 48 GB and up: fast all-rounder
MODEL_SMALL="gpt-oss:20b"     # fallback for 16-47 GB
XOOL_HOME="${XOOL_HOME:-$HOME/Library/Application Support/Xool}"
VOICE_HOME="$XOOL_HOME/voice"
VOICE_NAME="${XOOL_VOICE_NAME:-de_DE-thorsten-high}"
PY_VERSION="3.12"
REPO_URL="${XOOL_REPO_URL:-https://github.com/xool-de-founder/xool-os.git}"

MODE="install"
FORCED_MODEL=""
WITH_VOICE=1
ONLY_VOICE=0
ASSUME_YES="${XOOL_YES:-0}"
TEST_MODE="${XOOL_TEST_MODE:-0}"   # tests only

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --model) shift; FORCED_MODEL="${1:-}" ;;
    --yes|-y) ASSUME_YES=1 ;;
    --no-voice) WITH_VOICE=0 ;;
    --only-voice) ONLY_VOICE=1 ;;
    --help|-h) sed -n '2,30p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1"; exit 2 ;;
  esac
  shift
done

# ----- Output ----------------------------------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; C=""; N=""
fi
TOTAL=6
[ "$ONLY_VOICE" = "1" ] && TOTAL=2
STEP=0
step()  { STEP=$((STEP+1)); printf '\n%s%s▶ Step %s/%s: %s%s\n' "$B" "$C" "$STEP" "$TOTAL" "$1" "$N"; }
ok()    { printf '  %s✔%s %s\n' "$G" "$N" "$1"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
bad()   { printf '  %s✘%s %s\n' "$R" "$N" "$1"; }
info()  { printf '    %s\n' "$1"; }
PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS+1)); }
die() { bad "$1"; [ -n "${2:-}" ] && info "Next: $2"; exit 1; }

# Questions also work under "curl | bash"; with no terminal the answer is yes.
ask_yes() {
  if [ "$ASSUME_YES" = "1" ]; then return 0; fi
  local answer=""
  if [ -r /dev/tty ] && [ -t 1 ]; then
    printf '  %s?%s %s [Y/n] ' "$Y" "$N" "$1" >/dev/tty
    read -r answer </dev/tty || answer=""
  fi
  case "$answer" in n|N|no|No|nein) return 1 ;; *) return 0 ;; esac
}

printf '\n%s──────────────────────────────────────────────%s\n' "$B" "$N"
printf '%s   Xool OS: local AI, set up for you%s\n' "$B" "$N"
printf '%s──────────────────────────────────────────────%s\n' "$B" "$N"
[ "$MODE" = "check" ] && info "Check only: nothing is changed."

# ----- 1. This Mac -----------------------------------------------------------
step "Your Mac"
if [ "$TEST_MODE" != "1" ] && [ "$(uname -s)" != "Darwin" ]; then
  die "This script is for macOS." "Use Xool OS on a Mac."
fi
if [ "$TEST_MODE" = "1" ]; then
  RAM_BYTES="${XOOL_TEST_RAM_BYTES:-68719476736}"; CHIP="Apple M5 Pro (test)"
else
  RAM_BYTES="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
fi
RAM_GB=$(( RAM_BYTES / 1073741824 ))
ok "Chip: $CHIP"
ok "Memory: ${RAM_GB} GB"
case "$CHIP" in
  *Apple*) : ;;
  *) warn "Not an Apple chip. Local models run slowly here."; problem ;;
esac
FREE_GB="$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "${FREE_GB:-}" ] && ok "Free disk space: ${FREE_GB} GB"

# ----- 2. Model --------------------------------------------------------------
if [ "$ONLY_VOICE" = "1" ]; then MODEL="(voice only)"; fi
if [ "$ONLY_VOICE" != "1" ]; then
step "Choose the model"
if [ -n "$FORCED_MODEL" ]; then
  MODEL="$FORCED_MODEL"; ok "Your choice: $MODEL"
elif [ "$RAM_GB" -ge 48 ]; then
  MODEL="$MODEL_BIG"; ok "${RAM_GB} GB is plenty: $MODEL"
elif [ "$RAM_GB" -ge 16 ]; then
  MODEL="$MODEL_SMALL"; warn "${RAM_GB} GB is on the tight side. Using the smaller $MODEL."
  info "Close big apps while the agents work."; problem
else
  bad "With ${RAM_GB} GB a local model is too slow to be useful."
  info "Next: use a cloud key instead (Settings › Models), no setup needed."
  exit 1
fi
if [ -n "${FREE_GB:-}" ] && [ "${FREE_GB:-0}" -lt 30 ] && [ "$MODE" = "install" ]; then
  warn "Under 30 GB free. The model is about 20 GB."; problem
fi

# ----- 3. Ollama -------------------------------------------------------------
step "Ollama"
OLLAMA_APP=""
for d in /Applications/Ollama.app "$HOME/Applications/Ollama.app"; do [ -d "$d" ] && OLLAMA_APP="$d" && break; done
has_cli() { command -v ollama >/dev/null 2>&1; }
server_up() { curl -fsS --max-time 3 "$OLLAMA_URL/api/version" >/dev/null 2>&1; }

if has_cli || [ -n "$OLLAMA_APP" ]; then
  ok "Ollama is installed."
elif [ "$MODE" = "check" ]; then
  bad "Ollama is missing. Run without --check to install it."; problem
else
  warn "Ollama is not installed."
  if ask_yes "Install Ollama into ~/Applications (no password needed)?"; then
    tmp="$(mktemp -d)"
    info "Downloading Ollama (about 100 MB) …"
    if curl -fsSL --proto '=https' --tlsv1.2 "https://ollama.com/download/Ollama-darwin.zip" -o "$tmp/Ollama.zip" \
       && unzip -q "$tmp/Ollama.zip" -d "$tmp/x"; then
      mkdir -p "$HOME/Applications"
      if [ -d "$HOME/Applications/Ollama.app" ]; then
        info "~/Applications/Ollama.app already exists, left untouched."
      else
        mv "$tmp/x/Ollama.app" "$HOME/Applications/"
      fi
      OLLAMA_APP="$HOME/Applications/Ollama.app"
      xattr -dr com.apple.quarantine "$OLLAMA_APP" 2>/dev/null || true
      ok "Ollama installed in ~/Applications."
    else
      bad "Download failed."
      info "Next: install Ollama from https://ollama.com/download, then run this again."
      rm -rf "$tmp"; exit 1
    fi
    rm -rf "$tmp"
  else
    die "Ollama is needed for local models." "Install it from https://ollama.com/download, then run this again."
  fi
fi
if ! has_cli && [ -n "$OLLAMA_APP" ] && [ -x "$OLLAMA_APP/Contents/Resources/ollama" ]; then
  PATH="$PATH:$OLLAMA_APP/Contents/Resources"
fi

# ----- 4. Context ------------------------------------------------------------
step "A 64k context for Ollama (OLLAMA_CONTEXT_LENGTH=$CONTEXT_LENGTH)"
if [ "$MODE" = "install" ] && [ "$TEST_MODE" != "1" ]; then
  CURRENT="$(launchctl getenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || true)"
  if [ "$CURRENT" != "$CONTEXT_LENGTH" ]; then
    launchctl setenv OLLAMA_CONTEXT_LENGTH "$CONTEXT_LENGTH" 2>/dev/null || true
    ok "Set OLLAMA_CONTEXT_LENGTH=$CONTEXT_LENGTH for apps you start from now on."
    # A running Ollama keeps its old setting until it restarts.
    if pgrep -x Ollama >/dev/null 2>&1 || pgrep -x ollama >/dev/null 2>&1; then
      info "Restarting Ollama so it takes effect …"
      osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || pkill -x ollama 2>/dev/null || true
      sleep 2
    fi
  else
    ok "Already set."
  fi
  info "To keep it after a restart, also set it in Ollama: menu bar icon › Settings › Context length."
  if ! server_up; then
    if [ -n "$OLLAMA_APP" ]; then open -a "$OLLAMA_APP" 2>/dev/null || true
    else (OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH" nohup ollama serve >/dev/null 2>&1 &); fi
  fi
fi
for _ in $(seq 1 30); do server_up && break; sleep 1; done
if server_up; then
  ok "Ollama answers at $OLLAMA_URL"
elif [ "$MODE" = "check" ]; then
  bad "Ollama is not running."; problem
else
  die "Ollama doesn't answer." "Open the Ollama app once, then run this again."
fi

# ----- 5. Model and tool test ------------------------------------------------
step "The model $MODEL"
model_present() { curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null | grep -Eq "\"name\": *\"$1\""; }
if ! server_up; then
  warn "Skipped: Ollama isn't running."
elif model_present "$MODEL"; then
  ok "$MODEL is already downloaded."
elif [ "$MODE" = "check" ]; then
  bad "$MODEL is not downloaded (ollama pull $MODEL)."; problem
else
  info "This is a big download (10-25 GB). It continues if you run this again."
  ollama pull "$MODEL" 2>&1 | tr '\r' '\n' | perl -pe 'BEGIN{$|=1} s/\e\[[0-9;?]*[A-Za-z]//g' | grep --line-buffered -v '^[[:space:]]*$'
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    die "The download failed." "Check your internet connection and free disk space, then run this again."
  fi
  ok "$MODEL is ready."
fi

if server_up && model_present "$MODEL"; then
  SHOW="$(curl -fsS --max-time 20 "$OLLAMA_URL/api/show" -d "{\"model\":\"$MODEL\"}" 2>/dev/null || true)"
  if printf '%s' "$SHOW" | tr -d ' \n' | grep -q '"capabilities":\[[^]]*"tools"'; then
    ok "The model can use tools."
  else
    bad "Ollama says $MODEL has no tool calling. Agents need it."
    info "Next: pick another model with --model."; problem
  fi
  info "Test run: can it call a tool? (up to 2 minutes the first time)"
  BODY='{"model":"'"$MODEL"'","stream":false,"messages":[{"role":"user","content":"What time is it in Berlin? Use the tool."}],"tools":[{"type":"function","function":{"name":"clock","description":"Returns the current time in a city","parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}}}]}'
  REPLY="$(curl -fsS --max-time 300 "$OLLAMA_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$BODY" 2>/dev/null || true)"
  if printf '%s' "$REPLY" | grep -q '"tool_calls"'; then
    ok "Test passed: the model called the tool."
  elif [ -z "$REPLY" ]; then
    warn "No answer in the test (not enough free memory?)."; problem
  else
    warn "It answered without a tool. That happens; agents usually work anyway."
  fi
  PS_OUT="$(ollama ps 2>/dev/null || true)"
  if [ -n "$PS_OUT" ]; then
    info "Loaded like this (CONTEXT should read $CONTEXT_LENGTH or more):"
    printf '%s\n' "$PS_OUT" | sed 's/^/      /'
  fi
fi

fi  # not only the voice

# ----- 6. Voice --------------------------------------------------------------
step "The voice (listening and speaking)"
if [ "$WITH_VOICE" != "1" ]; then
  info "Skipped (--no-voice)."
else
  # Where is the sidecar code? In the app bundle (XOOL_VOICE_SRC), next to
  # this script in a checkout, or in a copy of the repository.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  SRC="${XOOL_VOICE_SRC:-}"
  if [ -z "$SRC" ] && [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../Resources/voice/requirements.txt" ]; then
    SRC="$SCRIPT_DIR/../Resources/voice"
  fi
  if [ -z "$SRC" ] && [ "$MODE" = "install" ]; then
    info "Fetching the voice code from the Xool OS repository …"
    mkdir -p "$VOICE_HOME"
    if [ -d "$VOICE_HOME/repo/.git" ]; then
      git -C "$VOICE_HOME/repo" pull --ff-only -q || warn "Couldn't update, using the copy that is there."
    else
      git clone -q --depth 1 "$REPO_URL" "$VOICE_HOME/repo" || die "Couldn't download the voice code." "Check your internet connection, then run this again."
    fi
    SRC="$VOICE_HOME/repo/Resources/voice"
  fi
  VENV="$VOICE_HOME/venv"
  PY="$VENV/bin/python"
  STAMP="$VOICE_HOME/.installed"
  WANT=""
  [ -n "$SRC" ] && [ -f "$SRC/requirements.txt" ] && WANT="$( (shasum < "$SRC/requirements.txt" 2>/dev/null || cksum < "$SRC/requirements.txt") | cut -c1-16)"

  if [ -x "$PY" ] && [ -n "$WANT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT" ]; then
    ok "Voice programs are installed."
  elif [ "$MODE" = "check" ]; then
    bad "The voice isn't set up yet. Run without --check."; problem
  elif [ -z "$WANT" ]; then
    die "The voice code wasn't found." "Run this from the Xool OS app (Settings › Models), or from a checkout of the repository."
  else
    mkdir -p "$VOICE_HOME"
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    if ! command -v uv >/dev/null 2>&1 && ask_yes "Install 'uv' (a fast Python helper) into ~/.local/bin?"; then
      curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null 2>&1 || warn "uv couldn't be installed, using python3."
    fi
    if command -v uv >/dev/null 2>&1; then
      info "Installing the voice programs with uv (1-3 minutes) …"
      { [ -x "$PY" ] || uv venv -q --python "$PY_VERSION" "$VENV"; } \
        && uv pip install -q --python "$PY" -r "$SRC/requirements.txt" \
        || die "The voice programs couldn't be installed." "Check your internet connection, then run this again."
    else
      command -v python3 >/dev/null 2>&1 || die "No Python found." "Install it with: xcode-select --install"
      info "Installing the voice programs with python3 (2-5 minutes) …"
      { [ -x "$PY" ] || python3 -m venv "$VENV"; } \
        && "$PY" -m pip install -q --upgrade pip \
        && "$PY" -m pip install -q -r "$SRC/requirements.txt" \
        || die "The voice programs couldn't be installed." "Check your internet connection, then run this again."
    fi
    echo "$WANT" > "$STAMP"
    ok "Voice programs installed."
  fi

  VOICE_DIR="$VOICE_HOME/voices"
  if ls "$VOICE_DIR"/*.onnx >/dev/null 2>&1; then
    ok "German voice found ($(basename "$(ls "$VOICE_DIR"/*.onnx | head -1)" .onnx))."
  elif [ "$MODE" = "check" ]; then
    bad "No voice file yet."; problem
  elif [ -x "$PY" ]; then
    info "Downloading the voice $VOICE_NAME (about 110 MB) …"
    "$PY" -m piper.download_voices "$VOICE_NAME" --download-dir "$VOICE_DIR" >/dev/null 2>&1 \
      && ok "Voice downloaded." \
      || die "The voice download failed." "Check your internet connection, then run this again."
  fi
  info "The first time you talk, Whisper (the ears, about 1.5 GB) downloads once."
  info "macOS asks for the microphone then. Click Allow."
fi

# ----- Done ------------------------------------------------------------------
printf '\n%s──────────────────────────────────────────────%s\n' "$B" "$N"
if [ "$PROBLEMS" -eq 0 ]; then
  printf '  %s%s✔ All set.%s\n' "$B" "$G" "$N"
else
  printf '  %s%s! Almost there: %s thing(s) above need a look.%s\n' "$B" "$Y" "$PROBLEMS" "$N"
fi
printf '%s──────────────────────────────────────────────%s\n' "$B" "$N"
printf '\n  Model: %s%s%s\n  Check again any time (changes nothing):\n    curl -fsSL https://raw.githubusercontent.com/xool-de-founder/xool-os/main/scripts/xool-setup.sh | bash -s -- --check\n\n' "$B" "$MODEL" "$N"
[ "$PROBLEMS" -eq 0 ] || exit 3
exit 0
