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
