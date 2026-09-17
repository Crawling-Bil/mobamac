# MobaMac

A native macOS SSH/terminal client, a MobaXterm-style alternative built for Mac.

## Download

Grab the latest build from the [Releases page](https://github.com/Crawling-Bil/mobamac/releases/latest). [CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

## Features

- SSH, Telnet, Serial console, and local terminal sessions in one app
- Sidebar organizes sessions into Customer → Device Type folders
- Multiple tabs at once, with a live connection status dot per session
- Broadcast keystrokes to several SSH sessions at the same time
- Color themes, session logging, saved macros, quick connect, and a command palette (⌘K)
- Auto-reconnect, credential sets for reusing logins across devices
- Passwords are stored in the macOS Keychain, never in plain text

## Installing

1. Download the `.zip` from the [Releases page](https://github.com/Crawling-Bil/mobamac/releases/latest)
2. Unzip it, then drag `MobaMac.app` into your Applications folder
3. First launch: right-click the app → **Open** → click **Open** again in the popup

(Step 3 is needed because the app isn't from the App Store — macOS blocks it by default the first time.)

## Building from source

Needs Xcode Command Line Tools (no full Xcode required).

```
git clone https://github.com/Crawling-Bil/mobamac.git
cd mobamac
./package-mobamac-app.sh
```

This builds the app and installs it straight into `/Applications`.
