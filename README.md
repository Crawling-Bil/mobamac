# MobaMac

A native macOS SSH/terminal client, a MobaXterm-style alternative built for Mac.

## Download

Grab the latest build from the [Releases page](https://github.com/Crawling-Bil/mobamac/releases/latest). [CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

## Features

- SSH, Telnet, Serial console, and local terminal sessions in one app
- Sidebar organizes sessions into Customer → Device Type folders
- Multiple tabs at once, with a live connection status dot per session
- Broadcast keystrokes to several SSH sessions at the same time
- Color themes, saved macros, quick connect, and a command palette (⌘K)
- Auto-reconnect, credential sets for reusing logins across devices
- Session logs in plain text: no color codes or cursor movement, so a log can go straight into a report
- Network tools, SFTP and snippets as a resizable side panel, not a modal sheet
- Light, Dark or System for the app, independently of the terminal's own theme
- Passwords are stored in the macOS Keychain, never in plain text
- Updates install themselves: MobaMac checks once a day and offers to update in place

## Installing

The first install is manual. Every update after that is not.

1. Download the `.zip` from the [Releases page](https://github.com/Crawling-Bil/mobamac/releases/latest)
2. Unzip it, then drag `MobaMac.app` into your Applications folder
3. First launch: right-click the app → **Open** → click **Open** again in the popup

(Step 3 is needed because the app isn't from the App Store, so macOS blocks it by default the first time. It is asked once, not on every launch and not after an update.)

From then on MobaMac checks for a new version once a day and, when there is
one, shows what changed and offers to install it. There is nothing to
download, unzip or drag again. **MobaMac → Check for Updates…** checks
immediately, and the **Automatically Check for Updates** item next to it
turns the daily check off.

## Settings

**MobaMac → Settings…** (⌘,), in three tabs.

**General** holds the appearance (System, Light or Dark — the terminal keeps
its own color theme either way), whether to confirm before closing a session
that is still connected, and the update options.

**Terminal** holds two habits carried over from MobaXterm and PuTTY, both off
by default because they contradict how other Mac apps behave: *Copy on
select*, and *Right-click pastes* (Control-click still opens the context
menu, and a multi-line paste still asks first).

**Logging** is where the log folder lives, along with *Keep raw session logs*
— a `.raw` file beside each `.log` holding the unfiltered bytes, for when the
escape sequences are the thing you need to see — and how long to keep old
logs.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘1 – ⌘8 | Select tab 1 to 8 |
| ⌘9 | Select the last tab |
| ⌘⇧] / ⌘⇧[ | Next / previous tab, wrapping at both ends |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌘D | Duplicate the active tab's session |
| ⌘W | Close the active tab |
| ⌘K | Command palette |
| ⌘R | Reconnect, on a tab that dropped or failed |
| ⌘+ / ⌘- / ⌘0 | Zoom in / out / actual size, across every tab |
| ⌥⌘*key* | Run a macro, with the key set per snippet |
| ⌘F | Search saved sessions in the sidebar |
| ⌘C / ⌘V | Copy / paste, with a confirmation for multi-line pastes |
| ⌘, | Settings |
| ⌘Q | Quit, confirming if sessions are still connected |

Macros keep ⌥⌘, so tab switching could take the ⌘1 – ⌘9 row that macOS
apps normally use for it. Nothing changed meaning.

## Building from source

Needs Xcode Command Line Tools (no full Xcode required).

```
git clone https://github.com/Crawling-Bil/mobamac.git
cd mobamac
Scripts/build-app.sh
```

This builds the app and installs it straight into `/Applications`.

### Code signing certificate

`Scripts/build-app.sh` signs the app with a self-signed certificate called
**MobaMac Self-Signed**, which you need to create once before the first
build. Without it the build stops and tells you so.

Ad-hoc signing would avoid the whole step, but it mints a fresh identity on
every build, and macOS treats a differently-signed binary as a different
application. Since MobaMac keeps every saved SSH password in the Keychain,
that means a Keychain prompt per session after every single update. One
certificate, created once, removes all of it.

In **Keychain Access**:

1. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `MobaMac Self-Signed`
3. Identity Type: **Self Signed Root**
4. Certificate Type: **Code Signing**, then **Create**

To build with a different certificate, or to go back to ad-hoc signing and
accept the Keychain prompts:

```
MOBAMAC_SIGN_IDENTITY="My Other Cert" Scripts/build-app.sh
MOBAMAC_SIGN_IDENTITY=- Scripts/build-app.sh
```

Hardened Runtime is deliberately left off. It brings library validation,
which refuses to load a framework unless it carries the same Team ID as the
app, and a self-signed certificate has no Team ID at all. Turning it on
would stop Sparkle.framework from loading.

### Auto-update

Updates run on [Sparkle 2](https://sparkle-project.org), with GitHub
Releases holding the zips and GitHub Pages serving the feed.

Every update MobaMac installs is checked against an EdDSA signature, so an
update has to have been signed by the private key belonging to the public
key baked into the app. Generate the pair once:

```
swift package resolve
$(find .build/artifacts -name generate_keys -type f | head -1)
```

`generate_keys` stores the private key in your login Keychain and prints the
public key. Put that public key in `Scripts/sparkle-public-key.txt`, which is
committed — a public key is public by definition, and the build reads it
from there to write `SUPublicEDKey` into the app's Info.plist.

**Back the private key up somewhere safe, outside this repository.** Losing
it means no future release can be signed with the key that installed copies
already trust, and everyone on an older version has to be told to download
and install by hand. `generate_keys -x private-key.txt` exports it; keep
that file out of git and off anything shared.

Turn the feed on once, in repository **Settings → Pages**: source "Deploy
from a branch", branch `main`, folder `/docs`. The feed then lives at
`https://crawling-bil.github.io/mobamac/appcast.xml`, which is what
`SUFeedURL` points at. It is https and not `raw.githubusercontent.com`,
whose caching can hide a new release for hours.

Building without `Scripts/sparkle-public-key.txt` is fine: the app is built
with no feed URL and simply never offers updates.

### Releasing

```
Scripts/release.sh
```

Builds, zips, tags, publishes the GitHub release with notes from
`CHANGELOG.md`, then regenerates `docs/appcast.xml` and pushes it. That last
step is what makes existing installs see the new version.

The appcast is generated from a folder holding only the new zip, and
`Scripts/merge-appcast.py` splices that one entry into the published feed.
`generate_appcast` stamps everything it is pointed at with the current run's
download URL, so running it over a folder of every past release would
rewrite the old entries to point at the newest tag and 404 for anyone still
on an older version.

## Project layout

```
Assets/              app icon and logo
docs/                GitHub Pages: serves appcast.xml, the Sparkle update feed
Scripts/
  build-app.sh       build, bundle, sign and install to /Applications (holds the version number)
  release.sh         build, zip, publish a GitHub release and the appcast
  merge-appcast.py   splices one release into docs/appcast.xml
  make-icon.sh       turn a PNG into Assets/AppIcon.icns
  sparkle-public-key.txt  EdDSA public key baked into the app (not secret)
Sources/MobaMac/
  App/               app entry point
  Connection/        SSH, Telnet, Serial and SFTP sessions
    SSH1/            fallback client for SSH-1-only devices
  Models/            session profiles, groups, credential sets, snippets
  Persistence/       Keychain, stores, known hosts, session logs and their settings
  Support/           themes, fonts, appearance, terminal behaviour, updates, dialogs
  Tools/             log sanitizer, terminal highlighting, network tools, serial ports
  ViewModels/        SessionManager: open tabs, connect, reconnect
  Views/
    Terminal/        terminal host views
    Sidebar/         session tree and folders
    Sessions/        new session, Quick Connect, credential sets, command palette
    Panels/          SFTP, logs, snippets, network tools, broadcast
    Preferences/     the Settings window
Vendor/swift-nio-ssh patched SSH library (see its VENDORED.md)
```

Session logs go to `~/Library/Logs/MobaMac/` unless another folder is set in
Settings, named `<yyyy-MM-dd_HH-mm-ss>_<session>.log`. What they contain is
plain text: `TerminalOutputSanitizer` takes out the color codes, cursor
movement and line redrawing, so the file reads the way the screen did.
