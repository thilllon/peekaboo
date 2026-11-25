extension ConfigStore {
    /// The starter `config.toml` that `app.config` creates: every setting present but commented out,
    /// so the file changes nothing until a line is uncommented. Settings that are planned but not read
    /// yet are only named in prose, so uncommenting every setting line still gives a clean file.
    public static var sampleConfig: String {
        sampleTemplate.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.isEmpty || line.hasPrefix("#") ? String(line) : "# " + line
        }.joined(separator: "\n")
    }

    /// `sampleConfig` with the settings uncommented (valid as a config; the tests parse it).
    static let sampleTemplate = #"""
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

[view]
background = "black"          # black | gray | checker   (cycle with b)
keep_zoom = false             # keep zoom and pan when moving to another image (toggle: shift+z)
zoom_step = 1.25              # factor of one zoom.in / zoom.out step
refine_delay_ms = 90          # pause after a zoom gesture before the high-quality re-render

[fullscreen]
mode = "instant"              # instant (borderless, no Space animation) | native (macOS Space)
avoid_notch = true            # keep the image below the camera housing on notched displays

[hud]
mode = "minimal"              # off | minimal | full   (cycle with i)

[cache]
memory_mb = "auto"            # decoded-image budget in MB, or "auto" (derived from installed memory)

[rating]
storage = "finder-tags"       # finder-tags | none
star = "★"                    # 3 stars -> Finder tag "★★★"
auto_advance = false          # true: plain 0-9 / p / x / u also go to the next image (shift+key always does)

[keymap]
defaults = true               # false: start from an empty keymap
vim = false                   # add the vim layer (h j k l, g g, G, d d, y y, y p ...)

[updates]
check = true                  # look for a new release when online (never during launch, at most hourly)
auto_install = true           # download it in the background and install it when Peekaboo quits

[slots]                       # destinations for file.move:<slot> / file.copy:<slot>; opt+N moves, opt+shift+N copies
1 = "~/Pictures/Keep"
2 = "~/Pictures/Later"
3 = "./_rejects"              # relative = next to the current image
keep = "~/Pictures/Keep"

[apps]                        # for file.open_with:<name>: a bundle id, an app name or a path
editor = "com.pixelmatorteam.pixelmator.x"
preview = "com.apple.Preview"

[keys]                        # "chord" = "action" or ["action", ...]; "none" removes a default binding
"k" = "file.move:keep"        # one-key keep (needs the keep slot above)
"shift+3" = ["meta.rate:3", "nav.next"]
"ctrl+x o" = "exec:open -a ImageOptim {path}"          # a sequence: ctrl+x, then o
"ctrl+x p" = "exec:open -a 'Pixelmator Pro' {path}"    # {path} is passed safely quoted, also inside "..."
"tab" = "none"                # unbind a default

[keys.zoomed]                 # active while zoomed in beyond fit; falls back to [keys]
"shift+left" = "pan.edge:left"
"shift+right" = "pan.edge:right"

"""#
}
