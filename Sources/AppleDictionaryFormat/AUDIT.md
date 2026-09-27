# Audit record — AppleDictionaryFormat

**Scope:** `Sources/AppleDictionaryFormat/` (11 files, 813 lines) plus an added *data validity*
dimension. **Date:** 2026-09-27. **Auditors:** this module's own re-measurement pass, then an
independent mini audit (5 dimensions) by `gpt-6-astra` at high effort, read-only.

Kept in the module rather than under `.cc-suite/audits/`, which is ignored by policy — an audit that
is not committed cannot be checked against the code it describes.

**30 findings tabulated:** 4 from my re-measurement pass, 25 from the audit, 1 found afterwards while
reconciling the ledger against the code. **19 fixed, 8 carried in the feature ledger §3 as recorded
gaps, 3 lower-severity still open** — 19 + 8 + 3 = 30.

The audit's own summary said 29 where its table listed 25, so its count is reported as tabulated rather
than as claimed. The two High findings I found by re-measurement were **independently found by the
audit**, which is corroboration from a reader that had not seen my pass.

---

## 1. What the audit was actually for

Every docstring figure was re-measured **through the shipping code path** rather than through the probe
that produced the original number. That distinction is the whole finding: a side probe disagreed with
the real extraction path five times, and the path was right every time.

| # | Where | Sev | Finding | Status |
|---|---|---|---|---|
| 1 | `SenseKey` | **High** | Claimed 100.00% over 29,065 pairs. Re-measured through `EntryIndexer`: **98.45%** over 72,944 pairs — 1,112 publisher ids mapped to two content keys | fixed |
| 2 | `EntryIndexer` | **High** | Emitted one sense per `d:def`, but a sense block can hold several; two senses then shared one publisher id. All 1,112 collisions same-entry, 0 cross-entry | fixed |
| 3 | `EntryIndexer` | Med | `_ = attribute` — the declared `senseIDAttribute` was read and discarded; the code took `lexid ?? id` regardless, so every declaration was decorative | fixed |
| 4 | `DictionaryProfile` | **High** | Default was `"id"`, but `lexid` is commoner (33 dictionaries to 24). Fixing #3 therefore dropped 28 dictionaries out of the validation set | fixed |
| 5 | `ContainerReader` | **High** | Header guard accepted 65–67-byte files while the `UInt32` read at offset 64 needs ≥68 — truncated input hit a precondition crash instead of a thrown error | fixed |
| 6 | `ContainerReader` | **High** | Allocating exactly `expected` cannot detect *excessive* output: `compression_decode_buffer` returns the destination size when it fills. One byte of slack makes overflow observable | fixed |
| 7 | `ContainerReader` | **High** | Docstring claimed the layout is "stable across all 86". It is not, which is why the reader gets 85 | fixed |
| 8 | `DictionaryLocator` | **High** | `DictionaryBundle.profile` called `DictionaryProfile.profile`, **bypassing `LanguageAdapters.profile`** — so every language adapter was silently unused by the bundle's own accessor | fixed |
| 21 | `DictionaryProfile` | Med | Two claims in one file contradicted each other: "78 depth-1, five depth-2, one depth-3" against "all 84 depth 1" | fixed |
| 22 | `DictionaryProfile`, `EntryIndexer` | Med | **`Tools/dictionary-depths` does not exist** — a cited probe that was never in the repository | fixed |
| 23 | `SimplifiedChinese` | Med | "Only CJK one with a publisher id" contradicted `Cantonese.swift`, which declares an Oxford work with `id` | fixed |
| 24 | `SimplifiedChinese` | Med | Counts came from another project's ingestion (68,123 entries); the **installed bundle has 136,288** | fixed |
| 25 | `LanguageAdapter`, `TraditionalChinese`, `Korean` | Med | The "no publisher ids" check was **circular** — it validated a declaration against a profile built from that same declaration | fixed |
| 20 | `SenseKey` | Med | The validation compared only `.value`, omitting entry identity, so it did not establish the documented full-key mapping | fixed |
| 28 | seven adapter/profile files | Low | Unused `import Foundation` | fixed |
| 26 | `SenseKey` | Low | Five named dictionaries plus "24 others" is 29, contradicting the stated 27 | fixed |
| 27 | `EntryIndexer` | Low | `Reader.dictionary` assigned, never read | fixed |
| 29 | `ContainerReader` | Low | The `subdata` comment misstated the mechanism | fixed |
| 30 | `LanguageAdapter` | **High** | `DictionaryDescriptor.profile` hardcoded `senseDepth: 1`, and `LanguageAdapters.profile(for:)` consults adapters **before** the measured override table — so any adapter claiming one of the five deeper dictionaries would silently reset it to depth 1. Latent, not live: no adapter claims one today. **Introduced by the fix for #8**, which routed the bundle accessor through the adapters without noticing the adapters discard the depth | fixed |

## 2. Carried, not fixed — and why

Eight findings need the entry reader reworked rather than patched at a call site, so they are recorded
in the feature ledger §3 with their effect, and left visible instead of silently carried:
the shared capture buffer, part of speech not scoped to its `x_xd0`, nested sense blocks clobbering
state, dropped CDATA, headword swallowing pronunciations, narrower namespace resolution than claimed,
the unvalidated Adler-32, and silently skipped key chunks.

Three lower-severity ones are also open: both readers overread the compressed stream by four bytes,
chunk bounds are checked against the file rather than the declared payload extent, and adding a second
identical definition renames an existing bare digest to `digest:0` rather than leaving it alone.

## 3. Verification, and the regression it caught

The fix for #2 was verified rather than assumed, and the verification found that the fix was wrong.

| | before | after keep-first-`d:def` | after join |
|---|---|---|---|
| forward (publisher id → one content key) | 98.45% | 100.00% | **100.00%** |
| reverse | 97.58% | 97.55% | **100.00%** |
| pairs / dictionaries | 72,944 / 49 | 71,827 / 49 | **75,401 / 50** |
| same-entry id collisions | 1,112 | 0 | **0** |

**Keeping only a sense block's first `d:def` destroyed content.** 譯典通's entry for `一` holds six
co-equal glosses in one block and five were being dropped. Multiple `d:def` is not always
cross-references, so one sense carrying all its text is the only reading wrong in neither direction.

The reverse figure moved because it too was **meaningless as first measured** — it compared bare
digests across entries, and a digest is unique only *within* its entry by construction. Exact once
entry identity is included.

Assertions were added, not only fixes: `noSenseBlockYieldsTwoSensesUnderOnePublisherID` over 34,068
id-bearing entries, and `aSenseBlockKeepsEveryDefinitionItHolds`. The second of those immediately
reported Vietnamese retaining 21.9% of its definitions, which is how the depth claim was found wrong —
see `RESEARCH.md` §2.

## 4. Found afterwards, while reconciling the ledger against the code

Finding #30 was not in either pass. It surfaced because a test named `everyDeclaredDepthIsOne` was
**passing and true** while five dictionaries declared depth 2 or 3 — a name that had become a false
general claim. The name was the only visible symptom; the defect underneath it was that the adapter
path discarded the measured depth entirely.

Two things worth keeping from it:

- **The fix for one bypass created another.** #8 was `DictionaryBundle.profile` bypassing the adapters.
  Routing it through them introduced the reverse bypass — the adapters ignoring the override table —
  and the audit could not see it, because it audited the code before that fix existed.
- **A test that asserts a coincidence locks it in.** `senseDepth == 1` was true for every
  adapter-declared dictionary, so the assertion passed; it just did not assert the invariant. Replaced
  with `anAdapterCannotOverrideAMeasuredDepth`, which checks each real declaration against the table
  *and* exercises the path with a descriptor bearing an overridden identifier. **Mutation-tested**:
  restoring the hardcoded `1` fails it.

