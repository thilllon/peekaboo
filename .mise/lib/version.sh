# Release version helpers, sourced by the app and release tasks (see AGENTS.md, Releases).
#
# head_version  YYYYMMDD-<sha6> of HEAD: its committer day in Asia/Seoul and the first six hex digits of its SHA,
#               so one commit always gets one version, whatever the machine's time zone.
# head_build    the build number (CFBundleVersion) of HEAD: the number of commits up to it, which only grows on
#               main. The updater orders releases by it; the SHA in the version is not orderable.
head_version() {
  local day sha
  day="$(TZ=Asia/Seoul git show -s --format=%cd --date=format-local:%Y%m%d HEAD)" || return 1
  sha="$(git rev-parse HEAD)" || return 1
  echo "$day-${sha:0:6}"
}
head_build() { git rev-list --count HEAD; }
