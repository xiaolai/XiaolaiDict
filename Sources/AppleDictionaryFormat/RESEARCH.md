# Research record — AppleDictionaryFormat

**What this file is for:** every figure in `FEATURE-LEDGER.md` and in the source docstrings was
measured on a real machine against real bundles. This records *how*, and against *which set*, so a
later reader can reproduce a number instead of trusting it — and so a stale one can be recognised.

**Measured:** 2026-09-27, macOS 27, against **all 86 assets in the macOS 27 dictionary catalogue**,
downloaded and read. Nothing here is cited from documentation.

**Reproducing it needs the catalogue.** An ordinary Mac carries only the dictionaries its region and
language selected — this one had 16 of the 86. The full set has to be downloaded before the gated
tests measure anything, and **the tests print "not measured" and pass when `XIAOLAIDICT_BUNDLES` is
unset**, which is the one thing to watch: a green suite is not evidence that a measurement happened.

```
XIAOLAIDICT_BUNDLES=<directory of .dictionary bundles> swift test --filter AppleDictionaryFormat
```

---

## 1. The container

| Question | Answer | How |
|---|---|---|
| How many bundles can be read end to end? | **85 of 86** | `everyBundleYieldsWellFormedEntries` — each bundle's first record parses as a whole `d:entry` |
| Why does the 86th fail? | **Compression, not path.** `com.apple.dictionary.AppleDictionary` has about thirty `Body.data` files, one per locale under `Contents/Resources/<lang>.lproj/`, and its chunks are not zlib-wrapped deflate | Two earlier claims about it were wrong — first that it has no `Body.data` at all, then that only its path differed |
| Is the entry markup well formed? | **0 unparsable of 100,872 entries read** | `EntryIndexer` over the 85 readable assets |
| How is `KeyText.data` walked? | By a **fixed 8,192 stride**, never by the per-chunk size field | `theKeyIndexIsWalkedByStrideNotBySize`. The size field is **0 in some chunks**, so a size-driven walk returns a partial index that looks complete |
| What does `COMPRESSION_ZLIB` mean here? | **Raw deflate.** Apple's Compression framework does not consume the 2-byte zlib header, so it must be dropped first | Found by decompression failing on every chunk until the header was skipped |

## 2. Sense depth — the same question asked three ways, two of them wrong

This is the measurement worth keeping, because the first two answers were plausible and wrong, and the
third contradicted both.

| Asked as | Answer it gave | Why it is wrong |
|---|---|---|
| Shallowest `x_xdN` carrying **any** `id` | six dictionaries nest deeper | Matches sub-sense *wrappers* that carry an `id` and no definition. The stricter test disagreed on 34 dictionaries |
| Shallowest `x_xdN` carrying **a definition** | depth 1 for all 84 | Worse, and more dangerously so: it asks whether *a* block at that depth holds *a* definition. A dictionary satisfies it while most of its definitions sit deeper |
| **Retention** — indexing at this depth, what share of the declared `d:def` elements survive | **five dictionaries need a deeper depth** | This is the question whose answer is the harm. Losing definitions is the failure; finding an id is not |

Retention, measured through `EntryIndexer` itself:

| Dictionary | depth 1 | best depth | retained there |
|---|---|---|---|
| `com.apple.dictionary.vi.oup` | 23% | 2 | 103% |
| `com.apple.dictionary.el.oup` | 48% | 3 | 100% |
| `com.apple.dictionary.ml-en.oup` | 62% | 2 | 122% |
| `com.apple.dictionary.as-en.oup` | 64% | 2 | 154% |
| `com.apple.dictionary.kn-en.oup` | 78% | 2 | 153% |

Over 100% means one indexed sense joins several `d:def` elements, which is correct — a block's glosses
belong to the sense that holds them.

`DepthRetentionTests` re-measures **every installed dictionary** every run: *84 measured, 0 declaring a
depth that loses definitions*. The table above therefore cannot drift silently.

**Still lost at the best available depth:** worst case **18.3%** in `com.apple.dictionary.or-en.oup`,
and no depth recovers it. That is not depth choice but definitions the reader does not reach at all —
measured, bounded, and not yet explained. Carried in the ledger §3.

## 3. Sense identity

| Question | Answer | How |
|---|---|---|
| Does a publisher id map to exactly one content key? | **100.00%, forward and reverse, over 75,401 pairs from 50 dictionaries** | `SenseKeyValidityTests`, through `EntryIndexer` — not a side probe. Both directions over **full keys, entry included** |
| Why does entry identity matter to the reverse figure? | A digest is unique only *within* its entry by construction. An earlier reverse figure of 97.55% compared bare digests across entries and measured nothing the scheme claims | See `AUDIT.md` §3 |
| Which attribute carries the publisher id? | `lexid` in **33** dictionaries, `id` in **24**, **none in 27** | `DictionaryProfile.senseIDAttributes`, read back through the indexer |

## 4. Authorship

Apple licenses its whole third-party dictionary programme through Oxford, so nearly every bundle looks
Oxford-authored at a glance. Measured per bundle instead: of the five languages with adapters, **only
Simplified Chinese and Cantonese carry an Oxford-authored work.** Japanese is Sanseido, Korean DIOTEK,
Traditional Chinese INVENTEC. Asserted by `authorshipIsRecordedRatherThanAssumed`.

Three adapter declarations originally claimed an `id` attribute where the indexer found 0%, 1% and 0%.
`declaredIDAttributesMatchRealBundles` reads every declaration back through the indexer over the 15
installed dictionaries, which is how all three were caught — and why the check had to stop being
circular (`AUDIT.md` #25).

## 5. Method, stated once because it was earned five times

**Measure through the code that will ship, not through a side probe.** A side probe disagreed with the
real extraction path five times during this work and the path was right every time. The corollary:
a green gated test proves nothing when its bundles are absent, so the test prints what it measured and
the count is read, not assumed.

## 6. What licensing forbids

Dictionary text is licensed to the reader whose Mac it is on. **No bundle content is vendored into this
repository and no test fixture quotes it** — fixtures are invented markup. The measurements above ran
against locally installed bundles and only counts left them.
