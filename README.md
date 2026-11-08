# MAC Commander

A dual-pane file manager for macOS in the Total Commander tradition — the Mac
counterpart of [DAZ Commander](https://github.com/Dazzer1234567/DAZ_Commander), with
the same features and interface. Native SwiftUI and AppKit, no dependencies.

## Build and run

```sh
./build.sh run      # build + launch
./build.sh          # release build only, produces "MAC Commander.app"
./build.sh debug    # faster build for iterating
```

You can also `open Package.swift` to work on it in Xcode. Drag the `.app` to
`/Applications` to keep it.

### Stopping the "would like to access your Downloads folder" prompt

macOS asks once per app identity, and an ad-hoc signature changes with every build. Run
`./make-signing-cert.sh` once: it creates a self-signed code-signing certificate called
"MAC Commander Local", which `build.sh` then signs with, so the identity stays the same
across rebuilds.

### Function keys

macOS keeps F5, F6 and friends for itself unless *System Settings ▸ Keyboard ▸ Keyboard
Shortcuts ▸ Function Keys ▸ "Use F1, F2, etc. keys as standard function keys"* is on, or
`fn` is held. Every function key therefore also has a ⌘ twin: **⌘ plus the digit**
(⌘5 = F5, ⌘6 = F6, ⌘7 = F7, …) and ⌥⌘ for the ⌥ ones (⌥⌘5 = ⌥F5 pack).

## The window

From top to bottom, as in DAZ Commander:

```
┌ workspace picker │ shortcut buttons …                │ + ⇩ ⇧ 🔍 ✎ ⚙ ┐   workspace toolbar
├ (extra rows of shortcuts, each with a − to remove it)               ┤
├ saved pane layouts …                                             + ┤   layout bar
├──────────────── left pane ────────┬─┬──────── right pane ─────────┤
│ drive list   free space       U   │V│ …                            │
│ path box                          │=│                              │
│ Name        Ext  Size  Date  Attr │↓│                              │   centre strip
│ ..                                │T│                              │
│ …                                 │P│                              │
│ status: files, dirs, selection    │…│                              │
├───────────────────────────────────┴─┴──────────────────────────────┤
│ /current/folder> command line                                       │
│ F3 View  F4 Edit  F5 Copy  F6 Move  F7 NewDir  F8 Delete  ⌘Q Exit   │
```

Colours come in **dark** and **light** (Settings ▸ Colours), DAZ Commander's palettes
exactly. **Interface size** (Settings ▸ Interface Size, ⌘+ / ⌘- / ⌘0) scales everything —
text, icons, buttons, panes and dialogs — from 75% to 200% in steps of 25%; everything is
laid out afresh at the new size rather than magnified, so text stays sharp.

Everything is remembered in `~/Library/Application Support/MACCommander/settings.json`,
written half a second after each change, so a crash or a kill loses nothing. A file that
cannot be read is kept as `settings.json.bad` rather than overwritten.

## Panes

Each pane has a **drive list** (this Mac's volumes, then the Tailscale computers — see
[Other computers](#other-computers)), the free space on its volume, a **U** button for up
one level, an editable **path box** (Enter goes there, Esc puts it back; `~` works, and so
does a path running on into an archive), the file list, and a status line: files, folders,
total size, then what is selected. The active pane is outlined in blue.

**Listing** — name, extension, size, date and attributes (`r` read-only, `h` hidden,
`l` link, `x` executable) in sortable columns: click a header to sort, again to reverse.
`..` always sits at the top, folders above files, and names sort the way the Finder sorts
them, so `file9` comes before `file10`. Apps (`.app`) are shown as files: they open.

**Type to filter** — typing letters narrows the pane to entries whose name starts with
them, and puts the cursor on the **most recently modified folder** among them (with no
folder left, the newest file), so Enter goes straight in. Backspace deletes a letter, Esc
clears it. Commands act only on rows the filter is showing.

**Selection** is Total Commander's: marking is separate from the cursor. Marked entries
turn red and stay marked while the cursor moves. Every command acts on the marked entries,
or on the one under the cursor when nothing is marked.

**Live** — a pane follows its folder as it changes on disk, keeping marks, cursor and
filter, and both panes catch up whenever the app comes back to the front.

**Long operations go to the background.** Copying, moving, deleting, packing and
unpacking show a small box in the bottom-right corner — the file being worked on, a bar,
how many are done, the percentage in its title — but only once the operation has run for
0.4 seconds. The boxes never take the keyboard, stack upwards when several run at once,
can be dragged by their title, and have their own Cancel. When one finishes, the listings
catch up quietly; only an operation too quick to show a box lands the cursor on what it
made.

## Keys

| Key | Action |
| --- | --- |
| `Tab` | Switch pane |
| `Return` | Open folder or archive, or open the file |
| `Backspace` | Delete a filter letter, or go up a level |
| `Space` | Mark / unmark the entry under the cursor |
| `Insert` (Help) | Mark and move down |
| `⌘A` | Mark all |
| `*`, `+`, `-` on the keypad | Invert marks; mark / unmark by wildcard (`*.txt;*.log`). Also ⌥⌘I, ⌥⌘=, ⌥⌘- |
| `Esc` | Clear the filter, then the marks |
| *letters* | Filter to entries starting with them |
| `F3` | View (text or hex) |
| `F4` | Open in the editor (TextEdit unless `editor` is changed in settings.json) |
| `F5` / `F6` | Copy / move to the other pane. The box offers the destination; a full path for one item copies and renames |
| `⌥F5` / `⌥F9` | Pack into a zip file / unpack |
| `⌥F7` | Find files |
| `F2`, `⇧F6` | Rename in place, name selected but not the extension |
| `F7` | New folder, named after the folder under the cursor, fully selected |
| `F8`, `⌦` | Delete to the Trash |
| `⇧F8`, `⇧⌦` | Delete permanently |
| `⌥Return` | Get Info |
| `⌥F1` / `⌥F2` | Drive list of the left / right pane |
| `⌘←` / `⌘→` | Show the highlighted folder in the other pane |
| `⌘U` | Swap panes |
| `⌘R` | Refresh both panes |
| `⌘H`, `⇧⌘.` | Show hidden files |
| `⌘+` / `⌘-` / `⌘0` | Interface bigger / smaller / 100% |
| `⌘M` | Multi-rename tool |
| `⇧⌘C` | Terminal in the active pane's folder |
| `⇧⌘E` | The active folder in the Finder |
| `⌘Z` | Undo the last copy, move or rename (up to 20) |
| `⌘[` / `⌘]` | Back / forward through the pane's history |
| `⌘Y` | Look inside an archive without going in |
| `⌘D` / `⌘L` | Bookmark this folder / add it to the toolbar |
| `⌥⌘P` / `⌥⌘F` | Copy name / full path |

⌘H and ⌘M are taken from the system's Hide and Minimize, as Ctrl+H and Ctrl+M are in DAZ
Commander; Hide is still in the app menu and Minimize in the Window menu.

The **command line** runs in the active pane's folder: `cd <path>` moves the pane,
anything else runs in Terminal.

## Mouse

| | |
| --- | --- |
| Double-click | Open folder or archive, or open the file |
| Click, pause, click | **Rename in place**, caret where the second click landed. Return renames; Esc or clicking elsewhere abandons it |
| Right-click | Mark the row — not a menu |
| `⌘`-click | Toggle the mark on one row |
| `⇧`-click | Mark everything between the cursor and the click |
| Drag to the other pane | **Copy** into the folder it shows, or the folder row it is dropped on. No dialog |
| `⌘`-drag | **Move** instead; what counts is whether ⌘ is held at the drop |
| Thumb buttons | Back goes up a level, forward goes into the highlighted folder, in the pane under the pointer |

Files can be dragged to and from the Finder too.

While renaming, the name is selected without its extension and the caret sits where you
clicked: typing adds there, Backspace rubs out the character behind it, ⌦ clears the
selected name, and the arrows step from the click point.

## Workspace toolbar

Shortcut buttons, grouped into **workspaces**; one workspace shows at a time. The picker
on the left switches workspace (right-click it to rename or delete); the gear manages them.
There is always at least one, and names are unique.

**Adding a shortcut:** drag a folder, app or file onto a bar, from a pane or the Finder.
Apps arrive icon only; everything else keeps its label. Dropping the same thing twice on
a row is refused with a note; dropping one that is on another row moves it here.

Clicking a shortcut shows its folder in the active pane — a link, not a switch: it goes to
its folder every time — or opens anything else. Files dropped on an app's button open in
that app. **⌘-click** (or right-click ▸ Properties) opens its properties: label, show the
text, full path, icon (Library… from the bundled set, File… from any image, `.icns` or
app, Default), and a vertical **icon size** slider that resizes the button live. Delete
shortcut sits apart in red.

The **+** adds another row of shortcuts under the bar; each extra row has a **−** that
removes it, moving its shortcuts up a row. The **pencil** turns on rearranging: drag the
buttons into the order you want, across rows too. The zip, unzip and magnifier buttons
pack, unpack and find files.

**Icon library** — the `.ico` and `.svg` files in [Resources/buttons/](Resources/buttons/)
are bundled into the app and offered by Library…; subfolders become groups. Add more by
dropping files in and rebuilding. One-colour SVGs are drawn in the theme's text colour and
follow it; coloured ones keep their colours; and each drawing is fitted to the button by
its own outline, not its canvas.

## Saved pane layouts

The second bar remembers pairs of folders, one per pane, and restores both with one click.
**+** saves both panes as they are and asks for a name (pre-filled with the two folder
names) and a width (70–600). ⌘-click or right-click ▸ Properties renames, resizes or
deletes; right-click ▸ Update to current panes repoints it. Layouts are kept per
workspace. A layout whose folder has gone leaves that pane where it is.

## Centre strip

The column between the panes holds the shared commands, and is also the splitter — drag
anywhere on it that is not a button.

| Button | Action |
| --- | --- |
| `V` | Go to `/Volumes` in the active pane (⌘-click to point it elsewhere) |
| `=` | **Match** — show the active pane's folder in the other pane |
| `↓` | **Quick folder** — go to a folder you choose (⌘-click to choose) |
| `T` | **Scratchpad**, a toggle — turns the active pane into a plain-text editor and back |
| `P` / `FP` | Copy the **name** / **full path** of the marked entries, or the one under the cursor |
| 🔍 | Find files |

Folders and apps dropped on the strip become buttons on it. Every button has properties
(⌘-click), where its icon is chosen. The pencil at the foot rearranges the strip.

**Scratchpad** — each pane has its own, so both can be open side by side. Everything
typed or pasted is reduced to what ISO 8859-1 holds: curly quotes straighten, dashes
become `-`, `…` becomes `...`, odd spaces become ordinary ones, zero-width marks go, `€`
`™` `•` `→` are spelled out, accented Latin is kept, other accents fold to the base letter,
and CJK and emoji are dropped. Paste takes the plain-text flavour only, so formatting never
comes along.

## Archives

Return or double-click on an archive and the pane goes inside: the path box shows the
archive's own path carried on into it, `/work/pack.zip/docs`, and `..` climbs back out.
Such a path can be typed, saved in a layout, and is restored at the next start. Archives
are read with `bsdtar`, which ships with macOS: zip, tar and its compressed kinds, 7z,
iso, and rar. Nothing is unpacked to list one.

Inside an archive, F5 copies out (asking once about anything that would be overwritten),
F3 views, Return opens a temporary copy; changing anything is refused with an explanation.

**Packing** (⌥F5) makes a zip file from the marked entries, offered in the other pane's
folder: also pack path names, recurse into subfolders, move to archive (originals go to
the **Trash**, and only those that went in whole), separate archives, compression level.
A zip file that is there is replaced, after asking. It is written under a temporary name
and read back before it takes its own, so nothing is left half made.

**Unpacking** (⌥F9) unpacks the marked archives — any kind bsdtar reads — or, inside one,
the marked entries, into the other pane's folder: masks (`*.txt;*.md`, `|` to exclude),
path names on or off, overwrite, each archive into its own folder. Names that would climb
out of the destination are dropped, and `:` becomes `_`.

## Multi-rename tool

⌘M over the marked entries. Name and extension masks with `[N]`, `[N2-5]`, `[N3-]`,
`[N2,3]`, `[E]`, `[C]`, `[C100+5:4]`, `[Y] [M] [D] [h] [m] [s] [d] [t]`, `[P]`, `[G]`;
search and replace as text or regular expression with capture groups; case conversion;
live preview with a status per row (`name clash`, `already exists`, `invalid name`).
Renames go through temporary names, so names can be swapped, and **Undo rename** puts the
last batch back.

## Find files

⌥F7, the toolbar magnifier or the centre strip. Masks with exclusions, several start
folders, subfolders and hidden files on or off, text containing (case, whole words,
regex, NOT containing), size and date limits. Results stream in while it searches;
**Go to file** puts the cursor on one, **Feed to listbox** fills the active pane with all
of them.

## Other computers

The drive list also offers the computers on your **Tailscale** network (asked of the
Tailscale app in the background, and again each time the list opens). Pick one and the pane
lists the folders it shares, whole drives such as `C$` included; go into one and macOS
mounts it under `/Volumes`, asking for a login itself if it needs one (with "Remember this
password in my keychain"). From the top of a share, `..` goes back to the list of shares.
Any computer can be typed as `smb://name` or `smb://name/share`. A computer that is off is
said within a few seconds rather than after the system's half-minute timeout.

Listing a computer's shares uses a login already in the keychain; the first time, type
`smb://computer/share` once and log in when asked. To see another Windows PC's whole drives,
see DAZ Commander's README, "Whole drives".

## Kept from the earlier MAC Commander

Undo (⌘Z), bookmarks (Go menu, ⌘D), back/forward history, looking inside an archive
(⌘Y), browsing non-zip archives, and the Replace / Skip / Keep Both question when a copy
meets a file of the same name. Folders pinned to the old top bar become shortcuts in the
first workspace.

## Layout

```
Sources/MACCommander/
  App.swift                 entry point, menus and shortcuts
  Models/
    Settings.swift          settings.json: workspaces, shortcuts, layouts, centre strip
    AppState*.swift         panes, commands, workspaces, zip commands, dialogs, undo
    PaneModel.swift         one pane: listing, cursor, marks, filter, history, watching
    FileItem.swift          one row, sorting, summary line, masks
    Transfer.swift          copy/move/delete engine and the background job boxes
    ArchiveService/Index    bsdtar listing and extraction
    ZipPacker/ZipUnpacker   packing and unpacking
    RenameEngine.swift      multi-rename rules
    FileSearch.swift        find files
    PlainText.swift         the scratchpad's ISO 8859-1 reduction
    NetworkPlaces.swift     Tailscale, SMB shares, mounting
    IconLibrary.swift       bundled icons, SVG tinting and fitting
  Views/
    ContentView.swift       window layout
    Bars.swift              toolbar, layout bar, centre strip, command line, F-keys, job boxes
    PaneView.swift          drive bar, path box, scratchpad
    FileListView.swift      the file list (AppKit table) and in-place rename
    Theme.swift             palettes, interface size, button style, glyphs
    *Sheet.swift            the dialogs
Resources/buttons/          the icon library
```
