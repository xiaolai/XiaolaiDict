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

## Compact lookup

In **Settings → Reading → In the panel**, turn on **Use a compact lookup card** for a shorter
dictionary preview. The existing reading card remains the default.

The preview shows the selected word, pronunciation, and up to three distinct meanings from the
current dictionary entry. Repeated grammar labels become familiar abbreviations such as `v.` and
`adj.`, and meanings with the same part of speech share a row. An uncertain context remains marked.

**More meanings** opens the full reading card, all its senses, and the entry's examples and details.
**Fewer details** returns to the preview; each new lookup starts compact again. These are two views
of the same lookup, so expansion does not fetch or generate another translation.

Compare the [existing card](docs/compact-lookup/original-light.png),
[compact preview](docs/compact-lookup/compact-light.png), and
[expanded details](docs/compact-lookup/expanded-light.png).
These native renders use a synthetic dictionary fixture to illustrate the layout.
