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
| Which attribute carries the publisher id? | Measured by indexing each dictionary both ways: `lexid` only **27**, `id` only **24**, **both 10**, neither **23** | `DictionarySurvey`. An earlier probe said 33/24/27 — it agreed on `id` exactly, and could not represent a dictionary carrying both |

## 4. Authorship

Apple licenses its whole third-party dictionary programme through Oxford, so nearly every bundle looks
Oxford-authored at a glance. Measured per bundle instead: of the five languages with adapters, **only
Simplified Chinese and Cantonese carry an Oxford-authored work.** Japanese is Sanseido, Korean DIOTEK,
Traditional Chinese INVENTEC. Asserted by `authorshipIsRecordedRatherThanAssumed`.

Three adapter declarations originally claimed an `id` attribute where the indexer found 0%, 1% and 0%.
`declaredIDAttributesMatchRealBundles` reads every declaration back through the indexer over the 15
installed dictionaries, which is how all three were caught — and why the check had to stop being
circular (`AUDIT.md` #25).

## 5. The key index — format, and why the chunk table is derived

`KeyText.data` holds the search keys. Nothing else does: NOAD's entries contain **0 `d:index` elements**,
so Apple strips them at build time and the keys exist only here. Dictionary Services cannot enumerate
them either, which is why this file has to be read.

### The group layout, measured

| field | width | meaning |
|---|---|---|
| `groupSize` | UInt32 | bytes after this field; groups chain by it |
| — | UInt32 | 1 in every group seen |
| — | UInt16 | always `groupSize - 6` |
| `offset` | UInt32 | the entry's offset **inside its decompressed body chunk** |
| `chunkID` | UInt16 | Apple's identifier for that chunk |
| `keyBytes` | UInt32 | length of the key block; **not reliable in every dictionary** |
| keys | — | `UInt16 byteLength` + UTF-16LE text, until a zero length |

**The trap that cost the most.** The two bytes after a key's length field look like a tag. They are not:
for `čapek` they are `0d 01`, which is U+010D, `č`. Read as a tag they truncate the first character of
every key — `čapek` becomes `apek`, `české budějovice` becomes `eske budejovic`. Both still look like
words, which is exactly why it survived a first look.

`offset` was confirmed directly rather than assumed: for the key `čapek` it is 172749, and the record at
byte 172749 of body chunk 104 is entry `m_en_gbus0149730`, "Čapek, Karel".

### Why the chunk table is derived rather than decoded

`chunkID` has **no arithmetic relation to anything**. Checked against the chunk's index, its file offset,
its compressed size and its decompressed size — none correlates. Chunk 21 is id 35546, chunk 50 is id
8594, chunk 104 is id 22015.

It does not need decoding, because it is *implied*. Every group carrying id X points into one chunk, so
that chunk must appear in the candidate set for **every** group with id X. Intersecting those sets cannot
admit a wrong answer. On NOAD it pins 774 ids, leaving 1 ambiguous.

Two things had to be got right for that to work:

- **An offset alone is not enough.** Only **68.3%** of NOAD's records sit at an offset no other record
  shares, so a join on offset alone silently mismatches a third of the dictionary.
- **One group must not be able to erase a chunk id.** Intersecting blindly let a single group whose offset
  matched no record anywhere empty the set for its whole id, losing 4,829 groups across 7 ids. A group
  that cannot be satisfied is dropped; it is that group's problem, not the chunk's.

### What it yields, and what it refuses

Measured over all 86. **64 verified, 10 unverified, 10 disagreeing, 2 with no keys at all.** The full
per-dictionary table is in `DICTIONARIES.md` §4; what belongs here is what the numbers mean.

Agreement is the share of resolved groups whose key and headword **share an opening** once pronunciation
is stripped. The obvious test — does the headword *contain* the key — does not work, and believing it cost
a wrong conclusion that reached a commit message:

| dictionary | containment | shared opening | |
|---|---|---|---|
| `zh_TW-en.DrEye` | 3.5% | **100.0%** | headwords interleave Bopomofo between every character |
| `ru.oup` | 7.9% | **93.6%** | suffix inflection: `вое`, `вои`, `воя` all belong to `вой` |
| `zh_TW.wn` | 6.9% | **96.5%** | Bopomofo again |
| `bn-en.oup` | 64.4% | **90.5%** | compounds: `অংশ করা` belongs under `অংশ` |
| `da-en.oup` | 77.5% | **97.1%** | `a aktier` against the headword `A-aktier` |
| `NOAD` | 82.4% | **92.9%** | |

**DrEye was described as resolving 96.5% of its keys to the wrong entry. It resolves them correctly.**
Containment could never have matched a headword written `三ㄙㄢ言ㄧㄢˊ`. The measurement was broken, not
the dictionary — and the test standing over it asserted the wrong dictionary was bad, which would have
blocked the fix.

**What a low score still cannot tell you.** Agreement measures a chain of three things, and fails if any
one of them fails:

1. the key mapping is wrong;
2. the **headword extraction** is wrong — `he.oup` scores 6.0% and yields `Tranz.` as a headword, which is
   this module's own recorded `x_xh0` defect and has nothing to do with keys;
3. the oracle is blind to that language — a kana key against a kanji headword shares no opening, and
   neither does a prefix-inflecting morphology.

So the 20 uncertified dictionaries are **withheld, not impeached.** Separating the three causes needs an
oracle outside this module, and that is the honest next step rather than tuning the threshold.

## 6. What the keys add that entries do not

**60.1% of NOAD's resolved keys are a form its headword does not contain.** `'roos` → `roo`, `'hood` →
`hood`, `&c.` → `etc.` — inflections, elisions and variants. **39.0% of its groups hold a phrase.** This
is the whole reason to read the file: scanning entries finds headwords, and a reader who meets `'roos` or
`mass-produced` on a page is not looking up a headword.
## 7. What is indexed, and what is not — inflections, POS, nesting, phrases

Asked directly, and measured rather than assumed. The answers differ sharply per question.

### Inflections — yes, and completely

Every form tested resolves to the right base entry. Irregulars: `children`→`child`, `went`→`go 1`,
`was`→`be`, `oxen`→`ox`, `feet`→`foot`, `mice`→`mouse`, `geese`→`goose`, `ran`→`run`. Regulars: `dogs`,
`running`, `happier`, `walked`, `studies` all land correctly. NOAD carries **259,497 distinct key strings
for 111,579 entries** — 2.3 ways of finding an average entry.

**But resolution is to the entry, never to the sense.** `ran` gives you `run`'s entry, not which of its
senses is meant. That is what the sense ladder in the app is for; it is not something the index can answer.

### Part of speech — present, and it was wrong

Coverage is high: **median 98.8% of senses labelled**, 21 dictionaries at 100%. Seven label under half;
`ja.Daijirin` labels 19.2%, and one Cantonese dictionary labels none, so anything narrowing by part of
speech must treat its absence as "unknown" rather than as "no match".

The label itself was **wrong** for a shape that occurs in real entries. `currentPOS` was set when a `d:pos`
element closed and never cleared, so a second `x_xd0` block declaring no part of speech inherited the
first's — a verb sense reported as a noun. Now scoped to its own block and held by
`partOfSpeechIsScopedToItsOwnBlock`. Wrong in the worst direction: a narrowing filter would have selected
the wrong senses rather than none, which looks like an answer.

### Nested senses — flattened, and the hierarchy is gone

The structure is `x_xd0` → `x_xd1` (a numbered sense) → `x_xd1sub` (the subsense actually holding
`d:def`). Where a numbered sense holds several subsenses they are **joined with `; ` into one sense**.
Joining is the right call — the alternative, keeping the first, destroyed five of six co-equal glosses in
one real entry — but `1a` and `1b` become indistinguishable and **nothing carries the sense number or a
parent**. In NOAD the counts happen to be equal (147,569 senses for 147,569 `d:def=`), so no joining
occurs there in practice; in dictionaries that do nest, it does.

### Phrases, idioms and phrasal verbs — the largest gap in the module

Three different situations, and only one of them works.

| kind | example | outcome |
|---|---|---|
| multi-word **entry** | `ice cream`, `hot dog`, `New York`, `point of view` | **works** — its own entry, its own senses |
| **phrasal verb** | `give up`, `look after`, `put up with`, `take off` | key resolves to the *base* entry (`give`, `look`, `put`, `take`); the phrasal verb's senses are never read |
| **idiom** | `kick the bucket`, `bite the bullet`, `under the weather` | same — resolves to `kick`, `bite`, `weather` |

The reason is a namespace this module does not touch. A phrasal verb is written:

```
<span class="subEntry x_xo1"><span class="l x_xoh">give up </span>
  <span class="se2 x_xo2 hasSn"><span class="gp sn">1</span>
    <span class="msDict x_xo2sub"><span class="df">…</span>
```

`x_xo1` / `x_xo2` / `x_xo2sub` mirror `x_xd0` / `x_xd1` / `x_xd1sub`, and the indexer reads only `x_xd*`.
The `give` entry holds **76 definition elements and 58 sense numbers; the indexer emits 8 senses**, none
mentioning `give up`.

Measured over whole dictionaries:

| dictionary | definitions declared (`class="df"`) | senses read | reached | sub-entries |
|---|---|---|---|---|
| `NOAD` | 197,761 | 147,569 | **74.6%** | 68,856 |
| `ODE` | 205,427 | 155,146 | **75.5%** | 72,590 |

**A quarter of the two English dictionaries this project depends on is unread.** And the retention metric
did not show it: a sub-entry definition carries `class="df"` with **no `d:def` attribute**, so it was absent
from both sides of the ratio and retention reported a clean 100%.

One key is missing even at the index level: `raining cats and dogs` is not there — stored under another
form. Every other idiom tested was present as a key.

## 8. Method, stated once because it was earned five times

**Measure through the code that will ship, not through a side probe.** A side probe disagreed with the
real extraction path five times during this work and the path was right every time. The corollary:
a green gated test proves nothing when its bundles are absent, so the test prints what it measured and
the count is read, not assumed.

## 9. What licensing forbids

Dictionary text is licensed to the reader whose Mac it is on. **No bundle content is vendored into this
repository and no test fixture quotes it** — fixtures are invented markup. The measurements above ran
against locally installed bundles and only counts left them.
