# Feature ledger — AppleDictionaryFormat

**Status:** implementation inventory, 2026-09-27. Every figure below was measured on this machine
against **all 86 assets in the macOS 27 dictionary catalogue**, downloaded and read; none is cited from
documentation. Findings and their fix history are in `AUDIT.md` beside this file; how each figure was
measured, and against which set, is in `RESEARCH.md`. **`DICTIONARIES.md` is the per-dictionary reference** — all 86, measured, with what each
one needs from an adapter. **`PLAN.md` is the agreed order of work**, and §4 below is what it closes.

**Which set matters.** The catalogue figures come from the full 86 downloaded that day. An ordinary Mac
carries only what its region and language selected — this one has 16, of which 10 are Apple's own and
9 are readable — and the gated tests **print "not measured" and pass** when `XIAOLAIDICT_BUNDLES` is
unset, so a green suite is not by itself evidence that a measurement ran. Re-verified on the 9 readable
Apple dictionaries after `PLAN.md` steps 0–5 and three rounds of independent audit: **151 tests in 21
suites pass**, forward and reverse 100.00% over the **4,794** pairs among them.

**Figures marked *catalogue* below have not been re-measured since `PLAN.md` was carried out.** Steps 0–3
changed what the reader extracts — NOAD went from 147,569 definitions to 203,253 — so any per-dictionary
figure taken before that is stale for the 77 assets this Mac does not have. Every gated test prints its
numbers, so one run against the full catalogue refreshes them.

**What this module is for:** to let xiaolaidict build its own index from the dictionaries Apple already
put on the reader's Mac, so that nothing licensed ever ships and nothing has to be downloaded but a
model. It reads Apple's container, names senses durably, and **builds and persists an index** — `IndexStore`
and `IndexRebuilder`, added by `PLAN.md` steps 4 and 5.

**Dependencies:** `Foundation`, `Compression`, `CryptoKit`, `SQLite3`. No app target, no third-party
package — `libsqlite3` ships with macOS. It compiles and tests without the rest of the project, which is
what makes it shippable on its own.

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
| Verify a chunk against its own checksum | Implemented | `aStreamWithAWrongChecksumIsRefused`, `adler32MatchesTheKnownVectors`. The zlib header's check value **and** the publisher's Adler-32 are compared against the decompressed bytes — output length alone never established integrity, since probes decoded identical bytes with an invalid header, an altered checksum and none at all. Verified present and correct over 400 NOAD body chunks and 460 key chunks across three dictionaries; all 9 readable dictionaries still read |
| Survey a dictionary against every fact known | Implemented | `DictionarySurvey.measure` returns `DictionaryFacts` in one pass: container, senses, depth retention, which id attribute actually carries ids, headword hygiene, keys, and a usability verdict. `DICTIONARIES.md` is generated from it over all 86 |
| Parse `KeyText.data` into keys | Implemented | `KeyIndexReader`. **252,428 groups and 396,529 key strings** from NOAD, against the 271,029 records Apple's index reports. 39.0% of its groups hold a phrase; `KeyIndexReaderTests` covers the format on invented bytes |
| Resolve an inflected or variant form to its entry | Implemented | Every form tested lands on the right base entry: `children`→`child`, `went`→`go`, `was`→`be`, `oxen`→`ox`, `feet`→`foot`, `mice`→`mouse`, plus regular forms. NOAD yields **259,497 distinct key strings for 111,579 entries**. Resolution is to the **entry**, never to the sense |
| Resolve a key to its entry | Implemented, gated | `KeyIndexBuilder`. NOAD **250,196 of 252,428 (99.12%)**; four other dictionaries resolve 100%. The chunk table is *derived* by intersection, not reverse-engineered — see `RESEARCH.md` §5 |
| Withhold a mapping that cannot be certified | Implemented | `KeyResolutionReport.confidence` over all 86: **64 verified, 10 unverified, 10 disagreeing, 2 without keys**. Agreement measures a chain — mapping, headword extraction, and whether the oracle can see that language — so a low score withholds rather than impeaches |
| Split an entry into senses | Implemented | `EntryIndexer`. `x_xd0` is the part-of-speech block, `x_xdN` a sense at that dictionary's own depth, anything deeper belongs to the sense above. **Depth 1 for 79 of 84; five nest deeper** — see the depth row below |
| Sense depth declared per dictionary, chosen by retention | Implemented | `DepthRetentionTests` re-measures **every installed dictionary** and fails if a declared depth loses definitions: *84 measured, 0 declaring a lossy depth*. Five need a deeper one — Vietnamese keeps only **23%** of its `d:def` elements at depth 1 and 103% at depth 2, Greek **48%** against 100% at depth 3, plus `ml-en`, `as-en`, `kn-en` at depth 2 |
| One sense per sense block | Implemented | `noSenseBlockYieldsTwoSensesUnderOnePublisherID`, over **34,068 id-bearing entries**. A block can hold several `d:def`; the extras are cross-references — "American English = rappel" — and emitting one sense each gave 1,112 publisher ids two identities |
| Durable sense identity | Implemented | `SenseKey`. Publisher id where the dictionary has one, content-addressed digest where it does not. **Exact in both directions, 100.00%, over 75,401 pairs from 50 dictionaries**, measured through `EntryIndexer` itself |
| Reach a definition however it is marked | Implemented | `DefinitionReachTests`. `d:def` **or** `class="df"`, inside a main-sense region **or** a sub-entry. NOAD reaches **203,253 of 203,299, 99.98%**, against 147,569 · 72.59% when only the attribute was read. A union rather than a swap: `OAWT`, `ko-en.NewAce` and `zh_CN-en.OCD` carry no `class="df"` at all and would have lost every definition |
| Sub-entry senses — phrasal verbs and idioms | Implemented | `subEntrySensesAreRecoveredWhereTheMarkupDeclaresThem`. NOAD yields **12,109**, ko.NewAce 10,967, SDCC 899 — **one sense per numbered sense inside the sub-entry**, not one per sub-entry: `give up` has five and `take off` six, and emitting the sub-entry whole merged them into a single definition. Each carries its own label, which is what scopes an alias so `give up` does not return all 76 of `give`'s definitions. Five of the nine dictionaries here open sub-entry regions holding **no** definition-marked element — synonyms and examples — so a region is not evidence of a sense |
| Read an entry as a tree | Implemented | `EntryTree`, `EntryTreeTests`. Ordered inline content, so `<df>turn <b>off</b> now</df>` and `<df>turn now<b>off</b></df>` keep different identities; round-trip byte-identical. Retires the shared-buffer, nested-block and CDATA defects structurally, and resolves the `d:` prefix from the document's own `xmlns:` declaration |
| Headwords without pronunciation | Implemented | `noHeadwordCarriesAPronunciation` — **0 headwords containing `\|`, 0 empty, 0 extra records refused** across all 9. Prefers the `hw` span, and excludes `gp`/`prx`/`pr`/`ph`/`syl_txt` **and the `rt`/`rp` ruby elements** — 譯典通 puts Bopomofo in unclassed `<rt>`, so a class-only filter turned `一一` into `一ㄧ一ㄧ` while the `\|` check reported success. A fallback to the raw text means filtering can never empty a headword and refuse the entry |
| Sense numbers, sub-entry labels, subsense hierarchy | Implemented | `SensePosition` carries the first two and feeds them into the key; `IndexedSubsense` carries the third **beside** the joined sense rather than instead of it, so 一's six glosses stay whole while `1a`/`1b` become addressable |
| Persist an index | Implemented | `IndexStore`, `IndexStoreTests`. Foreign keys on every reference and **`PRAGMA foreign_keys` read back after being set** — it is off by default and per connection, and with it off 10 of 12 assertions fail. Orphan alias refused, dangling `parent_key` refused, `give up` and `give in` return different candidate sets, `extractor_gen` stored beside `content_ver`. A schema whose `user_version` is not this one is **discarded, not migrated** — the index is derived and can always be rebuilt |
| Notice that a dictionary's content changed | Implemented | `DictionaryBundle.contentVersion` — a streaming SHA-256 of **`Body.data` and `KeyText.data`**, with the declared version. A body *length* was the first attempt and missed two real cases: a same-size replacement, and a change confined to the key file, which decides what can be looked up at all. Either left a rebuild reporting `upToDate` over stale senses for ever |
| Rebuild the index from the installed set | Implemented | `IndexRebuilder`, `RebuildDecisionTests`. Rebuilds on a changed `content_ver` **or** a bumped extractor generation, reports progress, and **refuses any dictionary whose mapping is not `verified`** with a reason naming the score and the bar. A refusal **withdraws** whatever was indexed before, because `candidates(for:)` does not filter by verification status — except a storage failure, which is a verdict about the store and not the dictionary. An empty replacement rolls back rather than committing over a good index |
| Per-dictionary facts as declarations | Implemented | `DictionaryProfile`. Two fields vary, both measured: `senseIDAttributes` — measured by indexing each dictionary both ways: `lexid` only in 27, `id` only in 24, **both in 10**, neither in 23 — and `senseDepth`, which departs from 1 in five. An adapter may pin the first and never the second |
| Five language adapters, each declaring only what it measured | Implemented | `SimplifiedChinese`, `TraditionalChinese`, `Cantonese`, `Korean`, `Japanese`. `declaredIDAttributesMatchRealBundles` reads each declaration back through the indexer over **15 installed dictionaries**; a wrong declaration fails the suite, which is how three of them were caught |
| Authorship recorded, not assumed | Implemented | `authorshipIsRecordedRatherThanAssumed`. Apple licenses its whole third-party programme through Oxford, so nearly every bundle looks Oxford. **Only Simplified Chinese and Cantonese have an Oxford-authored work**; Japanese is Sanseido, Korean DIOTEK, Traditional Chinese INVENTEC |

---

## 3. Partial — works, with a recorded gap

These are real and open. The six rows that said "needs the entry reader reworked" were closed by
`PLAN.md` step 3, which reworked it; what remains is listed rather than silently carried.

| Gap | Effect | Where |
|---|---|---|
| 20 dictionaries' key mappings are not certified | 10 agree 50–80%, 10 below 50%. None is shown to be wrong: agreement also fails when headword extraction is broken (`he.oup` yields `Tranz.` as a headword) or when the oracle cannot see the language. Withheld, not impeached | `KeyResolutionReport.confidence`, `DICTIONARIES.md` §5.7 |
| Agreement cannot localise its own failure | A low score means the mapping, the headword, or the oracle — and this module cannot say which. Distinguishing them needs an oracle outside it, which is the next real step for the 20 | `KeyAgreement` |
| Some definitions are still lost at the best available depth | The worst case is **18.3% in `com.apple.dictionary.or-en.oup`**, and no depth recovers it — the loss is not depth choice but definitions the reader does not reach at all. Measured, bounded, and not yet explained | `SenseKeyValidityTests` reports it every run |
| A failed key chunk is skipped silently | One surviving chunk makes the whole read look successful | `ContainerReader.keyChunks` |
| Subsense hierarchy is one level deep | `IndexedSubsense` carries a numbered sense's parts, but a subsense of a subsense is flattened into its parent's text. No dictionary measured here nests that far, so it is recorded rather than built | `EntryIndexer.Walk` |
| A sub-entry inside a sub-entry is absorbed by the outer | The outermost `x_xo<N>` owns its whole subtree, so a nested one contributes its definitions without its own label. 现代汉语规范词典 nests `x_xo[1-9]` inside another 64,893 times, and how many are genuine second-level sub-entries is not measured | `DictionaryProfile.marksSubEntry` |
| Definitions in refused records are unreachable | NOAD: **46 in 27 records with no headword block**, ko.NewAce 175 in 166. Counted in the denominator now, so the loss is visible rather than silent — but nothing recovers them | `EntryIndexer.Outcome` |
| Refusal is all-or-nothing per dictionary | `IndexRebuilder` refuses a dictionary whose mapping is not `verified`, so its senses go unindexed too — stricter than `DictionaryFacts.Usability`, which calls the same dictionary `sensesOnly` and still useful. 2 of the 6 assessed here are refused on this rule | `IndexRebuilder`, `RebuildDecision` |

---

## 4. Not built — what a rebuild tool still needs

**The module reads, names, persists and rebuilds. It does not match.** Naming the boundary plainly because
an index a reader can query by exact search key is easy to mistake for one that finds the phrase under their
cursor, and that is the row still open below.

**Four rows that were here are now built**, by `PLAN.md` steps 2–5, and are recorded in §2 with the
measurements that closed them: definitions with no `d:def` attribute (NOAD 74.6% → **99.98%**), sub-entry
senses (**12,109** in NOAD), the persistence layer (`IndexStore`), and the rebuild driver
(`IndexRebuilder`). What is still missing:

| Missing | Why it matters |
|---|---|
| Phrase matching on hover | Measured elsewhere at **39.2% coverage, 86.6% recall, 83.8% ranked first** from NOAD alone — but that was a different implementation, not this module |
| Cross-dictionary sense alignment | Direct alignments exist at **0.952 mean confidence** (thesaurus→NOAD, 31,828 pairs) and **44% by arithmetic** for Oxford Chinese→NOAD, but computed elsewhere and not by this module |
| Inflection resolution | **The keys are now readable and they carry it** — `'roos` resolves to `roo`, `&c.` to `etc.` — but nothing yet turns a reader's inflected word into a lookup. 60.1% of NOAD's resolved keys are a form its headword does not contain, so the material is there and unexploited |

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
| A pointer that lands on a record resolved correctly | **Still no** — "resolved" and "correct" are different measurements. But the example this claim was made with was wrong: see the row below |
| `zh_TW-en.DrEye` resolves 96.5% of its keys to the wrong entry | **False, and stated in a commit message before it was checked.** That came from an oracle asking whether the headword *contained* the key; DrEye interleaves Bopomofo between every character, so containment could never match. Under `KeyAgreement` it scores **100.0%** and is verified. The measurement was broken, not the dictionary |
| Retention of 100% means every definition is read | **No.** It counts `d:def=`, and a sub-entry definition carries `class=\"df\"` with no `d:def` attribute. NOAD measured 100% retention while a quarter of its definitions were never reached, because they were not in the denominator either |
| Low agreement means the key mapping is wrong | **No.** It means the mapping, the headword extraction, or the oracle's blind spot — three causes this module cannot tell apart. `he.oup` scores 6.0% and yields `Tranz.` as a headword |
| An adapter may declare its dictionaries' sense depth | **No** — it declares the id attribute only. `LanguageAdapters.profile` consults adapters before the measured override table, so a hardcoded depth there silently outranks the retention measurement. Held by `anAdapterCannotOverrideAMeasuredDepth` |
| NOAD declares 197,761 definitions | **203,299.** That counted `class="df"` only; **5,538 elements carry `d:def` with no `df` class**, and three of the nine dictionaries here mark *every* definition that way. The honest denominator is the union, which is why the predicate is a union and not a swap. Against the old denominator the old predicate reaches 147,569 / 197,761 = 74.6%, so the recorded figure was right about the numerator and wrong about the whole |
| Retention of 100% means every declared definition is reached | **Still no, one layer up.** Counting only from records that became entries made NOAD read *exactly* 203,253 of 203,253 while 46 definitions sat in 27 records with no headword block. An aggregate coming out **exactly** equal is what gave it away; merely close would have been believed. `EntryIndexer.Outcome` now reports what a refused record declared |
| A sense owning its whole subtree is always right | **Not for a sub-entry inside it.** The maximal-sense rule that retires the nested-block defect also swallowed 53 of 现代汉语规范词典's sub-entries. No definition and no sense was lost, so every total held and only the sub-entry count moved, 813 → 760 — and the label is what scopes an alias, so the `give up` defect would have come straight back |
| A test that passes has tested something | **Not if it took the other branch.** The rebuild driver's end-to-end test chose "the smallest bundle", which is `AppleDictionary` — the one unreadable asset — took the refusal path, and returned green having exercised none of step 5's three checks. It now walks candidates until one actually rebuilds and fails if none does |
| Declaring `PRAGMA foreign_keys = ON` makes it on | **Only if it is read back.** The pragma is off by default, is per connection, and SQLite says nothing when it is never enabled. With it off, 10 of `IndexStoreTests`' 12 assertions fail — so every constraint in the schema was one silent line away from decoration |
