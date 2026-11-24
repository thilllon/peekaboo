# Configuring Peekaboo

Peekaboo reads one TOML file. Every setting is optional: a missing key keeps its built-in default, and
an empty or missing file means "all defaults". Press **⌘,** (`app.config`) to create a starter file
with every setting commented out and open it in your default editor.

- [Where the file lives](#where-the-file-lives)
- [Reloading and errors](#reloading-and-errors)
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

Peekaboo never writes the file on its own. Only `app.config` (⌘,) creates it, and only when it does not
exist yet.

## Reloading and errors

Saving the file applies it immediately. Peekaboo watches both the file and its folder, so in-place
writes and atomic saves (vim, VS Code, BBEdit, TextEdit) are both picked up. `app.reload_config`
re-reads it on demand.

A file with a mistake is **not applied**: the previous configuration stays active, and a toast names
the first problem with its line number, for example:

```
config.toml:17: unknown action "nav.nxt" (did you mean "nav.next"?)
```

Unknown tables, unknown keys, wrong value types, unknown chords, unknown actions, unknown move/copy
slots, a chord bound twice in the same table and sequence conflicts are all errors.

### TOML subset

The file is standard TOML, limited to what the schema needs: `# comments`, `[table]` headers, bare,
quoted and dotted keys, basic strings (`"…"` with `\" \\ \n \t \uXXXX` escapes), literal strings
(`'…'`), integers, floats, booleans and arrays (which may span lines and end with a comma).
Multi-line strings, inline tables, arrays of tables and dates are not supported and are reported as
errors. Keys that contain `+`, `,`, `.` or spaces must be quoted: `"cmd+," = "app.config"`.

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
| `[keymap]` `defaults` | `true` | `false` starts from an empty keymap: only your `[keys]` apply |
| `[keymap]` `vim` | `false` | add the [vim layer](#vim-layer) on top of the defaults |
| `[slots]` *name* | none | a folder for `file.move:<name>` / `file.copy:<name>` (see [destinations](#move-and-copy)) |
| `[apps]` *name* | none | an app for `file.open_with:<name>`: a bundle id, an app name or a path |

`[slots]` named `1`…`9` are what `opt+1`…`opt+9` (move) and `opt+shift+1`…`opt+shift+9` (copy) use.
`[apps] editor` is what `e` opens.

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
- **Physical keys.** Chords match the key you press, translated through your ASCII-capable keyboard
  layout, not the character it types. Bindings keep working while a Korean, Japanese or other input
  method is active, and `opt+1` is the 1 key rather than `¡`.

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
| `app.config` | create the config file if needed and open it in your editor |
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

## File actions in detail

### Trash and undo

`file.trash` moves the file to the Trash at once (a rename on the same volume) and shows the next image.
⌘Z puts it back where it was, for the whole session. Finder's "Put Back" may not know about files
trashed by apps, so use ⌘Z. A volume without a Trash reports an error; nothing is deleted silently.

### Move and copy

A target is either a slot name from `[slots]` or a path. Paths may start with `~`; a relative path
(`./_keep`, `../Selects`, or a slot such as `3 = "./_rejects"`) is resolved against **the folder of the
current image**, so it means "a subfolder next to this photo". Missing folders are created. A file
never overwrites another one: a name that is taken becomes `name 2.jpg`, `name 3.jpg`, … (like
Finder's Keep Both). Undo moves the file back (or removes the copy).

`file.move:ask` (`m`) and `file.copy:ask` (`c`) open a picker: press a slot's key (`1`…`9`, or the
first character of a one-letter slot name), Return for the previous destination, or `o` to choose any
folder. `file.move:last` repeats the previous destination without asking.

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
toast reports a non-zero exit status. These placeholders are replaced, **already shell-quoted**, so
write them bare (`{path}`, not `"{path}"`):

| Placeholder | Example for `/Photos/Trip/IMG_0042.HEIC`, 42nd of 120 |
|---|---|
| `{path}` | `'/Photos/Trip/IMG_0042.HEIC'` |
| `{dir}` | `'/Photos/Trip'` |
| `{name}` | `'IMG_0042.HEIC'` |
| `{stem}` | `'IMG_0042'` |
| `{ext}` | `'HEIC'` |
| `{index}` | `'42'` (1-based) |
| `{count}` | `'120'` |

The environment also has `PEEKABOO_PATH`, `PEEKABOO_INDEX` (1-based) and `PEEKABOO_COUNT`.

### Open with

`file.open_with:<app>` looks the argument up in `[apps]` first, then treats it as a path (if it contains
`/`), a bundle id (`com.apple.Preview`), or an app name (`Pixelmator Pro`, searched in `/Applications`,
`/System/Applications` and `~/Applications`). `file.open_with_chooser` (`shift+e`) lists the apps that
can open the file.

### Default viewer

Peekaboo registers for image types as an alternate viewer, so it appears in Finder's Open With menu
without taking over. Run `app.make_default` (bind it to a key, or use Finder › Get Info › Open with ›
Change All…) to make it the default app for its image types.

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
