#!/bin/bash
# sync-upstream.sh
#
# Syncs this repository from upstream coreos/fedora-coreos-config
# by rebasing local commits on top of upstream changes.
#
# Preserved paths (.tekton/, .github/) are kept during rebase.
# This script only lives on the testing-devel branch (source of truth).
# Other branches are synced without this script.
#
# Usage:
#   ./sync-upstream.sh                     # Sync all configured branches
#   ./sync-upstream.sh <branch>            # Sync a specific branch
#   ./sync-upstream.sh --list              # List available branches
#
# Configured branches: testing-devel, rawhide

set -euo pipefail

UPSTREAM_REPO="https://github.com/coreos/fedora-coreos-config.git"
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"

# Branch where this script lives (source of truth)
SCRIPT_SOURCE_BRANCH="testing-devel"
SCRIPT_NAME="sync-upstream.sh"

# Branches to sync (can be overridden via command line)
DEFAULT_BRANCHES=("testing-devel" "rawhide")

# Files/directories to preserve during sync (not overwritten by upstream)
PRESERVE_PATHS=(".tekton" ".github" "README.md")

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
by rebasing local commits on top of upstream changes.
Preserves local files (.tekton/, .github/).

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

# Get the merge base between local branch and upstream
get_merge_base() {
    local branch="$1"
    git merge-base "$branch" "$UPSTREAM_REMOTE/$branch" 2>/dev/null
}

# Get local commits that are not in upstream (commits to rebase)
get_local_commits() {
    local branch="$1"
    git rev-list "$UPSTREAM_REMOTE/$branch..$branch" 2>/dev/null
}

# Resolve conflicts in preserved paths by keeping our version
resolve_preserved_path_conflicts() {
    local backup_dir="$1"
    
    for path in "${PRESERVE_PATHS[@]}"; do
        if [[ -e "$backup_dir/$path" ]]; then
            # Remove whatever is there (conflict or upstream version)
            rm -rf "$path"
            # Restore our version
            cp -a "$backup_dir/$path" "./"
            git add "$path"
        fi
    done
}

# Sync a single branch using rebase
sync_branch() {
    local branch="$1"
    local dry_run="${2:-false}"
    local canonical_script="$3"
    local backup_dir=""

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

    if [[ "$local_branch_exists" == "false" ]]; then
        # Create new branch from upstream
        log_info "Creating new branch: $branch from upstream/$branch"
        git checkout -b "$branch" "$UPSTREAM_REMOTE/$branch"
        
        # Remove upstream's preserved paths if they exist
        local needs_commit=false
        for path in "${PRESERVE_PATHS[@]}"; do
            if [[ -e "$path" ]]; then
                log_info "Removing upstream's $path"
                rm -rf "$path"
                needs_commit=true
            fi
        done

        # Handle sync-upstream.sh on source branch
        if [[ "$branch" == "$SCRIPT_SOURCE_BRANCH" ]]; then
            if [[ -n "$canonical_script" && -f "$canonical_script" ]]; then
                cp "$canonical_script" "$SCRIPT_NAME"
                chmod +x "$SCRIPT_NAME"
                git add "$SCRIPT_NAME"
                log_info "Added $SCRIPT_NAME"
                needs_commit=true
            fi
        fi

        if [[ "$needs_commit" == "true" ]]; then
            git add -A
            git commit -m "Initial setup: remove upstream paths, add local files

Branch: $branch
Upstream commit: $(git rev-parse "$UPSTREAM_REMOTE/$branch")"
            log_success "Created initial local commit"
        fi
    else
        # Branch exists - rebase local commits on top of upstream
        log_info "Checking out existing branch: $branch"
        git checkout "$branch"

        # Check if there are local commits to rebase
        local local_commits
        local_commits=$(get_local_commits "$branch")
        
        if [[ -z "$local_commits" ]]; then
            log_info "No local commits to rebase, fast-forwarding..."
            git reset --hard "$UPSTREAM_REMOTE/$branch"
        else
            local commit_count
            commit_count=$(echo "$local_commits" | wc -l)
            log_info "Found $commit_count local commit(s) to rebase"

            # Backup preserved paths before rebase
            backup_dir=$(mktemp -d)
            for path in "${PRESERVE_PATHS[@]}"; do
                if [[ -e "$path" ]]; then
                    log_info "Backing up $path"
                    cp -a "$path" "$backup_dir/"
                fi
            done
            # Also backup the script on source branch
            if [[ "$branch" == "$SCRIPT_SOURCE_BRANCH" && -f "$SCRIPT_NAME" ]]; then
                cp -a "$SCRIPT_NAME" "$backup_dir/"
            fi

            # Attempt rebase
            log_info "Rebasing local commits onto upstream/$branch..."
            if ! GIT_EDITOR=true git rebase "$UPSTREAM_REMOTE/$branch" 2>/dev/null; then
                log_warn "Rebase conflict detected, resolving..."
                
                # Handle conflicts by keeping our preserved paths
                while true; do
                    # Resolve conflicts in preserved paths
                    resolve_preserved_path_conflicts "$backup_dir"
                    
                    # For other conflicts, accept upstream version
                    local conflicted_files
                    conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)
                    if [[ -n "$conflicted_files" ]]; then
                        for file in $conflicted_files; do
                            # Check if it's a preserved path (already handled above)
                            local is_preserved=false
                            for path in "${PRESERVE_PATHS[@]}"; do
                                if [[ "$file" == "$path"* ]]; then
                                    is_preserved=true
                                    break
                                fi
                            done
                            if [[ "$is_preserved" == "false" && "$file" != "$SCRIPT_NAME" ]]; then
                                log_info "Accepting upstream version for: $file"
                                git checkout --theirs "$file" 2>/dev/null || true
                                git add "$file" 2>/dev/null || true
                            fi
                        done
                    fi

                    # Continue rebase
                    if GIT_EDITOR=true git rebase --continue 2>/dev/null; then
                        break
                    fi
                    
                    # Check if rebase is still in progress
                    if [[ ! -d "$(git rev-parse --git-dir)/rebase-merge" && ! -d "$(git rev-parse --git-dir)/rebase-apply" ]]; then
                        break
                    fi
                done
                
                log_success "Rebase conflicts resolved"
            fi

            # Cleanup backup
            if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
                rm -rf "$backup_dir"
            fi
        fi

        # After rebase, ensure upstream's preserved paths are removed
        local needs_amend=false
        for path in "${PRESERVE_PATHS[@]}"; do
            # Check if upstream added this path and it shouldn't be there
            if git show "$UPSTREAM_REMOTE/$branch:$path" &>/dev/null; then
                if [[ -e "$path" ]]; then
                    # Check if this is upstream's version (not ours)
                    local upstream_hash local_hash
                    upstream_hash=$(git ls-tree "$UPSTREAM_REMOTE/$branch" "$path" 2>/dev/null | awk '{print $3}')
                    local_hash=$(git ls-tree HEAD "$path" 2>/dev/null | awk '{print $3}')
                    if [[ "$upstream_hash" == "$local_hash" ]]; then
                        log_info "Removing upstream's $path that was added during rebase"
                        rm -rf "$path"
                        git add -A
                        needs_amend=true
                    fi
                fi
            fi
        done

        # Handle sync-upstream.sh: only on source branch
        if [[ "$branch" == "$SCRIPT_SOURCE_BRANCH" ]]; then
            if [[ -n "$canonical_script" && -f "$canonical_script" ]]; then
                if ! cmp -s "$canonical_script" "$SCRIPT_NAME" 2>/dev/null; then
                    cp "$canonical_script" "$SCRIPT_NAME"
                    chmod +x "$SCRIPT_NAME"
                    git add "$SCRIPT_NAME"
                    needs_amend=true
                    log_info "Updated $SCRIPT_NAME"
                fi
            fi
        else
            # On other branches: remove the script if it exists
            if [[ -e "$SCRIPT_NAME" ]]; then
                log_info "Removing $SCRIPT_NAME (only lives on $SCRIPT_SOURCE_BRANCH)"
                rm -f "$SCRIPT_NAME"
                git add -A
                needs_amend=true
            fi
        fi

        # Commit any post-rebase fixes
        if [[ "$needs_amend" == "true" ]]; then
            if ! git diff --cached --quiet; then
                git commit -m "Post-rebase cleanup: ensure local paths are correct

Branch: $branch"
                log_success "Committed post-rebase fixes"
            fi
        fi
    fi

    # Push to origin (force needed after rebase)
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
