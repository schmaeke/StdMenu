# StdMenu

A dmenu for macOS: it reads lines on stdin, lets you pick one in a small search window, and prints
it on stdout. App launching, emoji and anything else are shell pipelines bound to global hotkeys.

A resident agent owns the hotkeys and keeps the window ready; the `stdmenu` command is a thin client
that talks to it over a Unix socket, so a menu appears without application start-up delay. Results
are ranked synchronously and deterministically, so the list never changes under the cursor.

## Build and install

Needs macOS 14 or later and the Command Line Tools with Swift 6 (`xcode-select --install`); Xcode is
not needed.

    make            # builds build/StdMenu.app
    make install    # ~/Applications/StdMenu.app, ~/.local/bin/stdmenu, a default config,
                    # and starts the agent at login
    make uninstall  # leaves ~/.config/stdmenu and the log in place

To use `stdmenu` in a terminal, `~/.local/bin` must be on your `PATH`, for example with
`export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`. Hotkey commands find it either way. Install
elsewhere with `make install APPDIR=… BINDIR=…`.

The agent runs as the launchd job `dev.schmaeke.stdmenu`. Restart it with
`launchctl kickstart -k gui/$(id -u)/dev.schmaeke.stdmenu`; it logs to `~/Library/Logs/stdmenu.log`.

## Usage

    stdmenu [-0] [-p prompt] [-l lines]  pick a line from stdin, print its value (exit 1 if cancelled)
    stdmenu -f query                     print the values of stdin ranked against query, without a window
    stdmenu --paste                      paste stdin into the frontmost application
    stdmenu --reload                     reload the configuration and report problems
    stdmenu agent                        run the agent

Input lines are `label<TAB>value<TAB>icon`. The label is shown and searched, the value is printed
(defaults to the label), and the optional icon is a single character such as an emoji, or a path to an
image or to any file or app whose Finder icon should be shown. The prompt is shown in the empty search
field, and `-l` sets how many rows are shown at most (default 10). `-0` ends the value with a NUL byte
instead of a newline, so that `xargs -0` passes it on as one argument, whatever it contains:

    ls ~/Notes | stdmenu -0 -p notes | (cd ~/Notes && xargs -0 open)
    stdmenu -p name < /dev/null    # just a text prompt

| Key                                 | Action                                                 |
| ----------------------------------- | ------------------------------------------------------ |
| Return, click                       | choose the selected item                               |
| Shift-Return                        | choose the typed text; Return does too without a match |
| Up, Down, Ctrl-P, Ctrl-N, Shift-Tab | move the selection                                     |
| Page Up, Page Down                  | move by a page                                         |
| Tab                                 | complete the text to the selected label                |
| Cmd-A, Cmd-C, Cmd-X, Cmd-V, Cmd-Z   | edit the search text                                   |
| Escape                              | cancel                                                 |

Search terms are case- and accent-insensitive and may come in any order. As in dmenu, an item whose
label is exactly the search text comes first; the others are ranked by match quality (label prefix,
word prefix, substring, subsequence) and otherwise keep their input order.

## Configuration

`~/.config/stdmenu/config` holds settings and hotkeys, one `key = value` per line. `make install`
creates it from the [default](Resources/config) if it does not exist yet; without it the agent uses
the bundled default. Run `stdmenu --reload` after editing; it lists any mistakes. Hotkeys map a key
to a shell command:

    alt-space       = stdmenu-apps | stdmenu -0 -p apps | xargs -0 open
    alt-shift-space = stdmenu -p emoji < "$STDMENU_RESOURCES/emoji.tsv" | stdmenu --paste

Modifiers are `cmd`, `ctrl`, `alt` and `shift`; every hotkey needs one, except `f1` to `f12`. Keys are
characters on your keyboard layout, or `space`, `return`, `tab`, `escape`, `delete`, the arrows,
`home`, `end`, `pageup`, `pagedown`, and `minus` and `equal` for `-` and `=`. A hotkey takes the key
away from other applications: `alt-space`, for example, no longer types a non-breaking space.

Commands run in `/bin/sh`, with `stdmenu`, the bundled scripts in [Resources/bin](Resources/bin) and
`$STDMENU_RESOURCES` available; `PATH` is launchd's plus Homebrew's, not your shell's. Pressing a
hotkey again closes its menu.

To launch apps with `cmd-space` instead, turn off the Spotlight shortcut in System Settings →
Keyboard → Keyboard Shortcuts → Spotlight, change `alt-space` to `cmd-space` and run `stdmenu --reload`.

### Appearance

By default the window looks native: translucent, in the system font and accent colour, with the
scrollbar shown as System Settings say. These settings change that:

    theme       = light:paper, dark:ink
    font-family = Menlo
    font-size   = 15
    scrollbar   = never
    lines       = 10

`theme` names one theme for both appearances, or one per appearance as above. `font-family` takes a
font family or PostScript name, or `monospace` for the system's monospaced font; `font-size` sets the
list, and the search field scales with it. `scrollbar` is `system` (the default) or `never`; the list
still scrolls with the keyboard and trackpad. `lines` is how many rows a menu shows at most
(default 10); `stdmenu -l` overrides it for one menu.

No themes come with StdMenu. A theme is a file in `~/.config/stdmenu/themes/`, such as
`~/.config/stdmenu/themes/ink`, with colours as `#rrggbb` or `#rrggbbaa`:

    background           = #000000
    foreground           = #d4d4d4
    match-foreground     = #ffffff
    selection-background = #373737
    selection-foreground = #ffffff
    border               = #484848

Every key is optional, and keys a theme leaves out keep the native look:

| Key                    | Default                         | Colour of                                |
| ---------------------- | ------------------------------- | ---------------------------------------- |
| `background`           | translucent system material     | the window                               |
| `foreground`           | label colour                    | typed text and items                     |
| `match-foreground`     | accent colour                   | the matched characters of other items    |
| `placeholder`          | secondary label colour          | the prompt and the search icon           |
| `selection-background` | accent colour                   | the selected item                        |
| `selection-foreground` | white                           | the text of the selected item            |
| `cursor-color`         | system insertion point          | the text cursor                          |
| `border`               | no border, system separator     | the window outline and the divider       |

## Recipes

Pick an emoji by name and type it into the frontmost application:

    alt-shift-space = stdmenu -p emoji < "$STDMENU_RESOURCES/emoji.tsv" | stdmenu --paste

`stdmenu --paste` puts the text on the clipboard and presses Cmd-V, which needs Accessibility access
for StdMenu (System Settings → Privacy & Security → Accessibility). So that other programs cannot use
that access, the agent pastes only once, within five seconds of a menu choice. The build is signed ad
hoc, so macOS may ask for access again after a rebuild.

Open a new window in a chosen browser profile, even while another profile is open:

    alt-shift-b = stdmenu-chromium-profiles Home=🏠 Work=💼 | stdmenu -0 -p profile | xargs -0 -I{} open -na Chromium --args --profile-directory={}

`stdmenu-chromium-profiles` lists the profiles in the browser's own order, and arguments `name=icon`
give profiles an icon; the others show the browser's. For another Chromium-based browser, pass its
data directory and app, as in `stdmenu-chromium-profiles -d "$HOME/Library/Application Support/Google/Chrome"
-a "/Applications/Google Chrome.app"`, and open that app instead. It needs `jq`, which macOS includes
from version 15.

Open a new Ghostty window in a project directory:

    alt-shift-t = stdmenu-dirs ~/Software ~/Writing | stdmenu -0 -p directory | xargs -0 stdmenu-ghostty

`stdmenu-dirs` lists the subdirectories of each directory as `Software/StdMenu`, alphabetically within
each. `stdmenu-ghostty` opens a window through Ghostty's AppleScript interface, so macOS asks once
whether StdMenu may control Ghostty.

## Notes

- `stdmenu-apps` lists applications by file name, so system apps appear under their English names.
- [Resources/emoji.tsv](Resources/emoji.tsv) is generated from Unicode's `emoji-test.txt` and covered
  by the [Unicode License](Resources/LICENSE-Unicode.txt); `make emoji` updates it.
- Removing StdMenu leaves its Accessibility and Automation permissions listed in System Settings;
  `tccutil reset All dev.schmaeke.stdmenu` clears them.

## License

MIT, see [LICENSE](LICENSE).
