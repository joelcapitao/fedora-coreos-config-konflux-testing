#!/bin/bash
# sync-upstream.sh
#
# Syncs this repository from upstream coreos/fedora-coreos-config
# while preserving local .tekton/ and .github/ directories.
#
# This script only lives on the testing-devel branch (source of truth).
# Other branches are synced without this script.
#
# Usage:
#   ./sync-upstream.sh                     # Sync all configured branches
#   ./sync-upstream.sh <branch>            # Sync a specific branch
#   ./sync-upstream.sh --list              # List available branches
#
# Configured branches: testing-devel, next-devel, rawhide

set -euo pipefail

UPSTREAM_REPO="https://github.com/coreos/fedora-coreos-config.git"
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"

# Branch where this script lives (source of truth)
SCRIPT_SOURCE_BRANCH="testing-devel"
SCRIPT_NAME="sync-upstream.sh"

# Branches to sync (can be overridden via command line)
DEFAULT_BRANCHES=("testing-devel" "next-devel" "rawhide")

# Files/directories to preserve during sync (not overwritten by upstream)
PRESERVE_PATHS=(".tekton" ".github")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [BRANCH...]

Sync this repository from upstream coreos/fedora-coreos-config
while preserving local files (.tekton/, .github/).

This script only exists on $SCRIPT_SOURCE_BRANCH (source of truth).
Other branches are synced from upstream without this script.

Options:
  -h, --help     Show this help message
  -l, --list     List configured branches
  -n, --dry-run  Show what would be done without making changes
  -f, --force    Skip confirmation prompts

Branches:
  If no branch is specified, all configured branches will be synced:
  ${DEFAULT_BRANCHES[*]}

Preserved paths (not overwritten by upstream):
  ${PRESERVE_PATHS[*]}
  $SCRIPT_NAME (only on $SCRIPT_SOURCE_BRANCH)

Examples:
  $(basename "$0")                  # Sync all branches
  $(basename "$0") testing-devel    # Sync only testing-devel
  $(basename "$0") -n               # Dry run for all branches
EOF
}

list_branches() {
    echo "Configured branches to sync:"
    for branch in "${DEFAULT_BRANCHES[@]}"; do
        if [[ "$branch" == "$SCRIPT_SOURCE_BRANCH" ]]; then
            echo "  - $branch (has $SCRIPT_NAME)"
        else
            echo "  - $branch"
        fi
    done
    echo ""
    echo "Upstream remote: $UPSTREAM_REPO"
    echo ""
    echo "Preserved paths (not overwritten by upstream):"
    for path in "${PRESERVE_PATHS[@]}"; do
        echo "  - $path"
    done
    echo "  - $SCRIPT_NAME (only on $SCRIPT_SOURCE_BRANCH)"
}

# Check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not in a git repository"
        exit 1
    fi
}

# Check for uncommitted changes
check_clean_worktree() {
    local status
    status=$(git status --porcelain 2>/dev/null)
    if [[ -n "$status" ]]; then
        log_error "You have uncommitted changes. Please commit or stash them first."
        git status --short
        exit 1
    fi
}

# Setup upstream remote if not present
setup_upstream_remote() {
    if git remote get-url "$UPSTREAM_REMOTE" > /dev/null 2>&1; then
        local current_url
        current_url=$(git remote get-url "$UPSTREAM_REMOTE")
        if [[ "$current_url" != "$UPSTREAM_REPO" ]]; then
            log_warn "Upstream remote exists but points to different URL: $current_url"
            log_info "Updating upstream remote to: $UPSTREAM_REPO"
            git remote set-url "$UPSTREAM_REMOTE" "$UPSTREAM_REPO"
        else
            log_info "Upstream remote already configured"
        fi
    else
        log_info "Adding upstream remote: $UPSTREAM_REPO"
        git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_REPO"
    fi
}

# Fetch from upstream
fetch_upstream() {
    log_info "Fetching from upstream..."
    if ! git fetch "$UPSTREAM_REMOTE"; then
        log_error "Failed to fetch from upstream"
        exit 1
    fi
    log_success "Fetched upstream successfully"
}

# Sync a single branch
sync_branch() {
    local branch="$1"
    local dry_run="${2:-false}"
    local canonical_script="$3"
    local backup_dir=""
    local has_preserved_content=false

    log_info "========================================="
    log_info "Syncing branch: $branch"
    log_info "========================================="

    # Verify upstream branch exists
    if ! git rev-parse --verify "$UPSTREAM_REMOTE/$branch" > /dev/null 2>&1; then
        log_error "Branch '$branch' does not exist in upstream"
        return 1
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[DRY-RUN] Would sync $branch from upstream"
        return 0
    fi

    # Check if local branch exists
    local local_branch_exists=false
    if git rev-parse --verify "$branch" > /dev/null 2>&1; then
        local_branch_exists=true
    fi

    # If local branch exists, check out and backup preserved paths
    if [[ "$local_branch_exists" == "true" ]]; then
        log_info "Checking out existing branch: $branch"
        git checkout "$branch"

        # Backup preserved paths if they exist
        backup_dir=$(mktemp -d)
        for path in "${PRESERVE_PATHS[@]}"; do
            if [[ -e "$path" ]]; then
                log_info "Backing up $path to $backup_dir"
                cp -a "$path" "$backup_dir/"
                has_preserved_content=true
            fi
        done

        # Hard reset to upstream
        log_info "Resetting to upstream/$branch..."
        git reset --hard "$UPSTREAM_REMOTE/$branch"
    else
        # Create new branch from upstream
        log_info "Creating new branch: $branch from upstream/$branch"
        git checkout -b "$branch" "$UPSTREAM_REMOTE/$branch"
        
        backup_dir=$(mktemp -d)
    fi

    # Remove upstream's versions of preserved paths (we want our own)
    for path in "${PRESERVE_PATHS[@]}"; do
        if [[ -e "$path" ]]; then
            log_info "Removing upstream's $path"
            rm -rf "$path"
        fi
    done

    # Restore preserved paths if we had them
    if [[ "$has_preserved_content" == "true" ]]; then
        log_info "Restoring preserved local content"
        for path in "${PRESERVE_PATHS[@]}"; do
            if [[ -e "$backup_dir/$path" ]]; then
                log_info "Restoring $path"
                cp -a "$backup_dir/$path" "./"
            fi
        done
    fi

    # Cleanup backup
    if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
        rm -rf "$backup_dir"
    fi

    # Handle sync-upstream.sh: only on source branch
    if [[ "$branch" == "$SCRIPT_SOURCE_BRANCH" ]]; then
        # On source branch: restore the script
        if [[ -e "$SCRIPT_NAME" ]]; then
            rm -f "$SCRIPT_NAME"
        fi
        if [[ -n "$canonical_script" && -f "$canonical_script" ]]; then
            cp "$canonical_script" "$SCRIPT_NAME"
            chmod +x "$SCRIPT_NAME"
            log_info "Restored $SCRIPT_NAME"
        fi
    else
        # On other branches: remove the script if it exists
        if [[ -e "$SCRIPT_NAME" ]]; then
            log_info "Removing $SCRIPT_NAME (only lives on $SCRIPT_SOURCE_BRANCH)"
            rm -f "$SCRIPT_NAME"
        fi
    fi

    # Stage and commit any changes
    git add -A
    if ! git diff --cached --quiet; then
        local commit_msg="Sync from upstream

Synced from: $UPSTREAM_REPO
Branch: $branch
Upstream commit: $(git rev-parse "$UPSTREAM_REMOTE/$branch")"

        git commit -m "$commit_msg"
        log_success "Committed sync changes"
    else
        log_info "No changes to commit"
    fi

    # Push to origin
    log_info "Pushing $branch to origin..."
    if git push -u "$ORIGIN_REMOTE" "$branch" --force-with-lease; then
        log_success "Pushed $branch to origin"
    else
        log_warn "Failed to push $branch - you may need to push manually"
    fi

    log_success "Branch $branch synced successfully"
    return 0
}

# Main function
main() {
    local dry_run=false
    local force=false
    local branches=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                list_branches
                exit 0
                ;;
            -n|--dry-run)
                dry_run=true
                shift
                ;;
            -f|--force)
                force=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                branches+=("$1")
                shift
                ;;
        esac
    done

    # Use default branches if none specified
    if [[ ${#branches[@]} -eq 0 ]]; then
        branches=("${DEFAULT_BRANCHES[@]}")
    fi

    # Validate we're in a git repo
    check_git_repo

    # Check for clean worktree (skip in dry-run)
    if [[ "$dry_run" != "true" ]]; then
        # Only check if there are commits (empty repo has no HEAD)
        if git rev-parse HEAD > /dev/null 2>&1; then
            check_clean_worktree
        fi
    fi

    # Show what we're about to do
    echo ""
    log_info "Upstream repository: $UPSTREAM_REPO"
    log_info "Branches to sync: ${branches[*]}"
    log_info "Preserved paths: ${PRESERVE_PATHS[*]}"
    log_info "Script lives on: $SCRIPT_SOURCE_BRANCH only"
    if [[ "$dry_run" == "true" ]]; then
        log_warn "DRY-RUN MODE - no changes will be made"
    fi
    echo ""

    # Confirm unless force mode
    if [[ "$dry_run" != "true" && "$force" != "true" ]]; then
        read -p "Continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    # Setup and fetch upstream
    setup_upstream_remote
    fetch_upstream

    # Save original branch to return to
    local original_branch=""
    if git symbolic-ref --short HEAD > /dev/null 2>&1; then
        original_branch=$(git symbolic-ref --short HEAD)
    fi

    # Save the canonical version of the script BEFORE any sync
    local canonical_script=""
    canonical_script=$(mktemp)
    if [[ -f "$SCRIPT_NAME" ]]; then
        cp "$SCRIPT_NAME" "$canonical_script"
    elif git show "$SCRIPT_SOURCE_BRANCH:$SCRIPT_NAME" > "$canonical_script" 2>/dev/null; then
        : # Got it from git
    elif git show "$ORIGIN_REMOTE/$SCRIPT_SOURCE_BRANCH:$SCRIPT_NAME" > "$canonical_script" 2>/dev/null; then
        : # Got it from origin
    else
        log_error "Cannot find $SCRIPT_NAME - are you on $SCRIPT_SOURCE_BRANCH?"
        exit 1
    fi

    # Ensure source branch is synced first
    local ordered_branches=()
    for branch in "${branches[@]}"; do
        if [[ "$branch" == "$SCRIPT_SOURCE_BRANCH" ]]; then
            ordered_branches=("$branch" "${ordered_branches[@]}")
        else
            ordered_branches+=("$branch")
        fi
    done

    # Sync each branch
    local failed_branches=()
    for branch in "${ordered_branches[@]}"; do
        if ! sync_branch "$branch" "$dry_run" "$canonical_script"; then
            failed_branches+=("$branch")
        fi
    done

    # Cleanup canonical script temp file
    if [[ -n "$canonical_script" && -f "$canonical_script" ]]; then
        rm -f "$canonical_script"
    fi

    # Return to original branch if possible
    if [[ -n "$original_branch" ]] && git rev-parse --verify "$original_branch" > /dev/null 2>&1; then
        git checkout "$original_branch" 2>/dev/null || true
    fi

    # Summary
    echo ""
    log_info "========================================="
    log_info "Sync Summary"
    log_info "========================================="

    if [[ ${#failed_branches[@]} -eq 0 ]]; then
        log_success "All branches synced successfully!"
    else
        log_error "Failed to sync branches: ${failed_branches[*]}"
        exit 1
    fi
}

main "$@"
