#!/usr/bin/env bash
# =============================================================================
# IDEasy Docker Sandbox - local launcher (Docker Sandboxes `sbx` CLI)
# =============================================================================
# Runs an AI coding agent (default: Claude Code) inside an isolated MicroVM
# sandbox provided by Docker Sandboxes, using the `sbx` CLI.
#
# This is the "docker-sbx" flavour of the IDEasy Docker Sandbox solution.
# Instead of building a bespoke image (see the sibling
# feature/2573-AI-Sandbox-using-Docker-Sandboxes branch), it relies on the `sbx`
# CLI and its built-in agent images, so there is nothing to build and the whole
# thing runs locally on your machine for free.
#
# The git repository you pass (or the current repository) is bind-mounted
# read-write into the sandbox as its workspace. The agent's edits, `git commit`
# and pull requests therefore operate on your real repository, while the
# sandbox runtime is fully isolated (a disposable microVM) and never touches the
# host IDEasy installation.
#
# [EXPERIMENTAL] Targets technically skilled users. No warranty or support.
#
# Requirements (one-time, see https://docs.docker.com/ai/sandboxes/):
#   * a Docker engine with Hypervisor Platform for microVM isolation
#     (Docker Desktop / Rancher Desktop on Windows+macOS, KVM on Linux)
#   * `sbx login`  (a Docker account)
#   * `sbx policy init balanced`  (initialize the local network policy)
#
# Usage:
#   bash docker-sandbox/docker-sandbox.sh [options] [-- agent-args ...]
#
# Everything after `--` is forwarded to the agent (e.g. `-- -p "fix the test"`).
#
# NOTE: The option names below are fixed by the IDEasy engine's
# DockerSandboxCommandlet (`ide docker-sandbox`), which forwards arguments to
# this script and re-inserts `--` before the first argument that is not one of
# these known options. Keep them in sync.
# =============================================================================

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
AGENT="claude"                 # --agent: sbx built-in agent (claude, codex, ...)
REPO=""                        # --repo:  git repository to mount (default: auto)
IMAGE=""                       # --image: OCI image for the sandbox (default: sbx default)
CA_CERT_FILE=""                # --ca-cert: CA bundle to trust inside the sandbox
# API key for the agent. Shorthand --api-key; also read from the host env var
# IDEASY_SANDBOX_API_KEY (convenient for CI / a login script).
API_KEY="${IDEASY_SANDBOX_API_KEY:-}"
ENV_VARS=()                    # --env: repeatable NAME=VALUE for the agent
PULL=0                         # --pull: start a fresh sandbox and pull the latest image
CHECK=0                        # --check: validate the host and exit (no run)
DRY_RUN=0                      # --dry-run: print the exact `sbx run` command and exit
AGENT_ARGS=()                  # everything after `--`

# The workspace inside the sandbox where the CA bundle (if any) is placed.
CA_SANDBOX_PATH="/sbx/ca-bundle.crt"

# Disable MSYS/Git-Bash argument path conversion for this process so that the
# Windows-native paths we pass to `sbx` (C:/...) are not rewritten. Harmless
# outside MSYS2.
export MSYS_NO_PATHCONV=1

# --- Colored output helpers (mirror the repository install.sh style) ----------
if [ -t 1 ]; then
  RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; BLUE=$'\033[1;34m'; YELLOW=$'\033[1;33m'; OFF=$'\033[0m'
else
  RED=""; GREEN=""; BLUE=""; YELLOW=""; OFF=""
fi
red()    { printf '%sError: %s%s\n' "$RED" "$1" "$OFF" >&2; }
green()  { printf '%s%s%s\n' "$GREEN" "$1" "$OFF"; }
blue()   { printf '%s%s%s\n' "$BLUE" "$1" "$OFF"; }
yellow() { printf '%s%s%s\n' "$YELLOW" "$1" "$OFF"; }

usage() {
  cat <<'USAGE'
IDEasy Docker Sandbox - local launcher (Docker Sandboxes `sbx` CLI)

Runs an AI coding agent (default: Claude Code) inside an isolated MicroVM
sandbox, bind-mounting your git repository as the sandbox workspace.

Usage:
  bash docker-sandbox/docker-sandbox.sh [options] [-- agent-args ...]

Options:
  --repo <path>         Git repository to mount as the workspace (default: the
                        repository of the current directory, else the current
                        directory itself).
  --image <ref>         OCI image reference for the sandbox (default: the
                        sbx agent-specific image).
  --agent <name>        Agent to run (default: claude). sbx built-in agents:
                        claude, codex, copilot, cursor, devin, docker-agent,
                        droid, kiro, opencode, shell.
  --pull                Start a FRESH sandbox and pull the latest image (by
                        default `sbx run` re-attaches to an existing sandbox
                        for the same agent/workspace).
  --check               Validate the host (sbx CLI, daemon, login, network
                        policy, workspace) and exit - do not start anything.
  --dry-run             Validate and print the exact `sbx run` command, then
                        exit - do not start the sandbox.
  --ca-cert <file>      CA bundle to trust inside the sandbox (e.g. a corporate
                        proxy CA). Mounted read-only and exported as
                        NODE_EXTRA_CA_CERTS / SSL_CERT_FILE. Always starts a
                        FRESH sandbox: a workspace mount can only be attached at
                        sandbox creation, so --ca-cert cannot re-attach.
  --api-key <value>     API key for the agent (default: Anthropic), passed as
                        ANTHROPIC_API_KEY. Also read from the host
                        IDEASY_SANDBOX_API_KEY env var.
  --env NAME=VALUE      Extra environment variable for the agent (repeatable),
                        e.g. --env ANTHROPIC_BASE_URL=https://proxy.
  -h | --help           Show this help.

Everything after `--` is forwarded to the agent.

Examples:
  bash docker-sandbox/docker-sandbox.sh
  bash docker-sandbox/docker-sandbox.sh --agent codex -- -p "run the tests"
  bash docker-sandbox/docker-sandbox.sh --dry-run
  ide docker-sandbox                       (via the IDEasy commandlet)

Sandbox management (done by sbx directly):
  sbx ls                 list sandboxes
  sbx exec -it <name> bash   attach a shell to a running sandbox
  sbx rm <name>          remove a sandbox
  sbx prune              remove all stopped sandboxes

One-time prerequisites (see https://docs.docker.com/ai/sandboxes/):
  sbx login
  sbx policy init balanced
USAGE
}

# --- Argument parsing --------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      REPO="${2:?--repo requires a value}"; shift 2 ;;
    --image)     IMAGE="${2:?--image requires a value}"; shift 2 ;;
    --agent)     AGENT="${2:?--agent requires a value}"; shift 2 ;;
    --ca-cert)   CA_CERT_FILE="${2:?--ca-cert requires a value}"; shift 2 ;;
    --api-key)   API_KEY="${2:?--api-key requires a value}"; shift 2 ;;
    --env)       ENV_VARS+=("${2:?--env requires NAME=VALUE}"); shift 2 ;;
    --pull)      PULL=1; shift ;;
    --check)     CHECK=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; AGENT_ARGS=("$@"); break ;;
    *)           red "Unknown option: $1"; usage >&2; exit 2 ;;
  esac
done

# --- Helpers -----------------------------------------------------------------
# Convert a host path to the OS-native form the `sbx` CLI expects, resolving it
# to an absolute path. On Git Bash/MSYS2 this turns /c/Users/... into C:/...;
# on Linux/macOS the path is returned as-is.
to_sb_path() {
  local p="$1"
  if [ ! -e "$p" ]; then
    red "Path does not exist: $p"
    return 1
  fi
  if [ -d "$p" ]; then
    p="$(cd "$p" && pwd)"
  else
    p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  fi
  if [ -n "${MSYSTEM:-}" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
  else
    printf '%s' "$p"
  fi
}

# Resolve the workspace to mount: an explicit --repo, else the toplevel of the
# current git working tree, else the current directory.
resolve_workspace() {
  if [ -n "$REPO" ]; then
    WORKSPACE="$REPO"
  else
    local toplevel
    if toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"; then
      WORKSPACE="$toplevel"
    else
      WORKSPACE="$(pwd)"
    fi
  fi
  WORKSPACE_SB="$(to_sb_path "$WORKSPACE")"
}

sbx_available() {
  command -v sbx >/dev/null 2>&1
}

# If `sbx` is not on PATH (e.g. the current shell predates the `winget`/`brew`
# install, which adds the bin dir to PATH for *new* shells), prepend the standard
# install locations so the rest of the script can find it. Returns 0 when sbx is
# now resolvable.
resolve_sbx() {
  sbx_available && return 0
  local candidates=()
  [ -n "${LOCALAPPDATA:-}" ] && candidates+=("$LOCALAPPDATA/DockerSandboxes/bin")
  [ -n "${PROGRAMFILES:-}" ] && candidates+=("$PROGRAMFILES/DockerSandboxes/bin")
  candidates+=("$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin")
  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c/sbx" ] || [ -x "$c/sbx.exe" ]; then
      case ":$PATH:" in *":$c:"*) ;; *) export PATH="$c:$PATH";; esac
      return 0
    fi
  done
  return 1
}

# Validate the host. Each prerequisite is checked independently so the user
# sees a full picture. Returns 0 only when every prerequisite is satisfied.
run_checks() {
  local failures=0
  blue "IDEasy Docker Sandbox - host check"
  printf '  %-22s' "sbx CLI:"
  if sbx_available; then
    green "found ($(sbx --version 2>/dev/null | head -1 || echo sbx))"
  else
    red "not found."
    yellow "  Install:  winget install Docker.sbx   (Windows)"
    yellow "            brew install docker/tap/sbx (macOS)"
    yellow "            curl -fsSL https://get.docker.com | sudo SBX=1 sh   (Linux)"
    failures=$((failures + 1))
  fi

  if sbx_available; then
    printf '  %-22s' "sbx daemon:"
    if sbx settings ls >/dev/null 2>&1; then
      green "reachable"
    else
      red "not reachable."
      yellow "  Start your Docker engine, then: sbx daemon restart"
      failures=$((failures + 1))
    fi

    # Sign-in is only meaningful once the daemon is up.
    printf '  %-22s' "Docker login:"
    local ls_out
    if ls_out="$(sbx --no-input ls 2>&1)"; then
      green "signed in"
    elif printf '%s' "$ls_out" | grep -qi 'not signed in'; then
      red "not signed in."
      yellow "  Run:  sbx login"
      failures=$((failures + 1))
    else
      red "could not list sandboxes: $ls_out"
      failures=$((failures + 1))
    fi

    printf '  %-22s' "network policy:"
    if sbx --no-input policy ls >/dev/null 2>&1; then
      green "initialized"
    else
      red "not initialized."
      yellow "  Run once:  sbx policy init balanced"
      failures=$((failures + 1))
    fi

    printf '  %-22s' "workspace:"
    if [ -n "${WORKSPACE:-}" ]; then
      green "$WORKSPACE"
    else
      yellow "(auto-detected: current git repository or directory)"
    fi
  fi

  echo ""
  if [ "$failures" -gt 0 ]; then
    red "Check FAILED: $failures prerequisite(s) not satisfied (see above)."
    return 1
  fi
  green "Check passed. All prerequisites are satisfied."
  return 0
}

# Build the `sbx run` command as an array. Fills the global SBX_CMD.
build_sbx_cmd() {
  SBX_CMD=(sbx run)

  # Image override.
  if [ -n "$IMAGE" ]; then
    SBX_CMD+=(--image "$IMAGE")
  fi

  # A run starts a FRESH, disposable sandbox (latest image, removed on exit)
  # when --pull is given, and *always* when --ca-cert is used: the CA bundle is
  # a workspace mount, and sbx only allows attaching a workspace at sandbox
  # *creation* - it refuses to add a workspace to an already-existing sandbox
  # ("...already exists and can't be given new workspaces"). A --ca-cert run
  # therefore cannot re-attach to a previous sandbox and always creates its own.
  FRESH=0
  [ "$PULL" -eq 1 ] && FRESH=1
  [ -n "$CA_CERT_FILE" ] && FRESH=1
  if [ "$FRESH" -eq 1 ]; then
    SBX_CMD+=(--name "sbx-$(date +%Y%m%d-%H%M%S)" --pull always --rm)
  fi

  # Environment for the agent. The API key is a shorthand for the ANTHROPIC_*
  # env var; --env adds arbitrary ones (e.g. ANTHROPIC_BASE_URL for a proxy).
  if [ -n "$API_KEY" ]; then
    SBX_CMD+=(-e "ANTHROPIC_API_KEY=$API_KEY")
  fi
  local kv
  for kv in "${ENV_VARS[@]}"; do
    SBX_CMD+=(-e "$kv")
  done

  # CA bundle: mount read-only at a fixed in-sandbox path and point the agent's
  # TLS libraries at it. Best-effort - honoured by Node-based agents (Claude
  # Code) via NODE_EXTRA_CA_CERTS and by OpenSSL via SSL_CERT_FILE.
  if [ -n "$CA_CERT_FILE" ]; then
    CA_MOUNT="$(to_sb_path "$CA_CERT_FILE"):${CA_SANDBOX_PATH}:ro"
    SBX_CMD+=(-e "NODE_EXTRA_CA_CERTS=${CA_SANDBOX_PATH}" -e "SSL_CERT_FILE=${CA_SANDBOX_PATH}")
  fi

  # Agent (first positional of `sbx run`).
  SBX_CMD+=("$AGENT")

  # Workspace (explicit, so the agent works on the mounted repository).
  SBX_CMD+=("$WORKSPACE_SB")

  # Optional CA mount as an extra read-only workspace.
  if [ -n "${CA_MOUNT:-}" ]; then
    SBX_CMD+=("$CA_MOUNT")
  fi

  # Agent arguments (only if there are any - `--` with nothing after is noise).
  if [ ${#AGENT_ARGS[@]} -gt 0 ]; then
    SBX_CMD+=(-- "${AGENT_ARGS[@]}")
  fi
}

print_plan() {
  build_sbx_cmd
  echo ""
  blue "IDEasy Docker Sandbox (docker-sbx, experimental) - plan"
  echo "  Agent           : ${AGENT}"
  echo "  Workspace       : ${WORKSPACE}  ->  ${WORKSPACE_SB}"
  echo "  Image           : ${IMAGE:-<sbx agent default>}"
  local fresh_reason=""
  [ "$PULL" -eq 1 ] && fresh_reason="--pull"
  [ -n "$CA_CERT_FILE" ] && fresh_reason="${fresh_reason:+$fresh_reason+}--ca-cert (creation-time mount)"
  echo "  Fresh sandbox   : $([ -n "$fresh_reason" ] && echo "yes (${fresh_reason}, latest image, removed on exit)" || echo 'no (re-attach if one exists for this agent/workspace)')"
  echo "  API key         : $([ -n "$API_KEY" ] && echo 'present (value hidden)' || echo '<none>')"
  local envnames=()
  local kv
  for kv in "${ENV_VARS[@]}"; do envnames+=("${kv%%=*}"); done
  echo "  Agent env vars  : $([ ${#envnames[@]} -gt 0 ] && printf '%s' "${envnames[*]}" || echo '<none>')"
  echo "  CA cert         : ${CA_CERT_FILE:-<none>}"
  echo "  Agent args      : ${AGENT_ARGS[*]:-<none>}"
  echo ""
  echo "  Command:"
  local -a q=()
  for t in "${SBX_CMD[@]}"; do q+=("$(printf '%q' "$t")"); done
  echo "    ${q[*]}"
  echo ""
  blue "Notes (see the README.adoc in this folder):"
  echo "  * Only the workspace is mounted; the host IDEasy installation is untouched."
  echo "  * Push / PR auth from inside the sandbox is an explicit concern - store it with"
  echo "    'sbx secret set github --command \"gh auth token\"' (see the docs)."
}

# --- Main --------------------------------------------------------------------
main() {
  blue "IDEasy Docker Sandbox (docker-sbx, experimental)"

  # Make `sbx` resolvable even if the current shell's PATH predates the install.
  resolve_sbx

  # Resolve the workspace up front so --check / --dry-run can report on it.
  resolve_workspace

  if [ "$CHECK" -eq 1 ]; then
    if run_checks; then
      print_plan
      green "Check passed. (No sandbox was started.)"
      exit 0
    else
      exit 1
    fi
  fi

  # A real (or dry-run) invocation still wants to warn about missing prereqs,
  # but a stopped daemon / missing login is only fatal when actually running.
  if [ "$DRY_RUN" -eq 0 ]; then
    run_checks || {
      red "Prerequisites not satisfied. Fix them (see above) and retry."
      red "Tip: run with --check to re-validate, or --dry-run to preview the command."
      exit 1
    }
  fi

  build_sbx_cmd

  if [ "$DRY_RUN" -eq 1 ]; then
    print_plan
    green "Dry run complete. No sandbox was started."
    exit 0
  fi

  exec "${SBX_CMD[@]}"
}

main
