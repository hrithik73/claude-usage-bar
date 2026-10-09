# Claude Usage

A small macOS menu bar app that shows how much of your Claude plan limits you've used.

- **Menu bar:** two rings. The outer ring is the weekly limit and the inner ring is the 5-hour session. A ring turns orange at 75% and red at 90%.
- **Menu:** a progress bar for each limit, with the percentage and when it resets.
- **Alerts:** a notification when either limit crosses 90%.

It reads the login Claude Code saves in your Keychain and checks the same usage endpoint that `/usage` uses, every 5 minutes. You need to be logged in to Claude Code (`claude`).

## Install

```sh
./build.sh
```

This builds `~/Applications/ClaudeUsageBar.app`, sets it to start at login, and launches it. Run it again after you change `main.swift`.

For notifications that stay on screen, go to System Settings → Notifications → Claude Usage and choose **Persistent**.

## Test

```sh
./test.sh
```

Checks the 90% alert logic.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.hritik.claude-usage-bar
rm ~/Library/LaunchAgents/com.hritik.claude-usage-bar.plist
rm -rf ~/Applications/ClaudeUsageBar.app
```
