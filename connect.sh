#!/usr/bin/env bash
#
# connect.sh -- configure an rclone remote for Backblaze B2 and prove it works.
#
# Does three things and stops:
#   1. checks rclone is installed, and offers to install it if not
#   2. writes a B2 remote into your rclone config
#   3. verifies the credentials actually work, including write access
#
# If verification fails on a remote this script just created, the remote is
# removed again rather than left behind broken.
#
# Works on macOS and Linux, under bash 3.2 (which is what macOS ships) and any
# later version. For Windows use connect.ps1.

set -eu

VERSION="1.0.0"
PROBE_PREFIX=".rclone-b2-setup-probe"

# --------------------------------------------------------------------------
# output helpers. Colour only when stdout is a terminal, so redirected output
# and CI logs stay readable.
# --------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '    %sok%s    %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %swarn%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  { printf '\n%serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
connect.sh -- set up an rclone remote for Backblaze B2, then verify it.

Usage:
  ./connect.sh [options]

Options:
  -r, --remote NAME     name for the rclone remote (default: b2)
      --key-id ID       B2 application keyID     (else $B2_KEY_ID, else prompt)
      --app-key KEY     B2 applicationKey        (else $B2_APP_KEY, else prompt)
  -b, --bucket NAME     bucket to verify read/write against. Strongly
                        recommended: without it only listing can be checked.
      --create-bucket   create the bucket if it does not exist
      --force           replace an existing remote of the same name
      --no-install      fail instead of offering to install rclone
  -y, --yes             assume yes to prompts (for scripted use)
  -h, --help            this
      --version         print version

Examples:
  ./connect.sh
  ./connect.sh --bucket my-backup-bucket
  ./connect.sh --remote b2prod --bucket my-backup-bucket --create-bucket

  B2_KEY_ID=005... B2_APP_KEY=K005... ./connect.sh -b my-bucket -y

Get a keyID and applicationKey from Backblaze:
  https://secure.backblaze.com/app_keys.htm

Use an application key scoped to one bucket rather than the master key. The
master key cannot be scoped and cannot be rotated without breaking everything
that uses it at once.
EOF
}

# --------------------------------------------------------------------------
# arguments
# --------------------------------------------------------------------------
REMOTE="b2"
KEY_ID="${B2_KEY_ID:-}"
APP_KEY="${B2_APP_KEY:-}"
BUCKET=""
CREATE_BUCKET=0
FORCE=0
NO_INSTALL=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    -r|--remote)      REMOTE="${2-}";  shift; [ $# -gt 0 ] && shift ;;
    --key-id)         KEY_ID="${2-}";  shift; [ $# -gt 0 ] && shift ;;
    --app-key)        APP_KEY="${2-}"; shift; [ $# -gt 0 ] && shift ;;
    -b|--bucket)      BUCKET="${2-}";  shift; [ $# -gt 0 ] && shift ;;
    --create-bucket)  CREATE_BUCKET=1; shift ;;
    --force)          FORCE=1;         shift ;;
    --no-install)     NO_INSTALL=1;    shift ;;
    -y|--yes)         ASSUME_YES=1;    shift ;;
    -h|--help)        usage; exit 0 ;;
    --version)        say "connect.sh $VERSION"; exit 0 ;;
    *)                die "unknown option: $1  (try --help)" ;;
  esac
done

[ -n "$REMOTE" ] || die "--remote cannot be empty"
case "$REMOTE" in
  *:*|*/*) die "remote name cannot contain ':' or '/': $REMOTE" ;;
esac

confirm() {
  # confirm "question" -> 0 for yes, 1 for no. Assumes yes under --yes, and
  # under --yes never blocks waiting on a terminal that may not exist.
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if [ ! -t 0 ]; then
    warn "not a terminal and --yes not given, assuming no"
    return 1
  fi
  printf '    %s [y/N] ' "$1"
  read -r _reply || return 1
  case "$_reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

say "${C_BOLD}rclone + Backblaze B2 setup${C_RESET} (connect.sh $VERSION)"

# --------------------------------------------------------------------------
# 1. rclone
# --------------------------------------------------------------------------
step "checking for rclone"

install_hint() {
  # Print the most appropriate install command for this machine.
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        say "    brew install rclone"
      else
        say "    Install Homebrew from https://brew.sh then: brew install rclone"
        say "    or follow https://rclone.org/install/"
      fi
      ;;
    Linux)
      say "    curl https://rclone.org/install.sh | sudo bash"
      say ""
      info "Distribution packages exist (apt/dnf/pacman install rclone) but are"
      info "often years behind. The line above is rclone's official installer."
      ;;
    *)
      say "    See https://rclone.org/install/"
      ;;
  esac
}

try_install() {
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || return 1
      brew install rclone
      ;;
    Linux)
      command -v curl >/dev/null 2>&1 || return 1
      command -v sudo >/dev/null 2>&1 || return 1
      # rclone's own documented installer. Shown to the user before running.
      curl -fsSL https://rclone.org/install.sh | sudo bash
      ;;
    *) return 1 ;;
  esac
}

if command -v rclone >/dev/null 2>&1; then
  ok "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}') found at $(command -v rclone)"
else
  warn "rclone is not installed"
  if [ "$NO_INSTALL" -eq 1 ]; then
    say ""
    say "  Install it with:"
    install_hint
    die "rclone is required"
  fi
  say ""
  say "  Suggested install command for this machine:"
  install_hint
  say ""
  if confirm "Run that now?"; then
    try_install || die "automatic install failed. Install rclone manually, then re-run."
    command -v rclone >/dev/null 2>&1 || die "rclone still not on PATH after install"
    ok "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}') installed"
  else
    die "rclone is required. Install it and re-run."
  fi
fi

CONFIG_PATH="$(rclone config file 2>/dev/null | tail -1)"
[ -n "$CONFIG_PATH" ] && info "config: $CONFIG_PATH"

# --------------------------------------------------------------------------
# 2. credentials
# --------------------------------------------------------------------------
step "credentials"

REMOTE_EXISTED=0
if rclone listremotes 2>/dev/null | grep -qx "${REMOTE}:"; then
  REMOTE_EXISTED=1
  EXISTING_TYPE="$(rclone config show "$REMOTE" 2>/dev/null \
    | awk -F' *= *' '/^type/ { print $2; exit }')"
  if [ "$FORCE" -eq 1 ]; then
    warn "remote '$REMOTE' already exists (type ${EXISTING_TYPE:-unknown}), replacing it"
  else
    say ""
    say "  A remote called '$REMOTE' already exists (type ${EXISTING_TYPE:-unknown})."
    say "  Re-running will overwrite its keys."
    say ""
    confirm "Overwrite it?" || die "nothing changed. Use --remote NAME to set up a different one."
  fi
fi

if [ -z "$KEY_ID" ]; then
  [ -t 0 ] || die "no keyID given. Pass --key-id, set B2_KEY_ID, or run interactively."
  say ""
  info "Create an application key at https://secure.backblaze.com/app_keys.htm"
  info "Scope it to one bucket. Do not use the master key."
  say ""
  printf '    keyID: '
  read -r KEY_ID
fi
[ -n "$KEY_ID" ] || die "keyID cannot be empty"

if [ -z "$APP_KEY" ]; then
  [ -t 0 ] || die "no applicationKey given. Pass --app-key, set B2_APP_KEY, or run interactively."
  printf '    applicationKey (not echoed): '
  # -s is a bashism but this script already requires bash; it keeps the key out
  # of the scrollback.
  read -rs APP_KEY
  printf '\n'
fi
[ -n "$APP_KEY" ] || die "applicationKey cannot be empty"

# Backblaze shows the keyID and applicationKey adjacently in its UI and they are
# easy to paste the wrong way round. The keyID is short and hex; the
# applicationKey is longer and starts with K. Catch the obvious swap.
case "$KEY_ID" in
  K0*) if [ ${#KEY_ID} -gt 26 ]; then
         warn "that keyID looks like an applicationKey -- are they swapped?"
       fi ;;
esac

# --------------------------------------------------------------------------
# 3. write the remote
# --------------------------------------------------------------------------
step "writing remote '$REMOTE'"

# hard_delete stays at the default of false on purpose. With it false, deleting
# a file on B2 hides it and a lifecycle rule can remove it later, which leaves
# you an undelete window. See the README.
if ! rclone config create "$REMOTE" b2 \
      account "$KEY_ID" key "$APP_KEY" >/dev/null 2>&1; then
  die "rclone config create failed for remote '$REMOTE'"
fi
ok "remote '$REMOTE' written to ${CONFIG_PATH:-the rclone config}"

# From here on, a failure means we should not leave a broken remote behind --
# but only if we created it. An existing remote the user chose to overwrite is
# already gone either way, so say so rather than silently restoring nothing.
rollback() {
  if [ "$REMOTE_EXISTED" -eq 0 ]; then
    rclone config delete "$REMOTE" >/dev/null 2>&1 || true
    info "removed remote '$REMOTE' again, since setup did not finish"
  else
    warn "remote '$REMOTE' was overwritten with keys that did not verify"
  fi
}

# --------------------------------------------------------------------------
# 4. verify
# --------------------------------------------------------------------------
step "verifying"

# Listing buckets needs the listBuckets capability. A key scoped to a single
# bucket does NOT have it, so this failing is not conclusive -- it is only
# conclusive when no bucket was given and there is nothing else to try.
LIST_OK=0
if LIST_OUT="$(rclone lsd "${REMOTE}:" 2>&1)"; then
  LIST_OK=1
  BUCKET_N="$(printf '%s\n' "$LIST_OUT" | grep -c . || true)"
  ok "authenticated, and the key can list buckets ($BUCKET_N visible)"
else
  if [ -n "$BUCKET" ]; then
    warn "cannot list all buckets -- normal for a bucket-scoped key"
  else
    say ""
    printf '%s\n' "$LIST_OUT" | sed 's/^/      /'
    say ""
    rollback
    die "could not authenticate, and no --bucket was given to test directly.
      If this key is scoped to one bucket, re-run with:
        ./connect.sh --remote $REMOTE --bucket YOUR-BUCKET"
  fi
fi

if [ -z "$BUCKET" ]; then
  warn "no --bucket given, so write access was not tested"
  info "A key can list buckets and still be unable to write to them."
else
  # Does the bucket exist and can we see into it?
  if rclone lsf "${REMOTE}:${BUCKET}" --max-depth 1 >/dev/null 2>&1; then
    ok "bucket '$BUCKET' is reachable"
  else
    if [ "$CREATE_BUCKET" -eq 1 ]; then
      if rclone mkdir "${REMOTE}:${BUCKET}" >/dev/null 2>&1; then
        ok "bucket '$BUCKET' created"
      else
        rollback
        die "could not create bucket '$BUCKET'.
      Bucket names are globally unique across all of Backblaze B2, so a plain
      name like 'backup' is long gone. Try 'yourname-hostname-backup'."
      fi
    else
      rollback
      die "bucket '$BUCKET' is not reachable.
      Either it does not exist -- re-run with --create-bucket -- or this key is
      scoped to a different bucket."
    fi
  fi

  # Write, read back, delete. This is the only step that proves the key is
  # actually usable for a backup; --dry-run style checks never write, so they
  # succeed against buckets you cannot touch.
  PROBE="${PROBE_PREFIX}-$(date +%Y%m%d%H%M%S)-$$"
  PROBE_LOCAL="$(mktemp -t rclone-b2-probe.XXXXXX)"
  printf 'written by connect.sh at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PROBE_LOCAL"
  # Always try to clean up the probe, including on Ctrl-C.
  #
  # --b2-hard-delete is not optional here. A normal delete on B2 only HIDES a
  # file: the version stays in the bucket, stays billable, and stops the bucket
  # from being considered empty. Verifying a connection should not leave a
  # permanent object in someone's bucket, so the probe -- and only the probe --
  # gets deleted for real.
  cleanup_probe() {
    rm -f "$PROBE_LOCAL" 2>/dev/null || true
    rclone deletefile --b2-hard-delete "${REMOTE}:${BUCKET}/${PROBE}" >/dev/null 2>&1 || true
  }
  trap cleanup_probe EXIT INT TERM

  if ! rclone copyto "$PROBE_LOCAL" "${REMOTE}:${BUCKET}/${PROBE}" >/dev/null 2>&1; then
    rollback
    die "the key can see bucket '$BUCKET' but cannot write to it.
      Application keys can be read-only; check the key's permissions at
      https://secure.backblaze.com/app_keys.htm"
  fi
  ok "wrote a probe object"

  if ! rclone cat "${REMOTE}:${BUCKET}/${PROBE}" >/dev/null 2>&1; then
    rollback
    die "wrote the probe object but could not read it back"
  fi
  ok "read it back"

  if rclone deletefile --b2-hard-delete "${REMOTE}:${BUCKET}/${PROBE}" >/dev/null 2>&1; then
    ok "deleted it, leaving the bucket exactly as it was"
  else
    warn "could not delete the probe object ${BUCKET}/${PROBE} -- remove it by hand"
  fi

  trap - EXIT INT TERM
  rm -f "$PROBE_LOCAL" 2>/dev/null || true
fi

# --------------------------------------------------------------------------
# 5. what to do next
# --------------------------------------------------------------------------
DEST="${REMOTE}:${BUCKET:-YOUR-BUCKET}"

say ""
say "${C_GREEN}${C_BOLD}Connected.${C_RESET} Remote '${REMOTE}' is configured and working."
say ""
say "  Try it:"
say "    rclone lsd ${REMOTE}:"
say "    rclone ls ${DEST}"
say "    rclone copy ~/Documents ${DEST}/Documents"
say "    rclone sync ~/Documents ${DEST}/Documents --dry-run"
say ""
say "  ${C_BOLD}Always --dry-run a sync first.${C_RESET} sync makes the destination match the"
say "  source, which means it deletes remote files that are gone locally."
say ""
if [ "$LIST_OK" -eq 0 ]; then
  say "  Note: this key is scoped to one bucket, so 'rclone lsd ${REMOTE}:' fails with"
  say "  401 unauthorized. That is expected. Always name the bucket instead:"
  say "    rclone ls ${DEST}"
  say ""
fi
say "  One thing worth doing now, once per bucket:"
say "    rclone backend lifecycle ${REMOTE}:${BUCKET:-YOUR-BUCKET} -o daysFromHidingToDeleting=30"
say ""
info "On B2, deleting a file only hides it -- the bytes stay billable forever"
info "unless a lifecycle rule removes them. That command gives you a 30-day"
info "undelete window, after which you stop paying. Needs rclone 1.65+."
say ""
