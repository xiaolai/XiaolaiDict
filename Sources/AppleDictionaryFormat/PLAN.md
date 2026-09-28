# Plan — from a reader to a rebuild tool

**Status:** agreed order, nothing started. 2026-09-27.

**How this plan was arrived at:** the first version of it was wrong, and a second model in refute mode
(`gpt-6-astra`, read-only) found it wrong in five separate ways, each with a check that then failed when
run. §6 traces every step below to the objection that shaped it. The original order — rewrite the entry
reader first — is now step **3**, because two things have to be true before anything new is recovered.

**The order's one rule:** never recover a definition before the identity scheme can hold one. Recovering
first renames existing keys, and the test standing over that cannot currently fail.

---

## 0. The blocker: make a content key stable under insertion

**Status:** DONE — 2026-09-27
**Changed:** Sources/AppleDictionaryFormat/SenseKey.swift, Sources/AppleDictionaryFormat/EntryIndexer.swift, Sources/AppleDictionaryFormat/DictionarySurvey.swift, Tests/AppleDictionaryFormatTests/SenseKeyStabilityTests.swift, Tests/AppleDictionaryFormatTests/SenseKeyTests.swift, Tests/AppleDictionaryFormatTests/SenseKeyValidityTests.swift
**Verified:** `swift test --filter AppleDictionaryFormatTests` (60 tests in 12 suites passed) and, gated on the 9 readable bundles this Mac has, `XIAOLAIDICT_BUNDLES=… swift test --filter SenseKeyValidityTests` — **4,413 pairs, forward 100.00%, reverse 100.00%**, unchanged from before the change. All four checks below hold; the mutation that reintroduces the legacy ordinal scheme fails every one of them, which is what says they can fail.

**Recovering definitions renames existing keys today.** Measured:

```
definitions ["stop"]          -> ["6c45cb72a36e"]
definitions ["stop", "stop"]  -> ["6c45cb72a36e:0", "6c45cb72a36e:1"]
```

The first key *changed*. And document order decides which sibling owns `:0`, so reordering two
identically-worded sub-entries swaps their identities. Every later step adds definitions, so every later
step would silently rewrite the names of senses a reader has already studied.

**The cause is that the ordinal counts prior collisions.** A key must be a function of the sense, not of how
many siblings happen to share its wording.

**The change:** disambiguate on the sense's *structural position* — sub-entry label, sense number,
part-of-speech block — folded into the digest input, instead of appending `:ordinal`. Two identically worded
senses then differ because their positions differ, and neither depends on the other existing.

**Checks that decide it:**

| check | passes when |
|---|---|
| insert a definition anywhere; every pre-existing key keeps its value | property test over generated definition lists |
| delete a definition; every surviving key keeps its value | same test |
| reorder two identically-worded senses; each keeps its own key | same test |
| two senses genuinely identical in wording *and* position still get distinct keys | falls back to an ordinal only here, and this case is reported, not silent |

**Invariant that must not break:** publisher-id ↔ content-key exactness, currently 100% both directions over
75,401 pairs.

**Accepted cost:** a publisher renumbering its senses changes content keys. That is inherent to content
addressing and is why publisher ids are preferred where they exist.

---

## 1. Make the validity test able to fail

**Status:** DONE — 2026-09-27
**Changed:** Tests/AppleDictionaryFormatTests/SenseKeyValidityTests.swift
**Verified:** `XIAOLAIDICT_BUNDLES=… swift test --filter SenseKeyValidityTests` — **4,473 pairs from 3 dictionaries over 3,600 entries, forward 100.00%, reverse 100.00%**. The sample grew from 4,413 to 4,473: the 60 extra senses are the ones the old guard dropped whenever a sibling was content-keyed. The mutation — reintroducing that guard — now **fails** with `4413 pairs compared but 4473 senses carry a publisher id — 60 were dropped from the sample`, where before it passed at a printed 100.00%.

The sample-size assertion is stated as an exact equality against the walk (`pairs == sensesWithPublisherID`, `dictionariesWithIDs == dictionariesYieldingIDs`) rather than as a remembered 75,401, so it holds on any Mac regardless of which dictionaries it has.

Step 0 cannot be trusted while the test that guards it is structurally unable to notice.
`SenseKeyValidityTests` today:

- **skips any entry where some sense lacks a publisher id** (`guard publisherIDs.count == entry.senses.count`),
  so recovering content-keyed senses *removes entries from its own sample*;
- **requires reverse agreement only `> 0.90`**, while the measured figure is 100.00%.

Both together mean: recover definitions, watch the sample shrink, watch the suite stay green.

**The change:** compare every sense that has a publisher id rather than only entries where all do; assert
reverse exactness at 100%; print and assert the sample size so a shrinking denominator is visible.

**Check:** mutation. Reintroduce the `:ordinal`-on-collision behaviour from step 0 and confirm the suite
**fails**. If it still passes, the test is still decoration.

---

## 2. The definition predicate — recovers 28% of NOAD

**Status:** DONE — 2026-09-27
**Changed:** Sources/AppleDictionaryFormat/DictionaryProfile.swift, Sources/AppleDictionaryFormat/EntryIndexer.swift, Sources/AppleDictionaryFormat/DictionarySurvey.swift, Sources/AppleDictionaryFormat/ContainerReader.swift, Tests/AppleDictionaryFormatTests/DefinitionReachTests.swift, Tests/AppleDictionaryFormatTests/DepthRetentionTests.swift, Tests/AppleDictionaryFormatTests/SenseStructureTests.swift, Tests/AppleDictionaryFormatTests/SenseKeyValidityTests.swift
**Verified:** `XIAOLAIDICT_BUNDLES=… swift test --filter "DefinitionReachTests|DepthRetentionTests|SenseKeyValidityTests"` — 14 tests in 4 suites passed. Measured before and after over the 9 readable bundles on this Mac, by restricting the predicate to `d:def` and no sub-entries for the "before" run:

| dictionary | reached before | reached after | senses before | senses after |
|---|---|---|---|---|
| NOAD | 147,569 · 72.59% | 203,253 · **99.98%** | 147,569 | 183,172 |
| OAWT | 35,016 · 100.00% | 35,016 · 100.00% | 35,016 | 35,016 |
| ko-en.NewAce | 398,122 · 99.99% | 398,122 · 99.99% | 398,122 | 398,122 |
| ko.NewAce | 368,441 · 96.94% | 379,877 · 99.95% | 332,260 | 343,227 |
| zh_CN-en.OCD | 197,386 · 100.00% | 197,386 · 100.00% | 197,386 | 197,386 |
| zh_CN.SDCC | 96,512 · 98.80% | 97,682 · 100.00% | 96,512 | 97,358 |
| zh_CN.idioms | 20,625 · 92.61% | 22,270 · 100.00% | 17,482 | 18,347 |
| zh_CN.thes | 9,200 · 100.00% | 9,200 · 100.00% | 4,228 | 4,228 |
| zh_TW-en.DrEye | 171,126 · 97.56% | 175,401 · 100.00% | 159,047 | 160,556 |

**No dictionary loses senses** — every count rose or held. Sense identity is still exact both directions on a **larger** sample: 4,794 pairs against 4,473 before, forward and reverse 100.00%.

The "after" sense counts are the **final** ones, taken after three audit rounds. They rose again in the last round because a phrasal verb with several numbered senses was being emitted as one merged sense — NOAD's sub-entry senses went 9,777 → **12,109** when that was fixed. Definitions reached did not move: the same definitions, addressable separately. Retention re-measured on the corrected metric is bounded in [0, 1] and asserted so; the old count could exceed 100% and did.

**Three corrections the measurement forced, each of which had read as success.**

1. **The predicate is a union, not a swap.** Three of the nine dictionaries here — `OAWT`, `ko-en.NewAce`, `zh_CN-en.OCD` — carry **no `class="df"` at all** and mark every definition with `d:def` alone. Replacing the attribute test would have taken them from every definition to none.
2. **The denominator is the union too, and it is 203,299 for NOAD, not 197,761.** 5,538 elements carry `d:def` with no `df` class. Reproduced independently: 142,031 carry both, 55,730 `df` only, 5,538 attribute only. Against the plan's own denominator the restricted predicate reaches 147,569 / 197,761 = **74.6%**, the figure the ledger records — so the "before" state is confirmed, and the share moved only because the denominator was corrected.
3. **A refused record still declares what it declares.** Counting definitions only from accepted entries made NOAD read *exactly* 203,253 of 203,253 — a clean 100.00% — while 46 definition-marked elements sat in 27 records with no headword block and were unreachable. The aggregate coming out **exactly** equal is what gave it away. `EntryIndexer.Outcome` now reports a rejection and what the record declared, and both the reach test and `DictionarySurvey` count it.

**Not verified here:** ODE's 75.5%→99%+, "all 86" sense counts, and the re-ranking of the 16 lossy dictionaries need the full catalogue, which is on MBP16. Every check is gated on `XIAOLAIDICT_BUNDLES` and prints its figures, so one run there completes them.

`d:def` is not how a definition is marked; it is how *some* definitions are marked. Classifying every
`class="df"` element in NOAD by ancestry:

| where it sits | count | share |
|---|---|---|
| carries `d:def` — reached today | 142,031 | 71.8% |
| under `x_xd*`, no `d:def` | 23,494 | 11.9% |
| under `x_xdNsub`, no `d:def` | 19,580 | 9.9% |
| under `x_xo*` — a sub-entry | 12,610 | 6.4% |
| under neither | 46 | 0.0% |

**The change:** treat `class="df"` as a definition **wherever it appears inside a sense region**, not only
where it carries `d:def`. Structural access rises to 197,715 of 197,761 — **99.98%**.

**And fix the metric in the same step.** Retention counts `d:def=` on both sides of its ratio, so a
definition without the attribute is in neither numerator nor denominator; NOAD read a clean 100% with a
quarter unread. Retention must count `class="df"`, or it cannot verify this step.

**Checks:**

| check | passes when |
|---|---|
| definitions reached, NOAD and ODE | rises from 74.6%/75.5% toward 99%+ |
| no dictionary loses senses | per-dictionary sense counts, before against after, all 86 |
| sense identity | still exact both directions, and on a *larger* sample than before |
| retention re-measured on `class="df"` | the 16 lossy dictionaries are re-ranked honestly, not flattered |

**Not a tree, and not a new namespace reader.** This is a predicate in the existing walk. It was mistaken for
a sub-entry problem because the `give` entry, where phrasal verbs dominate, is unrepresentative.

---

## 3. The entry reader as a tree

**Status:** DONE — 2026-09-27
**Changed:** Sources/AppleDictionaryFormat/EntryTree.swift (new), Sources/AppleDictionaryFormat/EntryIndexer.swift, Sources/AppleDictionaryFormat/DictionaryProfile.swift, Tests/AppleDictionaryFormatTests/EntryTreeTests.swift (new), Tests/AppleDictionaryFormatTests/EntryReaderTests.swift (new)
**Verified:** `XIAOLAIDICT_BUNDLES=… swift test --filter AppleDictionaryFormatTests` — **92 tests in 17 suites passed** over the 9 readable bundles. All four checks hold:

| check | result |
|---|---|
| headwords — no `\|` | **0 headwords containing `\|`, 0 empty, 0 extra records refused**, across all 9 dictionaries |
| headwords — Bopomofo-interleaved come out clean | **failed at first, then fixed.** See the amendment below |
| mixed content | round-trip of ordered inline content is byte-identical over 7 fixtures |
| entry id with `senseIDAttributes: []` | present — read from `d:entry` directly, never through the sense attributes |
| **falsifiable prediction** | **confirmed** |

**Amendment, same day:** the Bopomofo half of the headword check was **not** verified by the run above, and
the independent audit found it failing. 譯典通 writes Bopomofo inside unclassed `<rt>` ruby elements, and the
headword filter excluded *classes* only — so installed entry `z_id000002`, whose headword is `一一`, came out
as `一ㄧ一ㄧ`. The `|` assertion passed throughout because ruby carries no delimiter. Ruby annotation is now
excluded by element name as well, and `rubyPronunciationIsNotPartOfTheHeadword` holds it. Recorded rather than
quietly corrected, because the shape is the one this plan keeps meeting: a check that passes while measuring
the wrong half.

**The prediction, and it held.** Key agreement rose for the contaminated dictionaries with **no change to the resolver**, and did not move for the ones that were already clean:

| dictionary | agreement before | after |
|---|---|---|
| ko.NewAce | 59.5% | **64.1%** |
| ko-en.NewAce | 73.5% | **78.0%** |
| NOAD | 92.9% | **94.4%** |
| OAWT | 99.0% | 99.0% |
| zh_CN-en.OCD | 100.0% | 100.0% |

The two Korean dictionaries moved most, and they are the ones whose headword blocks were worst contaminated — `ㄱㄴㄷ-순 (-順) \| -영-쑨 \|` for `ㄱㄴㄷ-순`, `@ \| ǽt;《약》 ət \|` for `@`. The two already at ceiling did not move at all. `he.oup`, the named subject at 6.0%, is not installed here; that one check needs MBP16.

**Sense identity unchanged by the rewrite:** 4,777 pairs, forward and reverse 100.00% — byte-identical to the figure before it. (4,794 after the audit rounds, still exact in both directions.)

**What the tree bought beyond the plan's list.** The three recorded defects go structurally: the shared text buffer is gone (each node owns its text), a nested matching sense block belongs to the sense above it, and `foundCDATA` is implemented. The namespace prefix is now read from the document's own `xmlns:` declaration instead of matched as a literal `d:`. `IndexedSubsense` carries the hierarchy beside the joined sense rather than instead of it, so nothing that existed changed shape.

**One defect the rewrite introduced and the measurement caught.** Making a sense own its whole subtree also swallowed a **sub-entry nested inside** one. 现代汉语规范词典 nests `x_xo[1-9]` inside `x_xd1` exactly 53 times — and losing those left no definition and no sense missing, so every total held; the only number that moved was the sub-entry count, 813 → 760. Sense-in-sense and sub-entry-in-sense are different questions, and the label is what scopes an alias, so conflating them would have brought back exactly the `give up` defect §4 exists to fix. Held by `aSubEntryNestedInsideASenseKeepsItsOwnLabel`.

Now worth doing, and smaller than claimed. It buys what a predicate cannot: **headwords without
pronunciation** (42 of 84 dictionaries), **sense numbers**, **sub-entry labels**, **the subsense
hierarchy** — and it retires the shared-buffer, nested-block and CDATA defects structurally rather than by
adding a ninth depth variable.

Two constraints the first design got wrong:

- **Mixed content must keep its order.** `<df>turn <b>off</b> now</df>` and `<df>turn now<b>off</b></df>`
  must not collapse to the same text: the definition text feeds the hash, so losing interleaving changes
  identities. Nodes carry *ordered inline content*, not `text` plus `children`.
- **The entry id is not a sense id.** Reading every identifier through `profile.senseIDAttributes` loses the
  entry's own `id` where a profile declares no attributes — `zh_TW-en.DrEye` declares none. Entry identity
  is its own field.

**Checks:**

| check | passes when |
|---|---|
| headwords | no headword contains `|`; Bopomofo-interleaved headwords come out clean |
| mixed content | round-trip of ordered inline content is byte-identical |
| entry id with `senseIDAttributes: []` | still present |
| **falsifiable prediction** | key agreement *rises* for contaminated dictionaries **without touching the resolver**; `he.oup` scores 6.0% and yields `Tranz.` as a headword, so it should jump. If agreement does not move, the diagnosis that headword extraction is the confound is wrong |

---

## 4. The schema

**Status:** DONE — 2026-09-27
**Changed:** Sources/AppleDictionaryFormat/IndexStore.swift (new), Tests/AppleDictionaryFormatTests/IndexStoreTests.swift (new)
**Verified:** `swift test --filter IndexStoreTests` — 12 tests passed; the whole module is **105 tests in 18 suites**. Each of the four scripts that failed against the first draft now passes:

| script | result |
|---|---|
| orphan alias rejected | `search_key` references its entry; an alias for an entry nothing created is refused |
| dangling `parent_key` rejected | composite self-reference; a NULL parent still passes, a parent in another entry does not |
| `give up` and `give in` return different candidate sets | `["to stop trying"]` against `["to yield to pressure"]`, while `give` still reaches all four |
| a bumped extractor generation forces a rebuild, an unchanged one does not | `extractor_gen` stored beside `content_ver`; `needsRebuild` reads both |

**`PRAGMA foreign_keys` is the trap under all four, and it is verified rather than set.** It is off by default, it is per connection, and SQLite says nothing when it is never enabled — so every constraint above would be decoration. `IndexStore` sets it and **reads it back**, failing to open rather than silently accepting orphans. Mutated to prove it: with the pragma off, **10 of the 12 assertions fail**, including "a stale alias resolved to an unrelated word" — the original defect, reproduced.

Designed against the tree, with four things the first draft got wrong — each demonstrated failing in SQLite:

- `search_key` had **no foreign key**. Deleting a dictionary left the alias behind; recreating the entry
  made that alias resolve to an unrelated word.
- `parent_key` pointing at a nonexistent sense was **accepted**.
- **No alias → sub-entry association**, so `give up` and `give in` both return `give`'s entire
  76-definition candidate set. Recovering phrasal-verb senses would not make them reachable — which defeats
  the point of recovering them.
- `content_ver` alone cannot express an **extractor generation**, so improving the reader would not trigger
  a rebuild of an unchanged asset.

**Checks:** the exact script that failed must pass — orphan alias rejected, dangling `parent_key` rejected,
`give up` and `give in` returning *different* candidate sets, and a bumped extractor generation forcing a
rebuild while an unchanged one does not.

---

## 5. The rebuild driver

**Status:** DONE — 2026-09-27
**Changed:** Sources/AppleDictionaryFormat/IndexRebuilder.swift (new), Sources/AppleDictionaryFormat/DictionaryLocator.swift, Sources/AppleDictionaryFormat/IndexStore.swift, Tests/AppleDictionaryFormatTests/IndexRebuilderTests.swift (new)
**Verified:** `swift test --filter AppleDictionaryFormatTests` — **114 tests in 20 suites**; and gated, `XIAOLAIDICT_BUNDLES=… swift test --filter IndexRebuilderMeasurementTests` — 2 tests passed in 354s. All three checks ran:

| check | result |
|---|---|
| a second run with nothing changed writes nothing | `.upToDate`, and **0 rows written** — read from `sqlite3_total_changes`, not from a timestamp |
| a bumped generation rebuilds | rebuilt, with the dictionary itself unchanged |
| a `disagrees` dictionary is skipped with a reason a reader could act on | `ko-en.NewAce` and `ko.NewAce` refused, each naming its score, the 80% bar, and that nothing is known to be wrong with the dictionary |

End to end on 现代汉语同义词典: **2,113 entries, 4,228 senses, 772 search keys**, and **50 of 50 probed keys reached a sense in the index it built**. `AppleDictionary` was refused first with `its container could not be read: KeyText.data: no chunks at 68`.

**A test that passed while checking none of this, caught and fixed.** The end-to-end test picked "the smallest bundle" to keep itself fast — and the smallest is `com.apple.dictionary.AppleDictionary`, the catalogue's one unreadable asset. It took the refusal branch and returned green having exercised neither the rebuild, nor the second run, nor the bumped generation. A refusal is a legitimate outcome for a *dictionary* and never for *this test*; it now walks candidates smallest-first until one actually rebuilds, and fails if none does.

**`contentVersion` is the declared version *and* the body's byte length.** Apple re-masters these — 牛津英汉汉英's copyright reads "© 2010, 2025" — and a re-master that leaves `CFBundleShortVersionString` alone still changes the bytes. Length rather than modification time: an asset re-download touches the mtime without changing a word, and rebuilding NOAD for nothing costs minutes.

**One tension worth naming.** Refusing an unverified dictionary outright is stricter than this module's own `DictionaryFacts.Usability`, which calls the same dictionary `sensesOnly` and still useful for its senses. The plan says refuse, so it refuses — but that means 2 of the 6 dictionaries assessed here contribute nothing at all, and if that is the wrong trade the rule is one function to change (`RebuildDecision.decide`).

Walk the installed set; rebuild a dictionary when its `content_ver` or the extractor generation changes;
report progress; **refuse any dictionary whose key mapping is not `verified`** rather than indexing it
quietly. Mechanical once 0–4 exist.

**Checks:** a second run with nothing changed writes nothing; a bumped generation rebuilds; a `disagrees`
dictionary is skipped with a reason a reader could act on.

---

## 6. Where each step came from

| step | objection that shaped it | check result |
|---|---|---|
| 0 | content keys not stable under insertion | **failed** — verified, keys renamed |
| 1 | the validity test cannot certify a migration | **failed** — verified by reading the guards |
| 2 | the predicate misses most of the missing definitions | **failed** — ancestry counts reproduced independently |
| 3 | tree loses mixed-content order; entry id lost with empty attributes | accepted on the reviewer's measurement, confirmed by reading the proposed type |
| 4 | orphan aliases; unchecked `parent_key`; no phrase scope; `content_ver` insufficient | **failed** — verified in SQLite |
| 5 | — | not attacked |

Nothing was overruled. Every objection carried a check and every check that was run failed as predicted,
which is why the order changed rather than the plan being defended.

---

## 7. Deliberately not doing

- **Sense selection.** A model's job; it lives in the app, not here.
- **Decoding the 20 uncertified dictionaries' key pointers.** Revisit *after* step 3 — if fixing headwords
  moves their agreement, there was never a pointer problem to solve.
- **Shipping any derived index.** It is built from dictionaries licensed to one reader's Mac.
- **Tuning the agreement threshold.** It would move dictionaries across a line without learning anything.

## 8. Effort

Agent-time, with clock-time called out separately because it does not shrink with parallelism.

| step | irreducible thinking | mechanical | clock-time |
|---|---|---|---|
| 0 identity | the position-based key design | property tests | one full-catalogue run, ~15 min sharded |
| 1 test | none — the guards are known | small edit | minutes |
| 2 predicate | none | predicate + metric | 2 catalogue runs |
| 3 tree | the node model | the walk, plus tests | 2–3 catalogue runs |
| 4 schema | representing sub-entries and hierarchy | DDL and queries | minutes |
| 5 driver | none | orchestration | one full rebuild |

Roughly **8–12 agent-hours** of work and **2–4 hours of waiting**, dominated by full-catalogue verification.
Steps 0–2 are about a third of that and recover the 28%.
