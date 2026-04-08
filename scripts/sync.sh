#!/bin/bash
# Sync-Script fuer vulkan-ed: Submodule + Superproject synchronisieren.
# Aufruf bei jedem PC-Wechsel oder vor/nach groesseren Arbeitsabschnitten.
#
# Usage:
#   ./scripts/sync.sh          # Pull: alles auf aktuellen Stand bringen
#   ./scripts/sync.sh --push   # Push: lokale Aenderungen hochladen
#   ./scripts/sync.sh --status # Status: nur pruefen, nichts aendern

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

OWN_SUBMODULES=("libs/gooey" "libs/wgpu_native_zig" "libs/wio")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}!!${NC}  $1"; }
err()  { echo -e "  ${RED}ERR${NC} $1"; }

get_default_branch() {
    local sub_path="$1"
    if git -C "$sub_path" rev-parse --verify origin/main &>/dev/null; then
        echo "main"
    else
        echo "master"
    fi
}

cmd_status() {
    echo "=== Superproject ==="
    local SUPER_STATUS
    SUPER_STATUS=$(git status --porcelain 2>/dev/null)
    if [[ -n "$SUPER_STATUS" ]]; then
        warn "Uncommitted changes:"
        echo "$SUPER_STATUS" | head -10
    else
        ok "Clean"
    fi

    local BEHIND AHEAD
    BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
    AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
    [[ "$BEHIND" != "0" ]] && warn "Behind origin/main by $BEHIND commits"
    [[ "$AHEAD" != "0" ]] && warn "Ahead of origin/main by $AHEAD commits"
    [[ "$BEHIND" == "0" && "$AHEAD" == "0" ]] && ok "Up to date with origin/main"

    echo ""
    echo "=== Submodule ==="
    ERRORS=0
    for SUB in "${OWN_SUBMODULES[@]}"; do
        SUB_PATH="$REPO_ROOT/$SUB"
        [[ -e "$SUB_PATH/.git" ]] || { warn "$SUB: not initialized"; continue; }

        local BRANCH
        BRANCH=$(get_default_branch "$SUB_PATH")

        local SUB_DIRTY SUB_UNPUSHED IS_DETACHED
        SUB_DIRTY=$(git -C "$SUB_PATH" status --porcelain 2>/dev/null)
        IS_DETACHED=$(git -C "$SUB_PATH" symbolic-ref HEAD 2>/dev/null || echo "detached")

        if [[ "$IS_DETACHED" == "detached" ]]; then
            # Detached HEAD: pruefen ob Commit auf Remote erreichbar ist
            local HEAD_SHA
            HEAD_SHA=$(git -C "$SUB_PATH" rev-parse HEAD)
            if git -C "$SUB_PATH" branch -r --contains "$HEAD_SHA" 2>/dev/null | grep -q "origin/"; then
                SUB_UNPUSHED=""
            else
                SUB_UNPUSHED="$HEAD_SHA (detached, not on remote)"
            fi
        else
            SUB_UNPUSHED=$(git -C "$SUB_PATH" log --oneline "origin/$BRANCH..HEAD" 2>/dev/null)
        fi

        if [[ -n "$SUB_DIRTY" ]]; then
            err "$SUB: uncommitted changes"
            ERRORS=1
        elif [[ -n "$SUB_UNPUSHED" ]]; then
            warn "$SUB: unpushed commits on $BRANCH"
            echo "$SUB_UNPUSHED" | sed 's/^/         /'
            ERRORS=1
        else
            ok "$SUB ($BRANCH)"
        fi
    done

    return $ERRORS
}

cmd_pull() {
    echo "=== Pull: Superproject ==="
    git fetch origin
    local BEHIND
    BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
    if [[ "$BEHIND" != "0" ]]; then
        git pull --no-recurse-submodules
        ok "Pulled $BEHIND commits"
    else
        ok "Already up to date"
    fi

    echo ""
    echo "=== Pull: Submodule ==="
    git submodule update --init --recursive
    ok "All submodules updated"

    echo ""
    cmd_status || true
}

cmd_push() {
    echo "=== Push: Submodule zuerst ==="
    for SUB in "${OWN_SUBMODULES[@]}"; do
        SUB_PATH="$REPO_ROOT/$SUB"
        [[ -e "$SUB_PATH/.git" ]] || continue

        local BRANCH
        BRANCH=$(get_default_branch "$SUB_PATH")

        local UNPUSHED
        UNPUSHED=$(git -C "$SUB_PATH" log --oneline "origin/$BRANCH..HEAD" 2>/dev/null)
        if [[ -n "$UNPUSHED" ]]; then
            git -C "$SUB_PATH" push origin "$BRANCH"
            ok "$SUB: pushed to $BRANCH"
        else
            ok "$SUB: nothing to push"
        fi
    done

    echo ""
    echo "=== Push: Superproject ==="
    local AHEAD
    AHEAD=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
    if [[ "$AHEAD" != "0" ]]; then
        git push
        ok "Pushed $AHEAD commits"
    else
        ok "Nothing to push"
    fi
}

case "${1:---pull}" in
    --status|-s) cmd_status ;;
    --push|-p)   cmd_push ;;
    --pull|*)    cmd_pull ;;
esac
