#!/bin/bash
# rec setup — one-command install on a fresh Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/brunoqgalvao/rec/main/setup.sh | bash
#
# or from a clone: ./setup.sh
#
# Idempotent: re-running rebuilds/reinstalls and leaves existing config alone.
set -euo pipefail

REPO_URL="https://github.com/brunoqgalvao/rec.git"
CLONE_DIR="${REC_DIR:-$HOME/Code/rec}"

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

# When piped (curl | bash) stdin is the script; reattach to the terminal so
# prompts work. If there is no terminal at all, run non-interactively.
INTERACTIVE=1
if [ ! -t 0 ]; then
  if [ -e /dev/tty ] && exec </dev/tty 2>/dev/null; then :; else INTERACTIVE=0; fi
fi

[ "$(uname)" = "Darwin" ] || { echo "rec is macOS-only (system audio capture, menu bar app)." >&2; exit 1; }

if ! xcode-select -p >/dev/null 2>&1; then
  step "Xcode Command Line Tools are required — starting the installer"
  xcode-select --install || true
  echo "Re-run this script once the installation finishes."
  exit 1
fi

# Run from inside a checkout when we're in one, otherwise clone (or update) CLONE_DIR.
if [ -f Makefile ] && grep -q '^APP = rec.app$' Makefile 2>/dev/null; then
  SRC_DIR="$(pwd)"
else
  step "Fetching source → $CLONE_DIR"
  if [ -d "$CLONE_DIR/.git" ]; then
    git -C "$CLONE_DIR" pull --ff-only || echo "(pull failed — using the existing checkout as-is)"
  else
    git clone "$REPO_URL" "$CLONE_DIR"
  fi
  SRC_DIR="$CLONE_DIR"
fi
cd "$SRC_DIR"

step "Building and installing rec.app → /Applications"
make install-app

step "Installing the rec CLI → /usr/local/bin (asks for sudo)"
sudo make install

# Claude Code skill: symlink so the skill tracks the repo.
SKILL_LINK="$HOME/.claude/skills/rec"
if [ -d "$HOME/.claude" ]; then
  step "Installing the Claude Code skill (/rec)"
  mkdir -p "$HOME/.claude/skills"
  if [ -e "$SKILL_LINK" ] && [ ! -L "$SKILL_LINK" ]; then
    mv "$SKILL_LINK" "$SKILL_LINK.bak"
    echo "Existing skill moved to $SKILL_LINK.bak"
  fi
  ln -sfn "$SRC_DIR/skills/rec" "$SKILL_LINK"
  echo "~/.claude/skills/rec → $SRC_DIR/skills/rec"
fi

# Transcription engine: AssemblyAI key, or the local whisper.cpp fallback.
CONFIG="$HOME/.rec"
if [ -f "$CONFIG" ] && grep -q '^ASSEMBLYAI_API_KEY=' "$CONFIG"; then
  step "Transcription: keeping the existing AssemblyAI key in ~/.rec"
elif [ "$INTERACTIVE" = 1 ]; then
  step "Transcription engine"
  printf 'AssemblyAI API key (Enter to skip and use the local engine): '
  read -r KEY || KEY=""
  if [ -n "$KEY" ]; then
    printf 'Language code [pt]: '
    read -r LANG_CODE || LANG_CODE=""
    { echo "ASSEMBLYAI_API_KEY=$KEY"
      echo "ENGINE=assemblyai"
      echo "LANGUAGE=${LANG_CODE:-pt}"
    } >> "$CONFIG"
    echo "Wrote ~/.rec (ENGINE=assemblyai)"
  else
    printf 'Set up the local engine now? Installs whisper-cpp and downloads a ~550MB model. [Y/n] '
    read -r LOCAL || LOCAL=""
    if [ "$LOCAL" != "n" ] && [ "$LOCAL" != "N" ]; then
      command -v brew >/dev/null 2>&1 || { echo "Homebrew not found — install it from https://brew.sh and re-run." >&2; exit 1; }
      brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
      PATH="/usr/local/bin:$PATH" rec setup-local
      echo "ENGINE=local" >> "$CONFIG"
      echo "Wrote ~/.rec (ENGINE=local)"
    else
      echo "Skipped. Add ASSEMBLYAI_API_KEY to ~/.rec, or run: brew install whisper-cpp && rec setup-local"
    fi
  fi
else
  step "No terminal — skipping engine setup (add ASSEMBLYAI_API_KEY to ~/.rec, or run rec setup-local)"
fi

step "Launching rec"
open -a rec || open /Applications/rec.app

step "Status (rec check)"
PATH="/usr/local/bin:$PATH" rec check || true

cat <<'EOF'

Done. Next steps:
  1. Grant Microphone and Screen Recording when macOS asks (rec's Settings
     window shows both with live status).
  2. Record a test meeting, then: rec show latest
EOF
