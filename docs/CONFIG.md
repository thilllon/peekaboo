# Configuring Peekaboo

Peekaboo reads one TOML file. Every setting is optional: a missing key keeps its built-in default, and
an empty or missing file means "all defaults". Press **⌘,** (`app.config`) for the
[Settings window](#the-settings-window), which changes every setting below and writes this file for you.
Peekaboo › Open config.toml (`app.config_file`) creates a starter file with every setting commented
out and opens it in your default editor.

- [Where the file lives](#where-the-file-lives)
- [Reloading and errors](#reloading-and-errors)
- [The Settings window](#the-settings-window)
- [Settings](#settings)
- [Key bindings](#key-bindings)
- [Chord syntax](#chord-syntax)
- [Actions](#actions)
- [Default keymap](#default-keymap)
- [File actions in detail](#file-actions-in-detail)
- [Examples](#examples)

## Where the file lives

The first of these that is set wins:

1. `$PEEKABOO_CONFIG` (a full path to the file; `~` is expanded)
2. `$XDG_CONFIG_HOME/peekaboo/config.toml`
3. `~/.config/peekaboo/config.toml`

Peekaboo never writes the file on its own. It writes it when you change something in the Settings
window, and `app.config_file` creates it when it does not exist yet. A symbolic link stays a link (the
file it points to is written, with its permissions).

## Reloading and errors

Saving the file applies it immediately. Peekaboo watches both the file and its folder, so in-place
writes and atomic saves (vim, VS Code, BBEdit, TextEdit) are both picked up. `app.reload_config`
re-reads it on demand.

A file with a mistake is **not applied**: the previous configuration stays active, and a toast names
the first problem with its line number, for example:

```
config.toml:17: unknown action "nav.nxt" (did you mean "nav.next"?)
```

Wrong value types, values out of range, unknown chords, unknown actions, unknown move/copy slots, a
chord bound twice in the same table, sequence conflicts and TOML syntax errors are all errors.

Unknown tables and unknown keys (a typo, or a setting from a newer version) are **warnings**: they are
skipped, the rest of the file is applied, and a toast names them with their line numbers:

```
config.toml:3: ignored unknown key "view.fit" (+1 more)
```

The starter file names the settings that are planned but not read yet (such as `[general]` `sort`)
only in a comment, so uncommenting its settings never produces a warning.

### TOML subset

The file is standard TOML, limited to what the schema needs: `# comments`, `[table]` headers, bare,
quoted and dotted keys, basic strings (`"…"` with `\" \\ \n \t \uXXXX` escapes), literal strings
(`'…'`), integers, floats, booleans and arrays (which may span lines and end with a comma, and nest
up to 32 deep).
Multi-line strings, inline tables, arrays of tables and dates are not supported and are reported as
errors. A key made of anything other than letters, digits, `_` and `-` must be quoted:
`"cmd+," = "app.config"`, `"?" = "view.help"`, `"g g" = "nav.first"`.

## The Settings window

⌘, opens it; it is built the first time you open it, so it costs nothing at launch. Its panes cover every
key of this page: General (default viewer per image type, the config file, the version), Viewer, Keyboard,
Files (move/copy slots, open-with apps, ratings), Performance (memory, HDR decoding, the fast decode path,
trace logging) and Updates (`[updates]`, **Check Now** and the updater's status line, the version).

The file stays the single source of truth. A change in the window is written at once as a minimal edit:
only the changed line moves, your comments, order and spacing stay, and in the starter file the
commented-out line of the setting is uncommented in place (`# background = "black"` becomes
`background = "gray"`, its comment kept). A change that would leave the file with an error is not
written, and while the file has an error (from an edit in your editor) the window shows it and waits
until it is fixed; a file that is not UTF-8 text is never rewritten. Saving the file in an editor
updates the window.

**Keyboard.** Every action is listed with its keys, for the normal and the zoomed-in context. Click **+**
and press the new keys (Esc cancels); recording matches the physical key like the viewer, so it works
under any input method. A key another action uses is named (`F is used by “Full Screen”`); press it again
(or click Move) to move it, which writes `"f" = "file.copy_name"`. A key that starts a sequence, or a
sequence it starts, is freed the same way. A key's menu changes or removes it: removing a built-in key
writes `"tab" = "none"`, removing your own deletes its entry. ↺ resets an action to its built-in keys and
Reset All removes every entry of `[keys]` and `[keys.zoomed]`. Actions with an argument
(`file.move:keep`, `meta.rate:4`, `nav.jump:+5`, `exec:…`) are added by typing their id. Sequences
(`"g g"`) are shown and can be removed, but are written in the file.

## Settings

| Key | Default | Values |
|---|---|---|
| `[view]` `background` | `"black"` | `"black"`, `"gray"`, `"checker"` (cycle with `b`) |
| `[view]` `keep_zoom` | `false` | keep zoom and pan when moving to another image (toggle with `shift+z`) |
| `[view]` `zoom_step` | `1.25` | factor of one `zoom.in` / `zoom.out` step, 1.01–8 |
| `[view]` `refine_delay_ms` | `90` | pause after a zoom gesture before the high-quality re-render, 0–2000 |
| `[fullscreen]` `mode` | `"instant"` | `"instant"` (borderless, no Space animation) or `"native"` (macOS full-screen Space) |
| `[fullscreen]` `avoid_notch` | `true` | keep the image below the camera housing on notched displays |
| `[hud]` `mode` | `"minimal"` | `"off"`, `"minimal"`, `"full"` (cycle with `i`) |
| `[cache]` `memory_mb` | `"auto"` | decoded-image memory budget in MB (64–1048576), or `"auto"` to derive it from installed memory |
| `[rating]` `storage` | `"finder-tags"` | `"finder-tags"` or `"none"` (turns `meta.*` actions off) |
| `[rating]` `star` | `"★"` | the character a rating is spelled with: 3 stars is the Finder tag `★★★` |
| `[rating]` `auto_advance` | `false` | `true`: plain `0`–`9`, `p`, `x`, `u` also go to the next image (`shift+` always does) |
| `[keymap]` `defaults` | `true` | `false` starts from an empty keymap: only your `[keys]` (and the vim layer, if on) apply |
| `[keymap]` `vim` | `false` | add the [vim layer](#vim-layer) on top of the defaults |
| `[decode]` `hdr` | `false` | decode gain-map photos (iPhone HDR, Apple gain-map JPEG/HEIC) and PQ / HLG images (10-bit HDR HEIF from cameras, HDR AVIF and PNG) to HDR for EDR displays; 10–15× the decode time of the SDR picture. Off, PQ / HLG images show ImageIO's tone-mapped SDR rendition. Turning it on or off decodes the image on screen again. `PEEKABOO_HDR=1` turns it on regardless |
| `[decode]` `fast_path` | `true` | decode through ImageIO's private IOSurface entry point (zero-copy, both hardware JPEG engines, native YCbCr for HEIF / AVIF); `false` uses the public path only, to compare or work around a decoding problem. `PEEKABOO_NO_IOSURFACE_SPI=1` turns it off regardless |
| `[debug]` `trace` | `false` | timestamped trace lines on stderr (decode paths and times, scheduling, frames). `PEEKABOO_TRACE=1` turns it on regardless, from the first line of the launch |
| `[updates]` `check` | `true` | look for a new release when online: 10 s after launch at the earliest, then every 6 h and when the network comes back, at most once an hour (see [updates](#updates)) |
| `[updates]` `auto_install` | `true` | download a new release in the background, verify it and install it when Peekaboo quits; `false` only tells you about it |
| `[slots]` *name* | none | a folder for `file.move:<name>` / `file.copy:<name>` (see [destinations](#move-and-copy)) |
| `[apps]` *name* | none | an app for `file.open_with:<name>`: a bundle id, an app name or a path |

`[slots]` named `1`…`9` are what `opt+1`…`opt+9` (move) and `opt+shift+1`…`opt+shift+9` (copy) use.
`[apps] editor` is what `e` opens.

### Updates

Peekaboo reads the manifest of the latest release on GitHub (`latest.json`, a few hundred bytes) — never
while it launches, and never on the main thread. When a newer release exists, a banner at the bottom of the
window (it waits until you pause, so it never lands between two images) and an item in the Peekaboo menu
offer it:

- With `auto_install = true` the release is downloaded in the background and checked before anything else
  happens: its SHA-256 must match the manifest, and its code signature must be valid and carry Peekaboo's
  identifier (and, for a Developer ID signed app, come from the same team). **Restart to Update** installs it
  now and reopens the image you were looking at; otherwise it is installed when Peekaboo quits.
- With `auto_install = false` the banner says that a release is available; **Update** downloads and checks it
  the same way.

Peekaboo › **Check for Updates…** looks at once, whatever `check` says; so does **Check Now** in Settings ›
Updates, which shows the outcome in its status line (`Up to date (20261125)`). The new bundle replaces the old one
in one atomic rename. When Peekaboo cannot replace itself (it runs from the disk image or from a quarantined
copy, or its folder is not writable), it offers the release page instead. If an install fails when Peekaboo
quits, the next launch says why once, and that release is then offered as a download from the release page
instead of being fetched again; **Check for Updates…** (or a newer release) tries the install again. A release is named
after its commit, e.g. `20261125-ab2342` (the day and the start of the commit hash); its build number (e.g. `35`)
decides which release is newer. The About panel, Settings (General and
Updates) and `peekaboo --version` show both.

## Key bindings

Bindings live in two tables:

- `[keys]`: the normal context.
- `[keys.zoomed]`: active while the image is zoomed in beyond fit. Keys not bound here fall back to
  `[keys]`. (`[keys.normal]` is accepted as another name for `[keys]`.)

Each entry is `"chord" = "action"` or `"chord" = ["action", "action", …]`; a list runs its actions in
order, so `"shift+3" = ["meta.rate:3", "nav.next"]` rates and advances. Your entries are applied on top
of the default keymap: binding a chord the defaults use replaces it, and `"none"` removes a binding
(`"tab" = "none"`). In `[keys.zoomed]`, `"none"` removes the zoomed binding, so the key falls back to
`[keys]`.

**One action, several keys.** An entry may also be written the other way round, with the action as the
key and one chord or a list of chords as the value:

```toml
[keys]
"nav.next" = ["n", "ctrl+f"]        # same as "n" = "nav.next" and "ctrl+f" = "nav.next"
"file.trash" = "d d"
"none" = ["tab", "b"]               # unbind both
```

A chord may be bound only once per table, whichever spelling you use.

**Sequences.** A binding may be a sequence of chords separated by spaces: `"g g"`, `"ctrl+x o"`. A key
cannot both be bound and start a sequence: with `z` bound to `zoom.toggle`, `"z z"` is reported as
`"z z" conflicts with "z"`. Unbind the single key first (`"z" = "none"`). There is no timeout, so single
keys never wait.

## Chord syntax

```
binding := chord ( " " chord )*            # "g g" is a sequence
chord   := ( modifier "+" )* key
```

- **Modifiers** (any order, any case): `cmd` / `command` / `super`, `opt` / `option` / `alt`,
  `ctrl` / `control`, `shift`.
- **Keys**: letters `a`–`z`, digits `0`–`9`, the unshifted US-layout symbols `` - = [ ] \ ; ' , . / ` ``,
  and the named keys `left right up down space return tab esc backspace forwarddelete home end pageup
  pagedown f1`…`f20 kp0`…`kp9 kp+ kp- kp* kp/ kp. kpenter`. Aliases: `enter` = `return`,
  `escape` = `esc`, `delete` = `backspace`, `del` = `forwarddelete`, `pgup` / `pgdn`.
- **Shift is a modifier.** An uppercase letter or a shifted symbol means shift plus the key that
  produces it on a US keyboard: `G` = `shift+g`, `?` = `shift+/`, `+` = `shift+=`, `<` = `shift+,`,
  `>` = `shift+.`, `|` = `shift+\`, `_` = `shift+-`, `!` = `shift+1`, `)` = `shift+0`, `cmd++` = `cmd+shift+=`.
- **Keyboard layouts.** Chords are written in US terms and match keys through your ASCII-capable
  keyboard layout, so bindings keep working while a Korean, Japanese or other input method is active,
  and on German, French and other keyboards:
  - Letters are the keys labelled with them: `z` is the Z key on a German or French keyboard.
  - Digits are the keys that type them, with or without shift: on a French keyboard `1` is the `&` key
    and `shift+1` that key with shift. Where a layout types digits only with option (Lithuanian,
    Vietnamese), the number-row keys are the digits.
  - A symbol is the key that types it: on a German keyboard `+` is the `+` key and `?` is ⇧ß. With
    shift held, the shifted symbol counts.
  - A key that types a letter outside a–z (`ü`, `ß`, `é`, `ñ`, `å`, …) or a symbol of the US number
    row (`$` on a French keyboard, which would otherwise mean `shift+4`) stands for the US key in its
    place: `ü` on a German keyboard is `[`.
  - Option and command do not change the key: `opt+1` is the 1 key rather than `¡`, and on a German
    keyboard `opt+5` is the 5 key (move to slot 5) although it types `[`.

Leave the system shortcuts alone: ⌃Space and ⌘Space (input source, Spotlight), ⌃arrows (Mission
Control), ⌘Tab, ⌘\`, ⌘H, ⌥⌘H, ⌘M, ⇧⌘3/4/5, ⌃⌘Q, ⌥⌘Esc and ⌃1…9 never reach the app or are best kept free.

## Actions

Ids are `namespace.verb`, optionally followed by `:argument`.

### Navigation and view

| Id | Does |
|---|---|
| `nav.next`, `nav.prev` | next / previous image |
| `nav.first`, `nav.last` | first / last image |
| `nav.jump:±N` | jump N images, e.g. `nav.jump:+10`, `nav.jump:-10` |
| `zoom.fit`, `zoom.fill` | fit the window / fill it |
| `zoom.actual` | 100 %: one image pixel per device pixel |
| `zoom.set:<factor>` | absolute zoom, e.g. `zoom.set:2` |
| `zoom.in`, `zoom.out` | one `zoom_step` |
| `zoom.toggle` | fit ↔ 100 % at the pointer |
| `zoom.keep` | toggle keeping zoom and pan across images |
| `pan.left`, `pan.right`, `pan.up`, `pan.down` | pan by 10 % of the window |
| `pan.edge:left`, `pan.edge:right`, `pan.edge:top`, `pan.edge:bottom` | pan to an edge |
| `pan.center` | centre the image |
| `view.fullscreen`, `view.fullscreen_native` | full screen (configured mode / native Space) |
| `view.hud`, `view.hud_hide` | cycle the HUD / hide everything |
| `view.background` | cycle black → gray → checker |
| `view.rotate_cw`, `view.rotate_ccw`, `view.flip_h`, `view.flip_v` | rotate / flip the view (the file is not changed) |
| `view.play_pause` | play or pause an animation (GIF, APNG, WebP, HEIC / AVIF sequence); after its last loop, play again |
| `view.frame_next`, `view.frame_prev` | pause the animation and step one frame (wraps around; hold to keep stepping) |
| `view.help` | the key cheat sheet |

### Files

| Id | Does |
|---|---|
| `file.trash` | move to the Trash, instantly; undo with ⌘Z |
| `file.delete` | delete permanently, after a confirmation; cannot be undone |
| `file.move:<target>`, `file.copy:<target>` | move / copy to a slot, a path, `ask` (picker) or `last` (previous destination); undoable |
| `file.reveal` | show the file in Finder |
| `file.copy_path`, `file.copy_name` | copy the POSIX path / the file name as text |
| `file.copy_image` | copy the file and its image (pasting into Finder pastes the file; image apps get pixels) |
| `file.open_with:<app>` | open with an `[apps]` name, a bundle id, an app name or an app path |
| `file.open_with_chooser` | pick from the apps that can open the file |

### Metadata (Finder tags)

| Id | Does |
|---|---|
| `meta.rate:0`…`meta.rate:5` | star rating; 0 clears it |
| `meta.label:<colour>` | `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `gray`, or `none` to clear |
| `meta.flag:pick`, `meta.flag:reject`, `meta.flag:none` | pick / reject flag |

### App

| Id | Does |
|---|---|
| `app.undo`, `app.redo` | undo / redo the last file action (trash, move, copy, rating, label, flag) |
| `app.config` | open the [Settings window](#the-settings-window) |
| `app.config_file` | create the config file if needed and open it in your editor |
| `app.reload_config` | re-read the config file now |
| `app.escape` | close an overlay, else leave full screen, else close the window |
| `app.close` | close the window (Peekaboo stays running, so the next open is instant) |
| `app.quit`, `app.open` | quit / open files |
| `app.make_default` | make Peekaboo the default app for its image types (only when you run it) |
| `exec:<command>` | run a shell command, see [exec](#exec-commands) |
| `none` | unbind |

## Default keymap

| Action | Keys |
|---|---|
| `nav.next` | `right` `down` `space` `pagedown` |
| `nav.prev` | `left` `up` `shift+space` `backspace` `pageup` |
| `nav.first` / `nav.last` | `home` `cmd+up` / `end` `cmd+down` |
| `nav.jump:-10` / `nav.jump:+10` | `[` / `]` |
| `zoom.toggle` | `z` (also double-click) |
| `zoom.fit` | `cmd+0` `cmd+9` |
| `zoom.actual` | `cmd+1` |
| `zoom.set:2` / `zoom.set:4` | `cmd+2` / `cmd+4` |
| `zoom.fill` | `cmd+shift+0` |
| `zoom.in` / `zoom.out` | `=` `+` `cmd+=` `cmd+shift+=` / `-` `cmd+-` |
| `zoom.keep` | `shift+z` |
| `view.fullscreen` | `f` `return` `ctrl+cmd+f` |
| `app.escape` | `esc` |
| `view.hud` / `view.hud_hide` | `i` / `tab` |
| `view.background` | `b` |
| `view.rotate_cw` / `view.rotate_ccw` | `r` `cmd+r` `>` / `shift+r` `cmd+l` `<` |
| `view.flip_h` / `view.flip_v` | `\|` / `_` |
| `view.play_pause` / `view.frame_prev` / `view.frame_next` | `k` / `,` / `.` |
| `file.trash` | `cmd+backspace` `forwarddelete` (fn+⌫) |
| `app.undo` / `app.redo` | `cmd+z` / `cmd+shift+z` |
| `file.move:ask` / `file.copy:ask` | `m` / `c` |
| `file.move:1`…`9` / `file.copy:1`…`9` | `opt+1`…`opt+9` / `opt+shift+1`…`opt+shift+9` |
| `file.reveal` | `cmd+shift+r` |
| `file.copy_image` / `file.copy_path` | `cmd+c` / `opt+cmd+c` |
| `file.open_with:editor` / `file.open_with_chooser` | `e` / `shift+e` |
| `meta.rate:0`…`5` | `0`…`5` |
| `meta.label:red` `yellow` `green` `blue` | `6` `7` `8` `9` |
| `meta.flag:pick` `reject` `none` | `p` `x` `u` |
| the same, then `nav.next` | `shift+` the key: `shift+3` rates 3 and advances, `shift+p` picks and advances |
| `app.config` | `cmd+,` |
| `view.help` | `?` `cmd+/` |
| `app.close` | `cmd+w` `q` |
| `app.quit` / `app.open` | `cmd+q` / `cmd+o` |

On other keyboard layouts the keys are matched as [above](#chord-syntax). A symbol that a layout
types only with option has no default key there, because option keeps the physical key: `]`
(`nav.jump:+10`) and `|` (`view.flip_h`) on German keyboards, `[` and `]` on Spanish ISO ones, `|`
on Swedish, Danish and French ones. The same goes for the number-row symbols of layouts that type
their digits with shift, since those keys are the digits (`-` on Lithuanian LST 1582). Bind other
keys for them if you use them:

```toml
[keys]
"shift+pageup" = "nav.jump:-10"
"shift+pagedown" = "nav.jump:+10"
"h" = "view.flip_h"
```

**Zoomed** (`[keys.zoomed]`, while zoomed in beyond fit): `left` `right` `up` `down` pan
(`pan.*`), `shift+left` `shift+right` `shift+up` `shift+down` jump to that edge (`pan.edge:*`).
`space`, `backspace` and the page keys keep navigating, so you can pixel-peep a sequence: turn on
`shift+z` (keep zoom), pan with the arrows, advance with space.

### Vim layer

`[keymap] vim = true` adds these on top of the defaults:

| Action | Keys |
|---|---|
| `nav.next` / `nav.prev` | `l` `j` `n` / `h` `k` `shift+n` |
| `nav.first` / `nav.last` | `g g` / `G` |
| `zoom.fit` / `zoom.actual` | `w` / `W` |
| `file.trash` | `d d` |
| `file.copy_image` / `file.copy_path` | `y y` / `y p` |
| `pan.center` | `M` |
| zoomed: `pan.left` `pan.down` `pan.up` `pan.right` | `h` `j` `k` `l` |
| zoomed: `pan.edge:left` `bottom` `top` `right` | `H` `J` `K` `L` |

The vim layer's `k` replaces `view.play_pause`; bind another key for it if you use both (`"s" = "view.play_pause"`).

## File actions in detail

### Trash and undo

`file.trash` moves the file to the Trash at once (a rename on the same volume) and shows the next image.
⌘Z puts it back where it was, for the whole session. Finder's "Put Back" may not know about files
trashed by apps, so use ⌘Z. A volume without a Trash reports an error; nothing is deleted silently.
If the Trash was emptied meanwhile, undo says so (`IMG_0042.jpg is no longer in the Trash`), and
the next ⌘Z goes on to the change before it.

### Move and copy

A target is either a slot name from `[slots]` or a path. Paths may start with `~`; a relative path
(`./_keep`, `../Selects`, or a slot such as `3 = "./_rejects"`) is resolved against **the folder of the
current image**, so it means "a subfolder next to this photo". `.` and `..` are resolved before use.
Missing folders are created. A file never overwrites another one: a name that is taken (even by a
broken symbolic link) becomes `name 2.jpg`, `name 3.jpg`, … (like Finder's Keep Both), decided by an
exclusive rename, so a file that appears at the last moment is not replaced either. Undo moves the file
back (or removes the copy). Copies, and moves to another volume, run in the background: the next image
shows at once, and a failure brings the file back. So do their undo and redo; another ⌘Z or ⇧⌘Z waits
until the one in progress has finished.

Safety rules:

- A symbolic link is moved, copied or trashed as the link; its target is never touched.
- A move to another volume copies first and removes the original only once the copy is complete. If
  the original cannot be removed (a read-only folder or card), the copy is removed again and the toast
  suggests copying instead.
- That move removes the original only if it is still the file that was copied. If another app saved
  a new version over it meanwhile (or renamed or removed it), the move ends as a copy and the original
  is left as it is (`IMG_0042.jpg changed during the move: copied to Card, original left as it is`).
  If the file was written to during the copy, the copy may be torn: it is removed again and nothing
  moves. Undo and redo of a move across volumes follow the same rule.
- Undo and redo leave a file alone if it was replaced or edited since the action (`IMG_0042.jpg was
  replaced or edited since it was copied: left as it is`). Renames and tag changes do not count as edits.
  A change that can never be undone (its file was replaced, edited or removed) is dropped after that
  message, so the next ⌘Z undoes the change before it. A failure that may pass, such as a read-only
  folder, keeps the change for another try.
- A read-only source or destination folder fails with a message such as `Cannot move IMG_0042.jpg:
  Permission denied`; nothing is moved or recorded. Messages name files and folders, not full paths.
- A file locked in Finder (Get Info › Locked) is copied with its lock, and cannot be moved, on the same
  volume or across volumes (`Cannot move IMG_0042.jpg: Operation not permitted (it is locked)`).
  Undoing a copy of it unlocks the copy to put it in the Trash.

`file.move:ask` (`m`) and `file.copy:ask` (`c`) open a menu of your slots. A slot whose name is one
character (`1`…`9`, `k`, …) is chosen with that key. Return picks the previous destination, and `o`
("Other Folder…") chooses any folder. `file.move:last` repeats the previous destination without asking.
Undoing a copy moves the copy to the Trash, as Finder does. Where there is no Trash (some network
shares), undo says so and leaves the copy alone; it never deletes the copy instead.

### Ratings, labels and flags

They are stored as Finder tags, so they show in Finder, survive copies and are searchable in Spotlight
(`tag:★★★`):

- **Rating**: one tag spelled with N `[rating] star` characters (`★★★` for 3). Setting a rating
  replaces the previous one; 0 removes it.
- **Label**: Finder's colour label. The tag uses the colour's name in your system language, so it is
  the same tag Finder's own colour menu sets.
- **Flag**: the tags `Pick` or `Reject`, never both.

Other tags on the file are kept. Every change can be undone. Lightroom, Bridge and Photo Mechanic read
XMP rather than Finder tags.

### exec commands

`exec:<command>` runs the command with `/bin/sh -c`, in the background; its output is discarded and a
toast reports a non-zero exit status. The file's values are passed in the command's **environment**,
never pasted into the command text, so no file name can run code (a photo named `$(rm -rf ~).jpg` is
just a name). Each placeholder becomes a reference to its variable:

| Placeholder | Variable | Example for `/Photos/Trip/IMG_0042.HEIC`, 42nd of 120 |
|---|---|---|
| `{path}` | `PEEKABOO_PATH` | `/Photos/Trip/IMG_0042.HEIC` |
| `{dir}` | `PEEKABOO_DIR` | `/Photos/Trip` |
| `{name}` | `PEEKABOO_NAME` | `IMG_0042.HEIC` |
| `{stem}` | `PEEKABOO_STEM` | `IMG_0042` |
| `{ext}` | `PEEKABOO_EXT` | `HEIC` |
| `{index}` | `PEEKABOO_INDEX` | `42` (1-based) |
| `{count}` | `PEEKABOO_COUNT` | `120` |

Quoting rules: the reference is quoted for where the placeholder stands, so every value stays exactly
one word, spaces and quotes included. You can write placeholders bare or inside quotes:

| You write | The shell runs |
|---|---|
| `open -R {path}` | `open -R "${PEEKABOO_PATH}"` |
| `echo "x {path}"` | `echo "x ${PEEKABOO_PATH}"` |
| `echo 'x {path}'` | `echo 'x '"${PEEKABOO_PATH}"''` |
| `cp {path} ~/Desktop/{name}` | `cp "${PEEKABOO_PATH}" ~/Desktop/"${PEEKABOO_NAME}"` |
| `echo "$(basename {path})"` | `echo "$(basename "${PEEKABOO_PATH}")"` |
| `printf %s $'{name}\n'` | `printf %s $''"${PEEKABOO_NAME}"$'\n'` |
| `echo $(({index} + 1))` | `echo $((${PEEKABOO_INDEX} + 1))` |

Inside `$((…))` quotes are a syntax error, so `{index}` and `{count}` (digits only) stand bare there;
the other placeholders stay quoted and the shell refuses them, rather than evaluate a file name as
arithmetic. `\{path}` and `${path}` are left as they are, and so is anything after a `#` comment. You can also use
the variables directly (`"$PEEKABOO_PATH"`); quote them yourself then. `{name}`, `{stem}` and `{ext}`
may start with `-`, so put `--` before them for commands that would read them as options; `{path}` and
`{dir}` always start with `/`. Do not pass placeholders to `eval` or `sh -c`, which would parse the
value as code again.

### Open with

`file.open_with:<app>` looks the argument up in `[apps]` first, then treats it as a path (if it contains
`/`), a bundle id (`com.apple.Preview`), or an app name (`Pixelmator Pro`, searched in `/Applications`,
`/System/Applications` and `~/Applications`). `file.open_with_chooser` (`shift+e`) lists the apps that
can open the file.

### Default viewer

Peekaboo registers for image types as an alternate viewer, so it appears in Finder's Open With menu
without taking over. Settings › General shows which app opens each image type and makes Peekaboo the
default for one type or all of them; `app.make_default` (Peekaboo menu, or bind it to a key) does all
of them, and so does Finder › Get Info › Open with › Change All….

## Examples

A culling setup: keepers and rejects next to the photos, one-key keep, rate-and-advance on plain keys.

```toml
[rating]
auto_advance = true

[slots]
1 = "./_keep"
2 = "./_rejects"
3 = "~/Pictures/Portfolio"
keep = "./_keep"

[keys]
"k" = "file.move:keep"
"shift+k" = ["file.copy:3", "nav.next"]
"tab" = "none"
```

Editors and scripts:

```toml
[apps]
editor = "com.pixelmatorteam.pixelmator.x"
preview = "com.apple.Preview"

[keys]
"ctrl+x o" = "exec:open -a ImageOptim {path}"
"ctrl+x c" = "exec:cp {path} ~/Desktop/"
"ctrl+x m" = "exec:sips -Z 2048 {path} --out ~/Desktop/{name}"
"o" = "file.open_with:preview"
```

Vim keys, a gray background and native full screen:

```toml
[keymap]
vim = true

[view]
background = "gray"

[fullscreen]
mode = "native"

[keys.zoomed]
"space" = "pan.down"
```
