# Signing and notarization helpers, sourced by the app, dmg and release tasks.
#
# SIGN_IDENTITY   code-signing identity (name or SHA-1); "-" forces ad-hoc. Default: the first valid
#                 "Developer ID Application" identity in the keychain, else ad-hoc (local builds only).
# NOTARY_PROFILE  notarytool keychain profile (default peekaboo-notary, see AGENTS.md).
# DRY_RUN=1       print the notarization and publishing commands instead of running them.

dry() { [[ "${DRY_RUN:-0}" == 1 ]]; }

# run <command…>: run it, or print it in a dry run.
run() {
  if dry; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

sign_identity() {
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "$SIGN_IDENTITY"
    return
  fi
  local id
  id="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application: / && !id { id = $2 } END { print id }')"
  echo "${id:--}"
}

# is_developer_id <code>: signed with a Developer ID Application certificate. The filters read all of their input:
# one that quits at the first match (`grep -q`, awk's `exit`) kills the writer with SIGPIPE on its next line, and
# under `set -o pipefail` the whole test then fails although it matched.
is_developer_id() { codesign -dvv "$1" 2>&1 | grep '^Authority=Developer ID Application: ' >/dev/null; }

# notarize <zip|dmg>: submit to Apple's notary service and wait; fails, printing Apple's log, unless accepted.
notarize() {
  local file="$1" profile="${NOTARY_PROFILE:-peekaboo-notary}" out id status
  if dry; then
    run xcrun notarytool submit "$file" --keychain-profile "$profile" --wait
    return
  fi
  echo "notarizing $file (a few minutes)…"
  out="$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json)"
  id="$(plutil -extract id raw -o - - <<<"$out")"
  status="$(plutil -extract status raw -o - - <<<"$out")"
  echo "notarization $id: $status"
  if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    return 1
  fi
}

# staple <app|dmg>: attach the notarization ticket and check it (Gatekeeper then needs no network).
staple() {
  run xcrun stapler staple "$1"
  run xcrun stapler validate "$1"
}
