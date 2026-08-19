# MAC Commander

A deliberately small dual-pane file browser for macOS, in the spirit of Total
Commander. Native SwiftUI, no dependencies.

## Build and run

```sh
./build.sh run      # build + launch
./build.sh          # release build only, produces "MAC Commander.app"
./build.sh debug     # faster build for iterating
```

You can also `open Package.swift` to work on it in Xcode.

The result is a normal `MAC Commander.app` — drag it to `/Applications` if you
want to keep it.

## Stopping the "would like to access your Downloads folder" prompt

macOS asks once per app identity. An ad-hoc signature — the fallback this
project uses — identifies an app by the hash of its binary, and that hash
changes on every rebuild, so each build looks like a brand-new app and gets
asked all over again.

Run this once to fix it for good:

```sh
./make-signing-cert.sh
```

It creates a self-signed code-signing certificate called "MAC Commander Local"
in your keychain. It asks for your login password (to import the key) and an
admin password (to trust it for code signing). `build.sh` then signs with that
identity instead of ad-hoc, the identity stays the same across rebuilds, and you
grant folder access one final time.

If you would rather do it by hand: Keychain Access ▸ Certificate Assistant ▸
Create a Certificate, name it `MAC Commander Local`, type "Code Signing",
self-signed. `build.sh` finds it by name.

## What it does

- **Two independent panes**, each with its own history, sort order and filter.
- **Shortcuts in the top bar** — a Downloads button plus your links. They all
  open in whichever pane is active, and clicking one never steals the focus, so
  the pane you were working in is the one that moves.
- **Link** (`⌘L`, or the button in the bottom bar) pins whichever folder the
  active pane is currently showing to the top bar. Links survive restarts;
  right-click one to remove it.
- **Drop files onto a pane to move them there**, from Finder or another app. The
  pane outlines itself while you hover, and the same conflict dialog applies.
  Dragging *between* the two panes is not wired up — see Known gaps.
- **Copy and move between panes** with a conflict dialog (Replace / Skip / Keep
  Both, with "apply to all"). Transfers run off the main thread with a progress
  bar and a Cancel button.
- **Undo** (`⌘Z`, or the button in the bottom bar) reverses the last copy, move,
  drag-drop or rename, and keeps going back through the last 20. Undoing a move
  or rename puts the file back where it was; undoing a copy trashes the copy it
  made. It refuses to overwrite anything that has appeared at the original
  location in the meantime, and says so instead.
- **Delete to Trash** — never a permanent unlink, so mistakes are recoverable.
  Choosing Replace in the conflict dialog also trashes the file it replaces
  rather than deleting it.
- **Rename** and **New Folder**.
- **Quick filter** per pane (⌘F) that narrows the list as you type.
- **Path** copies just the name of what you have selected (`report.pdf`), and
  **Full** copies the whole path from the disk root
  (`/Users/you/Downloads/report.pdf`). With several rows selected you get one per
  line; with nothing selected you get the folder the pane is showing.
- **Bookmarks** — per-pane menu, the Go menu, and a manage sheet you can
  reorder. Stored in `UserDefaults`.
- The big red arrow on the right of each pane header goes **up one level**, every
  press, until it greys out at the top level. It ignores history on purpose, so
  it can never bounce between two folders.
- **The extension has its own column**, so a long filename can truncate in the
  middle while you can still always see that it is a `wav`. The Name column
  therefore shows the name without its extension. Folders and files with no
  extension leave the column empty, and a dotfile like `.gitignore` keeps its
  whole name. Click the Ext header to group by type.
- Folders always sort above files; click a column header to change the sort.
- Panes auto-refresh when their folder changes on disk, so a copy shows up in
  the other pane immediately.

- **Browse inside archives.** Press Return or double-click a zip (or tar.gz, 7z,
  iso, rar…) and the pane steps into it, listing its contents with real sizes and
  dates. Descend through folders, use the breadcrumb, filter, mark with Space —
  it behaves like any other folder. Going up walks back out into the folder
  holding the archive.

  Nothing is unpacked to do this: the listing comes from the archive's table of
  contents, so opening a large archive is immediate rather than a wait. Archives
  are **read-only** here — copy out with F5, but rename, delete, move and New
  Folder are refused with an explanation. Opening a file inside one extracts a
  throwaway copy to open, so edits do not travel back into the archive.
- **Look inside an archive** (`⌘Y`, or the Peek button) lists its top level
  without stepping into it — a glance rather than a visit.
- **Extract** (`⌘E`, or Unzip in the centre strip) unpacks the marked archives
  into the other pane, each into its own folder named after the archive, so
  nothing spills loose. Undo removes what it created.

Archive support is `bsdtar`, which ships with macOS: zip, tar and its compressed
variants, 7z, iso, and rar read-only. No third-party dependency.

Deliberately not included: writing into archives (creating them, or adding to
one), nested archives opened in place, FTP/SFTP, multi-rename, file compare,
tabs, a built-in viewer or editor.

## Known gaps

- **Dragging rows between the panes.** Attaching SwiftUI's `.draggable` to table
  rows made ordinary clicking unreliable and stopped double-click from opening
  folders, because the drag recognizer competes with the table's own click
  handling. It was removed to keep clicking solid. Doing this properly needs an
  AppKit `NSTableView` drag source rather than the SwiftUI modifier. Use F6 /
  ⇧⌘M to move in the meantime.
A single click on the inactive pane activates the pane *and* selects the row you
clicked. See `PaneClickWatcher.swift` for why that needs an event monitor rather
than a gesture.

## Keyboard

Every command lives in the menus too, so nothing is keyboard-only.

| Action | Shortcut | Alternate |
| --- | --- | --- |
| Switch pane | `Tab` | `⌘\` |
| Enter folder / open file | `Return` | `⌘↓` |
| Enclosing folder | `Delete` | `⌘↑`, or the red arrow in the pane header |
| Back / Forward through history | `⌘[` / `⌘]` | |
| Undo last copy / move / rename | `⌘Z` | |
| Rename | `F2` | `⇧⌘E` |
| Copy to other pane | `F5` | `⇧⌘C` |
| Move to other pane | `F6` | `⇧⌘M` |
| New folder | `F7` | `⇧⌘N` |
| Move to Trash | `F8` | `⌘⌫` |
| Filter this folder | `⌘F` | |
| Select all / invert / none | `⌘A` / `⇧⌘A` / `⇧⌘D` |
| Show hidden files | `⇧⌘.` | |
| Swap panes | `⌘U` | |
| Point other pane here | `⇧⌘=` | |
| Bookmark this folder | `⌘D` | |
| Link this folder to the top bar | `⌘L` | |
| Reveal in Finder | `⇧⌘R` | |
| Open Terminal here | `⇧⌘T` | |
| Look inside an archive | `⌘Y` | |
| Extract to other pane | `⌘E` | |
| Copy name only ("Path" button) | `⌥⌘P` | |
| Copy full path ("Full" button) | `⌥⌘F` | |
| Refresh both panes | `⌘R` | |

### About the function keys

By default macOS keeps F5, F6 and friends for itself (dictation, Do Not
Disturb), so they never reach the app. Two ways around it:

- Hold `fn` — `fn`+`F5` works as F5, or
- turn on *System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Function Keys ▸
  "Use F1, F2, etc. keys as standard function keys"*.

If you would rather not touch that setting, the alternates in the table above do
the same jobs.

## Layout

```
Sources/MACCommander/
  App.swift              app entry point + all menu commands and shortcuts
  Models/
    FileItem.swift       one directory entry and its display formatting
    PaneModel.swift      per-pane state: contents, sort, filter, history, watcher
    AppState.swift       the two panes, which one is active, the file commands
    Transfer.swift       copy/move/trash engine, conflict resolution, progress
    Bookmarks.swift      bookmark list, persisted to UserDefaults
    ArchiveService.swift bsdtar wrapper: listing, indexing, extraction
    ArchiveIndex.swift   an archive's table of contents, bucketed by folder
  Views/
    ContentView.swift    window layout, F-key bar, progress bar, sheet routing
    PaneView.swift       one pane: breadcrumb, filter, file table, footer
    Sheets.swift         rename, new folder, trash confirm, conflict, bookmarks
Resources/Info.plist     bundle metadata and folder-access usage strings
build.sh                 builds and signs the .app
make-signing-cert.sh     one-off: stable signing identity, run once
```
