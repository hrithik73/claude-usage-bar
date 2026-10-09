# Claude Usage

A small macOS menu bar app that shows how much of your Claude plan limits you've used.

- **Menu bar:** two rings. The outer ring is the weekly limit and the inner ring is the 5-hour session. A ring turns orange at 75% and red at 90%.
- **Menu:** a progress bar for each limit, with the percentage and when it resets.
- **Alerts:** a notification when either limit crosses 90%.

It reads the login Claude Code saves in your Keychain and checks the same usage endpoint that `/usage` uses, every 5 minutes. You need to be logged in to Claude Code (`claude`). If you are logged out or your login has expired, the icon turns red and the menu tells you to run `claude`, then click Refresh.

## Install

**From the DMG** (any Mac on macOS 13 or later, Apple Silicon or Intel):

1. Download `ClaudeUsage.dmg` from the [latest release](../../releases/latest).
2. Open it and drag **ClaudeUsageBar** into **Applications**.
3. Open the app. macOS will block it the first time, because the app isn't signed with an Apple Developer ID. Go to System Settings → Privacy & Security, scroll down, and click **Open Anyway**.

The app adds itself to Login Items on first launch. Make sure you're logged in to Claude Code on that Mac.

**From source:**

```sh
./build.sh       # build, install to ~/Applications and launch
./build.sh dmg   # build ClaudeUsage.dmg
```

For notifications that stay on screen, go to System Settings → Notifications → Claude Usage and choose **Persistent**.

## Test

```sh
./test.sh
```

Checks the 90% alert logic.

## Uninstall

Quit the app from its menu, then delete ClaudeUsageBar from Applications (or ~/Applications if you built it from source). If it still shows in System Settings → General → Login Items, remove it there.
