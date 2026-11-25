# Signing and notarization helpers, sourced by the app, dmg and release tasks.
#
# SIGN_IDENTITY   code-signing identity (name or SHA-1); "-" forces ad-hoc. Default: DEVELOPER_ID_SHA1 of
#                 .env.production, else the first valid "Developer ID Application" identity in the keychain, else
#                 ad-hoc (local builds only).
# NOTARY_PROFILE  notarytool keychain profile. Default: NOTARY_KEYCHAIN_PROFILE of .env.production, else peekaboo.
#                 When the profile cannot be read (a locked screen locks notarytool's data-protection keychain item),
#                 the App Store Connect API key of .env.production is used instead: APP_STORE_CONNECT_API_KEY_PATH,
#                 APP_STORE_CONNECT_API_KEY_ID and APP_STORE_CONNECT_API_ISSUER_ID.
# TEAM_ID         Apple team the release must be signed by. Default: APPLE_TEAM_ID of .env.production.
# DRY_RUN=1       print the notarization and publishing commands instead of running them.

dry() { [[ "${DRY_RUN:-0}" == 1 ]]; }

# load_release_env: fill SIGN_IDENTITY, NOTARY_PROFILE, TEAM_ID and the App Store Connect API key (when unset) from the
# local, git-ignored .env.production (keys as in .env.example). Parsed line by line, never sourced; only these keys are
# read, and none is exported or printed.
load_release_env() {
  local file="${PEEKABOO_RELEASE_ENV:-.env.production}" key value
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    value="${value%$'\r'}"
    value="${value#[\"\']}"
    value="${value%[\"\']}"
    [[ -n "$value" ]] || continue
    case "$key" in
      DEVELOPER_ID_SHA1) SIGN_IDENTITY="${SIGN_IDENTITY:-$value}" ;;
      NOTARY_KEYCHAIN_PROFILE) NOTARY_PROFILE="${NOTARY_PROFILE:-$value}" ;;
      APPLE_TEAM_ID) TEAM_ID="${TEAM_ID:-$value}" ;;
      APP_STORE_CONNECT_API_KEY_PATH) APP_STORE_CONNECT_API_KEY_PATH="${APP_STORE_CONNECT_API_KEY_PATH:-$value}" ;;
      APP_STORE_CONNECT_API_KEY_ID) APP_STORE_CONNECT_API_KEY_ID="${APP_STORE_CONNECT_API_KEY_ID:-$value}" ;;
      APP_STORE_CONNECT_API_ISSUER_ID) APP_STORE_CONNECT_API_ISSUER_ID="${APP_STORE_CONNECT_API_ISSUER_ID:-$value}" ;;
    esac
  done < "$file"
}

# team_id <code>: the TeamIdentifier of its signature ("not set" when ad-hoc).
team_id() { codesign -dvv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/ { team = $2 } END { print team }'; }

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

# notary_auth: set NOTARY_AUTH to notarytool's credential arguments, once: the keychain profile when it can be read,
# else the App Store Connect API key named in .env.production (its file works with the screen locked).
notary_auth() {
  [[ ${#NOTARY_AUTH[@]} -gt 0 ]] && return
  local profile="${NOTARY_PROFILE:-peekaboo}" key="${APP_STORE_CONNECT_API_KEY_PATH:-}"
  key="${key/#\~/$HOME}"
  if xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "$profile")
  elif [[ -n "$key" && -r "$key" && -n "${APP_STORE_CONNECT_API_KEY_ID:-}" && -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" ]]; then
    echo "notarytool profile $profile cannot be read (locked screen?): using the App Store Connect API key" >&2
    NOTARY_AUTH=(--key "$key" --key-id "$APP_STORE_CONNECT_API_KEY_ID" --issuer "$APP_STORE_CONNECT_API_ISSUER_ID")
  else
    echo "notarytool profile $profile cannot be read and no App Store Connect API key is set (.env.production)" >&2
    NOTARY_AUTH=(--keychain-profile "$profile")  # notarytool says what is missing
  fi
}
NOTARY_AUTH=()

# notarize <zip|dmg>: submit to Apple's notary service and wait; fails, printing Apple's log, unless accepted.
notarize() {
  local file="$1" out id status
  if dry; then
    echo "+ xcrun notarytool submit $file <keychain profile or App Store Connect API key> --wait"
    return
  fi
  notary_auth
  echo "notarizing $file (a few minutes)…"
  out="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json)"
  id="$(plutil -extract id raw -o - - <<<"$out")"
  status="$(plutil -extract status raw -o - - <<<"$out")"
  echo "notarization $id: $status"
  if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    return 1
  fi
}

# staple <app|dmg>: attach the notarization ticket and check it (Gatekeeper then needs no network).
staple() {
  run xcrun stapler staple "$1"
  run xcrun stapler validate "$1"
}
