# Feature ledger — AppleDictionaryFormat

**Status:** implementation inventory, 2026-09-27. Every figure below was measured on this machine
against **all 86 assets in the macOS 27 dictionary catalogue**, downloaded and read; none is cited from
documentation. Findings and their fix history are in `AUDIT.md` beside this file; how each figure was
measured, and against which set, is in `RESEARCH.md`.

**Which set matters.** The catalogue figures come from the full 86 downloaded that day. An ordinary Mac
carries only what its region and language selected — this one has 16 — and the gated tests **print
"not measured" and pass** when `XIAOLAIDICT_BUNDLES` is unset, so a green suite is not by itself
evidence that a measurement ran. Re-verified on the 16 locally present: 25 tests in 6 suites pass,
9 language dictionaries reachable, forward and reverse 100.00% over the 4,413 pairs among them.

**What this module is for:** to let xiaolaidict build its own index from the dictionaries Apple already
put on the reader's Mac, so that nothing licensed ever ships and nothing has to be downloaded but a
model. It reads Apple's container and names senses durably. **It does not yet build or persist an
index** — see §4.

**Dependencies:** `Foundation`, `Compression`, `CryptoKit`. No app target, no third-party package. It
compiles and tests without the rest of the project, which is what makes it shippable on its own.

---

## 1. Outcomes and boundaries

A caller should be able to:

1. Discover which dictionaries this Mac actually has, without guessing from file names.
2. Read every entry of any of them, without Dictionary Services.
3. Split an entry into senses the way that dictionary delimits them.
4. Name a sense so the name survives the publisher reordering or re-mastering the dictionary.
5. Know, per dictionary, which facts were measured and which are defaults.

**Out of scope by design:** no sense *selection* (that is a model's job and lives in
`XiaolaiDictCore`), no licensed text leaving the machine, no shipped index.

---

## 2. What is implemented

**Evidence levels:** *Implemented* = source exists, wired, and covered by a test that runs against real
bundles or invented fixtures. *Partial* = works for the common case with a known, recorded gap. *New* =
not built. Every row cites the test or the measurement, not an intention.

| Capability | Level | Evidence |
|---|---|---|
| Find installed bundles and identify each by `CFBundleIdentifier` | Implemented | `DictionaryLocator.installed`. Identity from `Info.plist`, never the path: `Simplified Chinese - English.dictionary` contains `…zh_CN-en.OCD`, the Oxford Chinese Dictionary, and Apple re-points generic package names between releases |
| Read every entry from `Body.data` | Implemented | `ContainerReaderTests.everyBundleYieldsWellFormedEntries` — **85 of 86 bundles**, each first record a whole `d:entry`. The miss is `com.apple.dictionary.AppleDictionary`, Apple's software glossary, which fails on **compression, not path** — it has about thirty `Body.data` files, one per locale, whose chunks are not zlib-wrapped deflate |
| Decompress `KeyText.data` chunks | Implemented | `theKeyIndexIsWalkedByStrideNotBySize`. Walked by the **fixed 8,192 stride**, because the per-chunk size field is **0 in some chunks** and a size-driven walk returns a partial index that looks complete |
| Split an entry into senses | Implemented | `EntryIndexer`. `x_xd0` is the part-of-speech block, `x_xdN` a sense at that dictionary's own depth, anything deeper belongs to the sense above. **Depth 1 for 79 of 84; five nest deeper** — see the depth row below |
| Sense depth declared per dictionary, chosen by retention | Implemented | `DepthRetentionTests` re-measures **every installed dictionary** and fails if a declared depth loses definitions: *84 measured, 0 declaring a lossy depth*. Five need a deeper one — Vietnamese keeps only **23%** of its `d:def` elements at depth 1 and 103% at depth 2, Greek **48%** against 100% at depth 3, plus `ml-en`, `as-en`, `kn-en` at depth 2 |
| One sense per sense block | Implemented | `noSenseBlockYieldsTwoSensesUnderOnePublisherID`, over **34,068 id-bearing entries**. A block can hold several `d:def`; the extras are cross-references — "American English = rappel" — and emitting one sense each gave 1,112 publisher ids two identities |
| Durable sense identity | Implemented | `SenseKey`. Publisher id where the dictionary has one, content-addressed digest where it does not. **Exact in both directions, 100.00%, over 75,401 pairs from 50 dictionaries**, measured through `EntryIndexer` itself |
| Per-dictionary facts as declarations | Implemented | `DictionaryProfile`. Two fields vary, both measured: `senseIDAttributes` — `lexid` in 33 dictionaries, `id` in 24, **none in 27** — and `senseDepth`, which departs from 1 in five. An adapter may pin the first and never the second |
| Five language adapters, each declaring only what it measured | Implemented | `SimplifiedChinese`, `TraditionalChinese`, `Cantonese`, `Korean`, `Japanese`. `declaredIDAttributesMatchRealBundles` reads each declaration back through the indexer over **15 installed dictionaries**; a wrong declaration fails the suite, which is how three of them were caught |
| Authorship recorded, not assumed | Implemented | `authorshipIsRecordedRatherThanAssumed`. Apple licenses its whole third-party programme through Oxford, so nearly every bundle looks Oxford. **Only Simplified Chinese and Cantonese have an Oxford-authored work**; Japanese is Sanseido, Korean DIOTEK, Traditional Chinese INVENTEC |

---

## 3. Partial — works, with a recorded gap

These are real and open. Each needs the entry reader reworked rather than patched at a call site, so
they are listed rather than silently carried.

| Gap | Effect | Where |
|---|---|---|
| Headword capture takes all text in `x_xh0` | Pronunciations, variants and homograph labels land in the headword | `EntryIndexer` §headword |
| Headword, part-of-speech and definition share one capture buffer | A nested part-of-speech capture can reset text belonging to an open outer region | `EntryIndexer.Reader.buffer` |
| Part of speech is not scoped to its `x_xd0` | A later block with no label inherits the previous block's part of speech | `EntryIndexer.Reader.currentPOS` |
| Nested matching sense blocks overwrite `senseDepth`/`pendingID` | Closing an inner block clears the outer context | `EntryIndexer.Reader` |
| CDATA is dropped | `foundCharacters` is implemented, `foundCDATA` is not, so a CDATA definition reads empty | `EntryIndexer.Reader` |
| Namespace resolution is narrower than the docstring says | Only a literal `d:` prefix is matched, not the namespace URI | `EntryIndexer.Reader.dictionaryAttribute` |
| Adler-32 is never checked | The zlib header is stripped and raw deflate decoded, so wrapper and checksum corruption pass | `ContainerReader.inflate` |
| Some definitions are still lost at the best available depth | The worst case is **18.3% in `com.apple.dictionary.or-en.oup`**, and no depth recovers it — the loss is not depth choice but definitions the reader does not reach at all. Measured, bounded, and not yet explained | `SenseKeyValidityTests` reports it every run |
| A failed key chunk is skipped silently | One surviving chunk makes the whole read look successful | `ContainerReader.keyChunks` |

---

## 4. Not built — what a rebuild tool still needs

**The module reads and names. It does not index, persist, or match.** Naming this plainly because the
capabilities in §2 are the foundation of a rebuild tool and are easy to mistake for one.

| Missing | Why it matters |
|---|---|
| Parse `KeyText.data` chunks into **keys** | `keyChunks` returns decompressed bytes, not the search keys inside them. NOAD's index holds **271,029 records, 146,535 of them multi-word** — the phrase hover depends entirely on reading those, and Dictionary Services cannot enumerate them (no `DCSCopyKeys`, symbol-probed) |
| A persistence layer | No database is written. `libsqlite3` ships with macOS, so this needs no dependency — but the on-disk shape is a decision, not an implementation detail |
| The rebuild driver | Walk the installed set, report progress, rebuild on a dictionary update. The pieces exist; the orchestration does not |
| Phrase matching on hover | Measured elsewhere at **39.2% coverage, 86.6% recall, 83.8% ranked first** from NOAD alone — but that was a different implementation, not this module |
| Cross-dictionary sense alignment | Direct alignments exist at **0.952 mean confidence** (thesaurus→NOAD, 31,828 pairs) and **44% by arithmetic** for Oxford Chinese→NOAD, but computed elsewhere and not by this module |
| Inflection resolution | The bundles carry it — NOAD's index resolves `children → child` — and `keyChunks` has the bytes, but nothing reads them yet |

---

## 5. What this module deliberately does not decide

- **Which model selects a sense.** Measured separately: local Qwen3.5-4B 64.5% and 9B 70.4% against a
  28.6% first-sense floor. That belongs to the app, not here.
- **Whether a rebuilt index may be redistributed.** It may not. The index is derived from dictionaries
  Apple licensed to *that reader*, which is why it is built locally and never shipped.
- **Which dictionaries a reader has.** Region and language decide. Nothing here assumes NOAD exists.

---

## 6. Known-wrong things that were fixed, so they are not re-derived

Recorded because each produced a plausible, wrong number that survived a first look.

| Claim once made here | What it actually is |
|---|---|
| "`x_xd1` is a sense" is too narrow, use any `x_xdN` | **Wrong as a global rule.** Broke 牛津英汉汉英, where `x_xd2`/`x_xd3` are subsenses. Depth is dictionary-relative: 1 for 79 of 84, deeper for five |
| Six dictionaries have senses below depth 1 | **Right conclusion, wrong evidence** — that probe matched sub-sense wrappers carrying an `id` and no definition, and the strict test disagreed with it on 34 dictionaries. Five dictionaries really do nest deeper, which only *retention* establishes |
| Depth 1 is right for all 84, measured | **Wrong question, asked twice.** *Shallowest `x_xdN` carrying any id* matches sub-sense wrappers; *shallowest carrying a definition* is worse, because a dictionary satisfies it while most of its definitions sit deeper. Only **what share of `d:def` survives indexing** is the question whose answer is the harm |
| Content keys map 1:1 to publisher ids, 100.00% | Was **98.45%** through the real indexer, because of the multi-`d:def` bug. Now exact again over a set 2.5× larger |
| Reverse mapping is 97.55% | **Meaningless as measured** — it compared bare digests across entries, and a digest is unique only within its entry. Exact once entry identity is included |
| 牛津英汉汉英 has 68,123 entries | That is another project's database count. The installed bundle has **136,288** |
| `Tools/dictionary-depths` establishes the depth claim | **No such file.** The tests do |
| An adapter may declare its dictionaries' sense depth | **No** — it declares the id attribute only. `LanguageAdapters.profile` consults adapters before the measured override table, so a hardcoded depth there silently outranks the retention measurement. Held by `anAdapterCannotOverrideAMeasuredDepth` |
