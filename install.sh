#!/usr/bin/env bash
# OMOS Installer — OpenClaw Mission Orchestration System
set -euo pipefail

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
CONFIG_DIR="$HOME/.openclaw"
TEMPLATE_DIR="$CONFIG_DIR/mc-templates"
ARCHITECT_WS="$CONFIG_DIR/workspace-mc-architect"

echo -e "${B}═══ OMOS Installer ═══${N}"
echo ""

# ─── 1. Prerequisites ───
echo -e "${C}[1/7] Checking prerequisites...${N}"

missing=()
command -v sqlite3 >/dev/null 2>&1 || missing+=("sqlite3")
command -v python3 >/dev/null 2>&1 || missing+=("python3")
command -v openclaw >/dev/null 2>&1 || missing+=("openclaw")

if [ ${#missing[@]} -gt 0 ]; then
  echo -e "${R}Missing:${N} ${missing[*]}"
  echo "Install them and re-run."
  exit 1
fi
echo -e "  ${G}OK${N} — sqlite3, python3, openclaw"

# ─── 2. Install mc CLI ───
echo -e "${C}[2/7] Installing mc CLI...${N}"

mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/mc" "$BIN_DIR/mc"
chmod +x "$BIN_DIR/mc"

# Copy schema.sql alongside mc for schema resolution
cp "$SCRIPT_DIR/schema.sql" "$BIN_DIR/schema.sql"

# Check PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo -e "  ${Y}Add to your shell profile:${N} export PATH=\"\$HOME/bin:\$PATH\""
else
  echo -e "  ${G}OK${N} — $BIN_DIR/mc"
fi

# ─── 3. Install setup_mission ───
echo -e "${C}[3/7] Installing setup_mission...${N}"

cp "$SCRIPT_DIR/tools/setup_mission.py" "$BIN_DIR/setup_mission"
chmod +x "$BIN_DIR/setup_mission"
echo -e "  ${G}OK${N} — $BIN_DIR/setup_mission"

# ─── 4. Install agent templates ───
echo -e "${C}[4/7] Installing agent templates...${N}"

mkdir -p "$TEMPLATE_DIR"
for tmpl in base.md researcher.md coder.md reviewer.md; do
  if [ -f "$SCRIPT_DIR/agents/templates/$tmpl" ]; then
    cp "$SCRIPT_DIR/agents/templates/$tmpl" "$TEMPLATE_DIR/$tmpl"
  fi
done
echo -e "  ${G}OK${N} — $TEMPLATE_DIR/"

# ─── 5. Register mc-architect agent ───
echo -e "${C}[5/7] Registering mc-architect agent...${N}"

mkdir -p "$ARCHITECT_WS"
cp "$SCRIPT_DIR/agents/architect/AGENTS.md" "$ARCHITECT_WS/AGENTS.md"

if openclaw agents list 2>/dev/null | grep -q "mc-architect"; then
  echo -e "  ${Y}mc-architect already registered${N}"
else
  openclaw agents add mc-architect \
    --workspace "$ARCHITECT_WS" \
    --non-interactive 2>/dev/null || {
    echo -e "  ${Y}Could not auto-register mc-architect.${N}"
    echo -e "  Register manually: openclaw agents add mc-architect --workspace $ARCHITECT_WS"
  }
  echo -e "  ${G}OK${N} — mc-architect registered"
fi

# ─── 6. Initialize default workspace ───
echo -e "${C}[6/7] Initializing default MC workspace...${N}"

"$BIN_DIR/mc" init 2>/dev/null || true

# ─── 7. Create default mission ───
echo -e "${C}[7/7] Creating default mission...${N}"

"$BIN_DIR/mc" mission create default -d "Default mission" 2>/dev/null || true

echo ""
echo -e "${G}═══ Installation complete ═══${N}"
echo ""
echo -e "  mc CLI:         ${C}$BIN_DIR/mc${N}"
echo -e "  setup_mission:  ${C}$BIN_DIR/setup_mission${N}"
echo -e "  Templates:      ${C}$TEMPLATE_DIR/${N}"
echo -e "  Architect:      ${C}$ARCHITECT_WS/AGENTS.md${N}"
echo ""
echo -e "${B}Next steps:${N}"
echo -e "  1. Ensure ${C}export PATH=\"\$HOME/bin:\$PATH\"${N} is in your shell profile"
echo -e "  2. Issue a mission:  ${C}openclaw agent --agent mc-architect -m \"<your mission>\"${N}"
echo ""
