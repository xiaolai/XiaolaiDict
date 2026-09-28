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

Eight findings needed the entry reader reworked rather than patched at a call site, so they were recorded
in the feature ledger §3 with their effect and left visible instead of silently carried:
the shared capture buffer, part of speech not scoped to its `x_xd0`, nested sense blocks clobbering
state, dropped CDATA, headword swallowing pronunciations, narrower namespace resolution than claimed,
the unvalidated Adler-32, and silently skipped key chunks.

**Six of the eight were closed on 2026-09-27 by `PLAN.md` step 3**, which reworked the reader as a tree and
so retired them structurally rather than by adding a ninth depth variable: the shared buffer is gone because
each node owns its own text, a nested matching sense block belongs to the sense above it, `foundCDATA` is
implemented, the headword prefers its `hw` span and skips pronunciation, and the `d:` prefix is resolved from
the document's own `xmlns:` declaration. Part-of-speech scoping had already been fixed. Two remained open at
that point — the unvalidated Adler-32 and silently skipped key chunks; **the Adler-32 was closed in §6 below**
and the skipped key chunks are still carried in the ledger §3.

Of the three lower-severity ones, **one is closed**: adding a second identical definition no longer renames
an existing bare digest, because the first occurrence keeps it and only later repeats take an ordinal — the
defect `PLAN.md` step 0 exists to remove, held by `appendingARepeatDoesNotRenameTheOriginal`. Two remained
open: both readers overread the compressed stream by four bytes, and chunk bounds are checked against the
file rather than the declared payload extent. **The four-byte overread was measured and closed in §6**; the
chunk-bound check is still open.

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

---

## 5. Audit after `PLAN.md`, 2026-09-27 — what an independent model found in the new code

The nine changed and created sources were audited file by file across all nine dimensions by
`gpt-6-astra` at high effort, read-only — the same model whose refutation reordered the plan. It reproduced
several findings against installed dictionaries rather than reasoning about them, which is what made them
worth acting on immediately.

**The ones that mattered most, and why each was believed:**

| finding | evidence that settled it |
|---|---|
| A subsense could take another sense's key | Constructed: an unnumbered sense defining `A` beside a sense holding unlabelled subsenses `A`, `B`. Keys were assigned per parent, so the first sense and the `A` subsense matched — and `IndexStore` writes that key as a primary key with `INSERT OR REPLACE`, so six records became five rows. Keys are now assigned across the whole entry at once |
| Ruby pronunciation stayed in headwords | **Installed** 譯典通 entry `z_id000002`, headword `一一`, came out `一ㄧ一ㄧ`. Bopomofo sits in unclassed `<rt>`, so a class-only filter could not see it and the "no `\|` in a headword" check passed. This is the plan's own §3 check — *Bopomofo-interleaved headwords come out clean* — which had gone unverified |
| A nested sub-entry lent its part of speech to its parent | **Installed** 现代汉语规范词典 entry `0000215`: `形` belongs to sub-entry `嚣嚣`, and the main sense inherited it. The definition walk stopped at sub-entry boundaries; the part-of-speech, sense-number and subsense searches did not. One ownership rule now serves all four |
| A definition wrapper absorbed a nested sub-entry | Synthetic: `declared 1, captured 2`, retention **2.0** — breaking the bound this module had just started asserting. Both the text extraction *and* the declared count now use the same ownership rule |
| A refusal left the previous index searchable | `candidates(for:)` does not filter by verification status, so a dictionary that stopped verifying stayed queryable — which made checking refusal before freshness pointless. A refusal now withdraws the rows, except for a storage failure, which is not a verdict about the dictionary |
| The zero-entry refusal happened after the commit | `beginRebuild` deletes the previous index first, so `.noEntries` destroyed it *and* recorded the empty result as current. The check moved inside the transaction |
| `contentVersion` could not see a content change | Constructed two different bodies fingerprinting alike, and a change confined to `KeyText.data` is invisible to a body length. Now a streaming SHA-256 of both files |
| A lookup returned a sense once per alias | `give` and `Give` share a folded search key, so the join returned the same sense twice. Now an `EXISTS` predicate |

**Two findings were about the tests rather than the code, and both were right.** The pronunciation test could
not detect the ruby defect it was written to catch, because it only looked for `|`. And the rebuild driver's
end-to-end test chose "the smallest bundle", which is `AppleDictionary` — the one unreadable asset — so it
took the refusal branch and returned green having exercised none of the three checks step 5 names.

**Also fixed, each cheap and each a silent-failure generator:** a file-controlled decompressed size was
allocated unbounded (a chunk declaring `0xffffffff` asked for 4 GiB); `limit: 0` delivered one entry because
the limit was checked after delivery; `Int("01") == 1` meant `x_xd01` opened a sense region; a document
declaring an XML entity parsed *successfully* and silently dropped the entity's text; a bound multi-statement
call would have run only its first statement; `sqlite3_bind_text` with `-1` truncated a string at an embedded
NUL; one document-wide namespace prefix let a child rebinding blind an earlier sibling; and `xmlns:d` bound
to an unrelated namespace was still read as Apple's.

**One fix was wrong on its first attempt, in the way this file keeps recording.** The multi-statement guard
scanned the SQL for `;` and rejected four of the store's own queries — one has a semicolon inside a SQL
comment. The same substring-versus-token mistake as reading `x_xd1sub` as a sense. It now asks SQLite what it
left unconsumed (`pzTail`), which cannot be fooled by a comment or a literal.

**Still open after this round**, and carried in the ledger §3: the unvalidated Adler-32 (the wrapper is
stripped and raw deflate decoded, so checksum corruption passes), silently skipped key chunks, both readers
reading the compressed-length field four bytes too generously, and chunk bounds checked against the file
rather than the declared payload extent.

> **Superseded, 2026-09-28.** The first and third of those were measured and closed in §6. The other two —
> silently skipped key chunks, and chunk bounds checked against the file rather than the declared payload
> extent — are still open.

**Three rounds were run, and the severity fell as the fixes landed:** 4 Critical/High in round 1, 4 again in
round 2 — three of which were regressions the round-1 fixes had introduced — and **1 in round 3**, with
`SenseKey.swift` returning no findings at all. Two of round 2's were mine in the plainest way: the fix that
canonicalised a sub-entry alias was written and then **refactored out from under itself** when the insert was
extracted into a method, and the withdrawal-on-refusal rule was applied at one `return` while three others
kept deciding it for themselves. Both now live in one place — the bind, and `RebuildRefusal.withdrawsTheIndex`
— because a rule spread across call sites is a rule that will be forgotten at the next one.

Round 3's single High was the one worth the whole exercise. **A phrasal verb with several numbered senses was
emitted as one.** Installed NOAD `m_en_gbus0415220` (`give`) carries five numbered `x_xo2` senses under
`give up`, and `take off` six; all of them came back joined by `; `. That is the defect `PLAN.md` §4 exists to
prevent — `give up` returning `give`'s whole candidate set — reproduced one level down, and the plan's own
§2 status block had said the granularity would be refined in §3 and then it never was. Fixed: one sense per
numbered block, each with its own publisher id and sense number. NOAD's sub-entry senses went 9,777 →
**12,109** with the definitions reached unchanged, which is exactly the shape of the correction — the same
content, separately addressable.

**Findings files:** `.cc-suite/audits/audit-fix-*-findings.md`, one per round, each carrying the model's
verbatim output per file.

---

## 6. The fourth round — two format claims verified, and a class of traversal bug

A fourth audit was run over the same nine files after the third round's fixes. Severity fell to **1 High,
22 Medium, 9 Low**, with `ContainerReader.swift` and `DictionarySurvey.swift` returning **no findings**.

**Two claims the ledger had carried for a while were measured and turned out true.** They had sat as "open,
low priority" because nothing failed on account of them:

| claim | measurement |
|---|---|
| Both readers overread each compressed stream by four bytes | `size - compressed` is a constant **4** in every body chunk of NOAD. Every one of 400 chunks decompresses correctly from `compressed - 4` bytes, and the same holds for 460 key chunks across NOAD, the Oxford thesaurus and 牛津英汉汉英. The `compressed` field is inclusive of the decompressed-size word that follows it; slicing the whole field read four bytes of the *next* chunk's header. zlib stops at the end of its stream and ignored them, which is why nothing ever failed — and why every bounds check was four bytes too lax |
| Adler-32 is never checked | The trailer is present and **correct in all 860 chunks checked**, sitting in the last four bytes of the `compressed - 4` stream. Native probes decoded identical output with an invalid header, an altered checksum and no checksum at all, so a matching output length was never evidence of integrity |

Both are now enforced: the stream length is `compressed - 4`, the zlib header's own check value is validated,
and the publisher's Adler-32 is compared against the decompressed bytes. **All nine readable dictionaries
still read** — about 7,200 body chunks and 4,400 key chunks now pass a checksum they were never asked for,
with every definition and agreement figure unchanged.

**The High was a regression from the third round's own fix.** Splitting a phrasal verb into its numbered
senses borrowed the sub-entry's publisher id for each of them, so two id-less `x_xo2` blocks under one
id-bearing `x_xo1` got the *same* publisher key — and `IndexStore` writes that as a primary key with
`INSERT OR REPLACE`. The wrapper's id may now be borrowed only when it names exactly one emitted sense.

**And one traversal ambiguity caused the same defect three times, which is what finally made it structural.**
`maximalDescendants` matches the receiver before descending. That is right when the question is "what
definition regions does this region own" — a sub-entry marked `class="x_xo1 df"` *is* its own definition — and
wrong every time the question is "what is nested inside this". Asked the wrong way it: returned the node a
nested-sub-entry search started from and quietly did nothing; recursed forever on a node that was both a
sub-entry and a definition, crashing the test process with `SIGBUS`; and would have returned a subsense equal
to its own parent. `maximalNestedDescendants` is now a separate operation that never returns the receiver, and
every "what is inside this" call site uses it.

**Two more constraint holes closed, both of the same shape as the `PRAGMA foreign_keys` one** — a check that
looks present and enforces nothing. `origin` was missing from the sense primary key, so a publisher id that
reads like a content digest and the content key with that digest were one row; adding it exposed a second
omission one statement away, where the lookup's `GROUP BY` still collapsed on three of the four columns. And
adding `parent_origin` for the reference silently *disabled* the dangling-parent check, because a composite
foreign key is satisfied when any of its columns is NULL — a `CHECK ((parent_key IS NULL) = (parent_origin IS
NULL))` makes the pairing a constraint rather than something a call site has to remember.
