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

## Translate a selection

Select a sentence or short passage and press **Control–Option–T** (⌃⌥T). XiaolaiDict shows the
translation in its own panel, using the same on-device translator and source attribution as the
"Translate This Sentence" control on a dictionary card. The selection is limited to 2,000
characters and does not create a dictionary lookup or study-history entry. The existing ⌃⌥D
shortcut still looks up a selected word or phrase.

In Ghostty, XiaolaiDict asks Ghostty's scripting interface to copy the focused terminal's selection.
macOS asks for permission to control Ghostty the first time; allow it for this feature. This copy
updates the clipboard. If the terminal has no selection, the old clipboard text is never translated.
Other apps continue to provide selected text through Accessibility.

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
