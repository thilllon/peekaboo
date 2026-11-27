/// config.toml files that earlier versions wrote and users still have: the upgrade (`ConfigStore.upgradeFile`) and the
/// Settings window's edits must handle them.
enum LegacyConfigFiles {
    /// The starter file of every release up to 20261126-517cb0 (`app.config_file`, and what a Settings change started
    /// from without a file): every setting commented out, byte for byte (3650 B).
    static let releasedStarter = #"""
# Peekaboo configuration. Every setting is optional: a missing key keeps its built-in default.
# Saving this file applies it at once. An error shows as a toast with its line number, and the
# previous configuration stays active; an unknown key is skipped with a warning, and the rest
# applies. Reference: docs/CONFIG.md in the Peekaboo repository.
# To change a setting, remove the "# " in front of it (and in front of its [table] line).
#
# Planned, not read yet (skipped with a warning if set): the [general] table (sort, wrap,
# include_hidden, recursive, open_multiple, keep_running, escape), the [loading] table, view.fit,
# view.actual, view.upscale_filter, fullscreen.hide_cursor_ms, hud.position, hud.autohide_ms,
# hud.font_size, hud.toast_ms, cache.prefetch_ahead, cache.prefetch_behind and cache.preview_count.

# [view]
# background = "black"          # black | gray | checker   (cycle with b)
# keep_zoom = false             # keep zoom and pan when moving to another image (toggle: shift+z)
# zoom_step = 1.25              # factor of one zoom.in / zoom.out step
# refine_delay_ms = 90          # pause after a zoom gesture before the high-quality re-render

# [fullscreen]
# mode = "instant"              # instant (borderless, no Space animation) | native (macOS Space)
# avoid_notch = true            # keep the image below the camera housing on notched displays

# [hud]
# mode = "minimal"              # off | minimal | full   (cycle with i)

# [cache]
# memory_mb = "auto"            # decoded-image budget in MB, or "auto" (derived from installed memory)

# [rating]
# storage = "finder-tags"       # finder-tags | none
# star = "★"                    # 3 stars -> Finder tag "★★★"
# auto_advance = false          # true: plain 0-9 / p / x / u also go to the next image (shift+key always does)

# [keymap]
# defaults = true               # false: start from an empty keymap
# vim = false                   # add the vim layer (h j k l, g g, G, d d, y y, y p ...)

# [decode]
# hdr = false                   # gain-map and PQ / HLG photos in HDR (10-15x the SDR decode time; PEEKABOO_HDR=1 forces it)
# fast_path = true              # ImageIO's private IOSurface path (false: public path only; PEEKABOO_NO_IOSURFACE_SPI=1)

# [debug]
# trace = false                 # timestamped trace lines on stderr (PEEKABOO_TRACE=1 forces it)

# [updates]
# check = true                  # look for a new release when online (never during launch, at most hourly)
# auto_install = true           # download it in the background and install it when Peekaboo quits

# [slots]                       # destinations for file.move:<slot> / file.copy:<slot>; opt+N moves, opt+shift+N copies
# 1 = "~/Pictures/Keep"
# 2 = "~/Pictures/Later"
# 3 = "./_rejects"              # relative = next to the current image
# keep = "~/Pictures/Keep"

# [apps]                        # for file.open_with:<name>: a bundle id, an app name or a path
# editor = "com.pixelmatorteam.pixelmator.x"
# preview = "com.apple.Preview"

# [keys]                        # "chord" = "action" or ["action", ...]; "none" removes a default binding
# "k" = "file.move:keep"        # one-key keep (needs the keep slot above)
# "shift+3" = ["meta.rate:3", "nav.next"]
# "ctrl+x o" = "exec:open -a ImageOptim {path}"          # a sequence: ctrl+x, then o
# "ctrl+x p" = "exec:open -a 'Pixelmator Pro' {path}"    # {path} is passed safely quoted, also inside "..."
# "tab" = "none"                # unbind a default

# [keys.zoomed]                 # active while zoomed in beyond fit; falls back to [keys]
# "shift+left" = "pan.edge:left"
# "shift+right" = "pan.edge:right"

"""#

    /// The very first starter file (development builds before #21).
    static let firstStarter = "# Peekaboo configuration — every key is optional.\n"

    /// The starter files of the development builds between the two, newest first (`SampleConfig.swift` at d4f0032,
    /// e04e29e and a5ba1b6): the released one before `[decode]` and `[debug]`, then before `[updates]`, then with the
    /// first header and an older comment. `ConfigFileTests` checks each against the digest Peekaboo knows it by.
    static let developmentStarters: [String] = {
        var lines = releasedStarter.components(separatedBy: "\n")
        func remove(from first: String, to next: String) {
            lines.removeSubrange(lines.firstIndex(of: first)!..<lines.firstIndex(of: next)!)
        }
        remove(from: "# [decode]", to: "# [updates]")
        let d4f0032 = lines.joined(separator: "\n")
        remove(from: "# [updates]", to: lines.first { $0.hasPrefix("# [slots] ") }!)
        let e04e29e = lines.joined(separator: "\n")
        let warnings = lines.firstIndex { $0.hasPrefix("# previous configuration stays active;") }!
        lines.replaceSubrange(warnings...warnings + 1,
                              with: ["# previous configuration stays active. Reference: docs/CONFIG.md in the Peekaboo repository."])
        remove(from: "#", to: "")  // the planned settings
        let a5ba1b6 = lines.joined(separator: "\n")
            .replacingOccurrences(of: "{path} is passed safely quoted, also inside \"...\"", with: "{path} is substituted already shell-quoted")
        return [d4f0032, e04e29e, a5ba1b6]
    }()

    /// Every starter file a version of Peekaboo wrote, exactly.
    static var starters: [String] { [releasedStarter] + developmentStarters + [firstStarter] }
}
