#!/usr/bin/env zsh
# Silent setup script for demo.tape
# Called from VHS Hide block — sets up two throwaway git repos and sources w.zsh.
# VHS cwd is the repo root when invoked as: vhs demo/demo.tape

REPO_ROOT="$PWD"
DEMO_BASE=$(mktemp -d)

# ── Repo 1: api-service ───────────────────────────────────────────
cd "$DEMO_BASE"
git init api-service -b main -q
cd api-service
echo '# api-service' > README.md
mkdir -p src
echo 'package main' > src/main.go
git add .
git commit -q -m 'initial commit'

# ── Repo 2: web-app ───────────────────────────────────────────────
cd "$DEMO_BASE"
git init web-app -b main -q
cd web-app
echo '# web-app' > README.md
mkdir -p src
echo 'console.log("hello")' > src/index.js
git add .
git commit -q -m 'initial commit'

# Pre-create several worktrees in api-service so the switcher has
# something interesting to show across repos.
cd "$DEMO_BASE/api-service"
source "$REPO_ROOT/w.zsh"
w add feat/auth-tokens   >/dev/null 2>&1
w add feat/rate-limiting >/dev/null 2>&1
w add fix/memory-leak    >/dev/null 2>&1
cd "$DEMO_BASE/api-service"

# Pre-create a couple in web-app too
cd "$DEMO_BASE/web-app"
w add feat/dark-mode     >/dev/null 2>&1
w add feat/dashboard     >/dev/null 2>&1
cd "$DEMO_BASE/web-app"

# Land back in web-app main for the demo to start from
cd "$DEMO_BASE/web-app"
