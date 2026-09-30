# XiaolaiDict

A menu-bar dictionary for macOS that marks **which sense** of a word you just read.

## Requirements

- macOS 27 or later
- Apple Silicon

## Install

```sh
brew tap xiaolai/tap
brew install --cask xiaolaidict
```

To update later: `brew upgrade --cask xiaolaidict`

Or download the `.dmg` from [Releases](https://github.com/xiaolai/XiaolaiDict/releases) and drag the
app to Applications. It is signed and notarised, so Gatekeeper opens it without a right-click.

**Installing needs neither Xcode nor a developer certificate.** Those are for building, and building
is not a supported path: the app is signed with this project's own Developer ID, and an ad-hoc build
is refused by its own dictionary service, which accepts only a caller signed by the same team.
