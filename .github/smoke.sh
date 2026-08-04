#!/usr/bin/env bash
#
# Behaviour tests for connect.sh that need no Backblaze account.
#
# Everything here either fails before touching the network, or fails against
# B2's auth endpoint with deliberately wrong credentials. The one test that does
# reach out asserts only "non-zero exit and no remote left behind", which holds
# whether the request 401s or cannot connect at all.
#
# Usage: RCLONE_CONFIG=/tmp/scratch.conf ./smoke.sh /path/to/connect.sh

set -u

SCRIPT="${1:-./connect.sh}"
[ -x "$SCRIPT" ] || chmod +x "$SCRIPT" 2>/dev/null || true

: "${RCLONE_CONFIG:?set RCLONE_CONFIG to a scratch path so the real config is safe}"
rm -f "$RCLONE_CONFIG"
: > "$RCLONE_CONFIG"

# These MUST be cleared. If the calling environment happens to have real
# credentials in it, every "refuses without credentials" test below would pass
# for entirely the wrong reason -- the script would sail past the prompt and
# fail later at authentication instead.
unset B2_KEY_ID B2_APP_KEY

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}

# expect_exit CODE "label" args...
expect_exit() {
  _want="$1"; _label="$2"; shift 2
  _out="$("$SCRIPT" "$@" 2>&1 </dev/null)"; _got=$?
  if [ "$_got" -eq "$_want" ]; then
    ok "$_label (exit $_got)"
  else
    bad "$_label (wanted exit $_want, got $_got)" "$_out"
  fi
}

# expect_output "label" "needle" args...
expect_output() {
  _label="$1"; _needle="$2"; shift 2
  _out="$("$SCRIPT" "$@" 2>&1 </dev/null)"
  case "$_out" in
    *"$_needle"*) ok "$_label" ;;
    *) bad "$_label (no '$_needle' in output)" "$_out" ;;
  esac
}

remotes() { rclone listremotes 2>/dev/null | tr '\n' ' '; }

echo "--- connect.sh behaviour (bash ${BASH_VERSION:-unknown}) ---"

# --- things that must not need credentials --------------------------------
expect_exit 0 "--help exits clean"    --help
expect_exit 0 "--version exits clean" --version
expect_output "--help documents --bucket"   "--bucket"      --help
expect_output "--version prints a version"  "connect.sh 1." --version

# --- argument validation --------------------------------------------------
expect_exit 1 "unknown flag rejected"         --bogus
expect_output "unknown flag names itself" "unknown option" --bogus
expect_exit 1 "remote name with ':' rejected" --remote "has:colon"
expect_exit 1 "remote name with '/' rejected" --remote "has/slash"
expect_exit 1 "empty remote name rejected"    --remote ""

# --- missing credentials, with no terminal to prompt at -------------------
# Note the assertion is on the message, not just the exit code: exiting 1 for
# some unrelated reason would otherwise look like a pass.
expect_exit   1 "refuses without a keyID when non-interactive"  --remote t1 --yes
expect_output "says how to supply a keyID" "B2_KEY_ID" --remote t1 --yes

_out="$(B2_KEY_ID="005hasidbutnokey00000000" "$SCRIPT" --remote t2 --yes 2>&1 </dev/null)"
_got=$?
if [ "$_got" -eq 1 ]; then
  case "$_out" in
    *B2_APP_KEY*) ok "refuses without an applicationKey when non-interactive" ;;
    *) bad "refuses without an applicationKey when non-interactive" "$_out" ;;
  esac
else
  bad "refuses without an applicationKey when non-interactive (exit $_got)" "$_out"
fi

# --- rollback: a remote that fails verification must not survive ----------
# The env prefix here is a genuine command invocation, so the variables really
# do reach the script. Written as assignments before a "$(...)" they would not.
BEFORE="$(remotes)"
_out="$(B2_KEY_ID="005deadbeefdeadbeef000000" \
        B2_APP_KEY="K005notARealApplicationKeyAtAll" \
        "$SCRIPT" --remote rollbackme --yes 2>&1 </dev/null)"; _got=$?
AFTER="$(remotes)"

if [ "$_got" -ne 0 ]; then
  ok "bad credentials fail (exit $_got)"
else
  bad "bad credentials fail" "$_out"
fi

case "$AFTER" in
  *rollbackme*) bad "broken remote rolled back" "still present: $AFTER" ;;
  *) ok "broken remote rolled back (remotes: ${AFTER:-none})" ;;
esac

if [ "$BEFORE" = "$AFTER" ]; then
  ok "config unchanged overall"
else
  bad "config unchanged overall" "before: [$BEFORE] after: [$AFTER]"
fi

# --- an existing remote is never clobbered without consent ----------------
rclone config create keepme b2 account sentinel-account key sentinel-key >/dev/null 2>&1
_out="$("$SCRIPT" --remote keepme 2>&1 </dev/null)"; _got=$?
SENTINEL="$(rclone config show keepme 2>/dev/null | awk -F' *= *' '/^account/ { print $2; exit }')"
if [ "$_got" -eq 1 ] && [ "$SENTINEL" = "sentinel-account" ]; then
  ok "existing remote left intact without --force"
else
  bad "existing remote left intact without --force" "exit $_got, account now '$SENTINEL'"
fi

# --- probe hygiene --------------------------------------------------------
# Asserted by reading the script rather than by round-tripping to B2, since
# there are no credentials here. A soft delete would leave a permanent hidden
# version in the user's bucket, so this must not regress.
if grep -q 'deletefile --b2-hard-delete' "$SCRIPT"; then
  ok "probe object is hard-deleted"
else
  bad "probe object is hard-deleted" "no 'deletefile --b2-hard-delete' in $SCRIPT"
fi

rm -f "$RCLONE_CONFIG"

echo
echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ] || exit 1
