# Lite XL

[![CI]](https://github.com/lite-xl/lite-xl/actions/workflows/build.yml)
[![Discord Badge Image]](https://discord.gg/RWzqC3nx7K)

![screenshot-dark]

A lightweight text editor written in Lua, adapted from [lite].

* **[Get Lite XL]** — Download for Windows, Linux and Mac OS.
* **[Get plugins]** — Add additional functionality, adapted for Lite XL.
* **[Get color themes]** — Add additional colors themes.

Please refer to our [website] for the user and developer documentation,
including [build] instructions details. A quick build guide is described below.

Lite XL has support for high DPI display on Windows and Linux and,
since 1.16.7 release, it supports **retina displays** on macOS.

Please note that Lite XL is compatible with lite for most plugins and all color themes.
We provide a separate lite-xl-plugins repository for Lite XL, because in some cases
some adaptations may be needed to make them work better with Lite XL.
The repository with modified plugins is https://github.com/lite-xl/lite-xl-plugins.

The changes and differences between Lite XL and rxi/lite are listed in the
[changelog].

## This fork

Lite XL 2.1 (plugin API mod-version 3) with our changes on top, merged from
upstream's `release/v2.1.x`. Additions to the editor:

* **Tab overflow:** tabs scroll when they don't fit, with scroll buttons and a menu
  of all tabs at the end of the tab bar.
* **Tab tooltips and menu:** hovering a tab shows the file's full path, size and
  age (and git state, with gitfiles); right clicking it offers close others / to
  the right / all and copy path.
* **Reopen closed tab:** ctrl+shift+t reopens the file whose tab was closed last
  (again for the one before), beside the tab that was next to it, at the cursor
  and scroll it had. Recent files (`core.recent_files`, kept between sessions)
  are ordered by when they were closed.
* **Tooltips** behave alike and as usual elsewhere (`core.tooltip`): shown after
  `config.tooltip_delay`, kept while the pointer stays on their target, and shown
  at once when moving from one to another.
* **Popups** (context menus, tooltips, autocomplete, ...) share theme colors
  (`style.popup_background`, `style.popup_border`) and can cast a soft shadow
  (`style.popup_shadow`).
* **Status bar:** items that don't fit are dropped by priority, and items can open
  menus (e.g. indentation and line endings).
* **Idle means idle:** background work (language servers, terminals, file watching)
  wakes the editor only when there's data, so an idle editor uses no CPU.
* **Key bindings:** those made in the user module come before plugins'
  (no matter that plugins load later), and `config.plugin_keys` chooses which
  of a plugin's bindings to keep (`{ build = { "f6" }, debugger = false }`);
  `keymap.origin` records which plugin added each.
* **Ctrl+P modes**, as in VS Code: `>` runs a command, `:` goes to a line, and
  with lsp `@` finds a symbol in the file and `#` one in the workspace
  (`command.find_file_modes`). The empty box lists them.
* **Touch:** tap to click, drag to scroll.
* **Borderless window** (`config.borderless`): the title strip moves the window
  (but not the buttons on it, `system.set_window_hit_test`'s rects), a double-click
  on it maximizes or restores, and every edge resizes.
* **File browser:** keeps its width and visibility between sessions, and
  dragging its divider narrower than `config.plugins.treeview.collapse_size`
  collapses it (toggling reopens it at the width it had before the drag).
  Hovering an entry shows its path, size and age (a folder's entry count); while
  it's focused, the status bar shows the selected entry and the project's file
  count, warning when it's over `config.max_project_files`.
* **Command view:** clicking a suggestion (ctrl+p, Do Command, ...) submits it.
* **System file dialogs:** `core:open-file-picker`, `doc:save-as-picker` and the
  folder commands' `-picker` versions (from upstream master's SDL3 dialogs); the
  menubar's File menu uses them, while key bindings keep the command view.
* **Block select:** `doc:select-block`, bound to a click (e.g.
  `keymap.add { ["alt+1lclick"] = "doc:select-block" }`), selects a rectangle
  while dragging.
* **For plugins:** antialiased vector drawing (`renderer.draw_path`,
  `renderer.draw_glyph`), per-font letter spacing (`font:set_letter_spacing`),
  background marks on lines
  (`DocView:get_line_marks`), `command.hidden` for commands that exist only
  for key bindings (not listed by Do Command or menus),
  `View:get_name_style` (the font of a view's name in tabs and tab lists),
  `View:get_icon` (the icon shown with it; the treeview gives docs their file's),
  `View:is_transient` (views the workspace doesn't restore),
  facts in tooltips (`TreeView:get_item_info`, `RootView:get_tab_tooltip_info`),
  multi-line status bar tooltips,
  `system.open_url` (opens a URL with the system's default handler), context
  menu items built when the menu opens (`ContextMenu:register` with a function), and
  threads that wait for events rather than time (`core.wait_for`, `core.wake`,
  `core.watch_readable` with `process:watch_source`).

### Add-ons

`addons/` holds the add-ons we changed or wrote, as an [lpm] repository (listed in
`manifest.json`, each entry saying what we changed). `scripts/lpm` runs our fork of
lpm (`lpm/`, built with the editor), which fixes installs replacing an add-on with
another repository's version, uninstalls removing dependents under `--assume-yes`,
2.1's mod-version, and symlinked installs across filesystems. Ours:

* **menubar:** a menu bar of commands, toggled by tapping Alt. Menus are
  `config.plugins.menubar.menus`; commands from plugins not placed in a menu are
  listed per plugin under Tools. File > Open Recent lists recent files that aren't
  open, the one closed last first, and projects.
* **headerbar:** one strip at the top in place of the title bar and toolbars: a
  menu button (menubar's menus as one dropdown), a file browser toggle,
  back/forward (navigate, dimmed when there's nowhere to go) and, with
  `config.borderless`, the title and the window controls.
* **highlight_selection:** marks the other occurrences of the selected text (whole
  words only when a whole word is selected), in `style.selection_match`.
* **search_ui** (imported, with our changes): a "Highlight All" option marking every
  match in `style.search_match`; the replace row shows only when wanted (ctrl+r,
  or the chevron left of the search box).
* **terminal** (imported from lite-xl-terminal, with our changes): an integrated
  terminal, as a drawer (shift+alt+t) or a tab (ctrl+shift+\`). ctrl+f
  searches it in search_ui's pane, newest output first (`search_backward`). Its C
  module is built by our meson build and linked into the user dir by `scripts/run.sh`.
* **spellcheck:** spell checking with hunspell (`/usr/share/hunspell/en_US` by
  default), off until `spell-check:toggle` turns it on for a document. Identifiers
  are checked by their camelCase / snake_case parts; the syntax's keywords, ALL
  CAPS words and URLs or paths are skipped. Right click a marked word for
  suggestions or "Add to Dictionary" (`spellcheck_words.txt` in the user dir).
  "Spell" on the status bar shows whether it's on and toggles it. Its
  C module is built by our meson build when libhunspell is found.
* **ephemeral_tabs** (imported, with our changes): a file opened while browsing
  (a click in the tree, go to definition, a search result, ...; callers pass
  `{ preview = true }` to `RootView:open_doc`) replaces the previous preview tab
  until edited or double-clicked; ctrl+p and ctrl+o open normal tabs. Preview tabs
  show their name in italic (in tabs, the tab menu and the ctrl+tab list) and
  aren't restored with the workspace or listed in File > Open Recent until they
  become normal tabs.
* **openurl:** ctrl+click opens the URL or DOI under the mouse in the browser
  (DOIs via `config.plugins.openurl.doi_url`), or a `[[wiki link]]` to a local file
  (`name`, `name.md`, ... in the file's directory or a parent; `[[name#Heading]]`
  jumps to the heading), or the path of an existing file, with an optional
  `:line:col` (relative to the file's directory or a project directory); links are
  underlined unless `underline = false`. With ctrl held, what ctrl+click would open
  is underlined, including lsp's go-to-definition targets. "Search Web" in the
  context menu searches for the selection (`search_url`).
* **gitfiles:** in a git repository, the project's files (tree view, ctrl+p,
  project search) are those git doesn't ignore, hidden ones included, rather than
  what `config.ignore_files` lets through; untracked files are green in the tree
  view. "Show All Files" in the tree view's context menu shows everything but
  `.git` (ignored files dimmed), per project. With the tree view focused, the
  status bar shows the branch, ahead/behind and counts of changed and untracked
  files; tooltips show a file's git state.
* **navigate** (imported, rewritten): alt+left / alt+right go back and forward
  through the places the cursor jumped from (another file, or a move of more than
  `config.plugins.navigate.jump_threshold` lines), alt+shift+left / alt+shift+right
  within the current file only.
* **shapes:** antialiased shape helpers (squiggly underlines) for plugins.
* **qtcreator:** a light color theme matching Qt Creator's.

Also imported with changes: lsp and lintplus (squiggly diagnostics, diagnostics in
hover popups), build and debugger (from lite-xl-ide), tab_switcher, tab_overflow,
minimap, nerdicons, language_yaml, the widget library, and repl (evaluates Lua in
a running editor).

## Overview

Lite XL is derived from [lite].
It is a lightweight text editor written mostly in Lua — it aims to provide
something practical, pretty, *small* and fast easy to modify and extend,
or to use without doing either.

The aim of Lite XL compared to lite is to be more user friendly,
improve the quality of font rendering, and reduce CPU usage.

## Customization

Additional functionality can be added through plugins which are available in
the [plugins repository] or in the [Lite XL plugins repository].

Additional color themes can be found in the [colors repository].
These color themes are bundled with all releases of Lite XL by default.

## Quick Build Guide

If you compile Lite XL yourself, it is recommended to use the script
`build-packages.sh`:

```sh
bash build-packages.sh -h
```

The script will run Meson and create a tar compressed archive with the application or,
for Windows, a zip file. Lite XL can be easily installed
by unpacking the archive in any directory of your choice.

Otherwise the following is an example of basic commands if you want to customize
the build:

```sh
meson setup --buildtype=release --prefix <prefix> build
meson compile -C build
DESTDIR="$(pwd)/lite-xl" meson install --skip-subprojects -C build
```

where `<prefix>` might be one of `/`, `/usr` or `/opt`, the default is `/`.
To build a bundle application on macOS:

```sh
meson setup --buildtype=release --Dbundle=true --prefix / build
meson compile -C build
DESTDIR="$(pwd)/Lite XL.app" meson install --skip-subprojects -C build
```

Please note that the package is relocatable to any prefix and the option prefix
affects only the place where the application is actually installed.

## Installing Prebuilt

Head over to [releases](https://github.com/lite-xl/lite-xl/releases) and download the version for your operating system.

### Windows

Lite XL comes with installers on Windows for typical installations.
Alternatively, we provide ZIP archives that you can download and extract anywhere and run directly.

To make Lite XL portable (e.g. running Lite XL from a thumb drive),
simply create a `user` folder where `lite-xl.exe` is located.
Lite XL will load and store all your configurations and plugins in the folder.

### macOS

We provide DMG files for macOS. Simply drag the program into your Applications folder.

> **Important**
> Newer versions of Lite XL are signed with a self-signed certificate,
> so you'll have to follow these steps when running Lite XL for the first time.
>
> 1. Find Lite XL in Finder (do not open it in Launchpad).
> 2. Control-click Lite XL, then choose `Open` from the shortcut menu.
> 3. Click `Open` in the popup menu.
>
> The correct steps may vary between macOS versions, so you should refer to
> the [macOS User Guide](https://support.apple.com/en-my/guide/mac-help/mh40616/mac).
>
> On an older version of Lite XL, you will need to run these commands instead:
> 
> ```sh
> # clears attributes from the directory
> xattr -cr /Applications/Lite\ XL.app
> ```
>
> Otherwise, macOS will display a **very misleading error** saying that the application is damaged.

### Linux

Unzip the file and `cd` into the `lite-xl` directory:

```sh
tar -xzf <file>
cd lite-xl
```

To run lite-xl without installing:
```sh
./lite-xl
```

To install lite-xl copy files over into appropriate directories:

```sh
rm -rf  $HOME/.local/share/lite-xl $HOME/.local/bin/lite-xl
mkdir -p $HOME/.local/bin && cp lite-xl $HOME/.local/bin/
mkdir -p $HOME/.local/share/lite-xl && cp -r data/* $HOME/.local/share/lite-xl/
```

If `$HOME/.local/bin` is not in PATH:

```sh
echo -e 'export PATH=$PATH:$HOME/.local/bin' >> $HOME/.bashrc
```

To get the icon to show up in app launcher:

```sh
xdg-desktop-menu forceupdate
```

You may need to logout and login again to see icon in app launcher.

To uninstall just run:

```sh
rm -f $HOME/.local/bin/lite-xl
rm -rf $HOME/.local/share/icons/hicolor/scalable/apps/lite-xl.svg \
          $HOME/.local/share/applications/org.lite_xl.lite_xl.desktop \
          $HOME/.local/share/metainfo/org.lite_xl.lite_xl.appdata.xml \
          $HOME/.local/share/lite-xl
```


## Contributing

Any additional functionality that can be added through a plugin should be done
as a plugin, after which a pull request to the [Lite XL plugins repository] can be made.

Pull requests to improve or modify the editor itself are welcome.

## Licenses

This project is free software; you can redistribute it and/or modify it under
the terms of the MIT license. See [LICENSE] for details.

See the [licenses] file for details on licenses used by the required dependencies.


[CI]:                         https://github.com/lite-xl/lite-xl/actions/workflows/build.yml/badge.svg
[Discord Badge Image]:        https://img.shields.io/discord/847122429742809208?label=discord&logo=discord
[screenshot-dark]:            https://user-images.githubusercontent.com/433545/111063905-66943980-84b1-11eb-9040-3876f1133b20.png
[lite]:                       https://github.com/rxi/lite
[lpm]:                        https://github.com/lite-xl/lite-xl-plugin-manager
[website]:                    https://lite-xl.com
[build]:                      https://lite-xl.com/en/documentation/build
[Get Lite XL]:                https://github.com/lite-xl/lite-xl/releases/latest
[Get plugins]:                https://github.com/lite-xl/lite-xl-plugins
[Get color themes]:           https://github.com/lite-xl/lite-xl-colors
[changelog]:                  https://github.com/lite-xl/lite-xl/blob/master/changelog.md
[Lite XL plugins repository]: https://github.com/lite-xl/lite-xl-plugins
[plugins repository]:         https://github.com/rxi/lite-plugins
[colors repository]:          https://github.com/lite-xl/lite-xl-colors
[LICENSE]:                    LICENSE
[licenses]:                   licenses/licenses.md
