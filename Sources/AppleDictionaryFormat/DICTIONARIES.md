# The 86 dictionaries — format and data, measured

**Generated, not written.** Every number below came from `DictionarySurvey.measure` over the whole
macOS 27 dictionary catalogue, downloaded and read on this machine. Regenerate it rather than edit it;
a hand-edited row is a number nobody measured. See §9 for how.

> **Stale as of 2026-09-27: every sense and retention figure below predates `PLAN.md` steps 0–3 and has not
> been regenerated.** Those steps changed what the reader extracts and how retention is counted, so the
> numbers here understate the current reader by a wide margin — NOAD alone went from 147,569 definitions
> reached to 203,253, and its sense count from 147,569 to 180,840. Re-measured on the 9 Apple dictionaries
> this Mac has; the other 77 need a regeneration run against the full catalogue. Treat the *structure* of
> this document — which dictionary is which, which need what from an adapter — as current, and every
> **count** as historical until §9 has been run again.

**Scope:** 86 assets in the catalogue. **64** give senses *and* a verified key index, **20** give senses only, **2** cannot be read at all.

**The headline: these are not one format.** They share a container and diverge inside it — sense depth,
which attribute carries a publisher's sense id, whether a key pointer can be followed at all. A rebuild
that assumes one shape silently loses data from most of them, which is why the module measures each
dictionary rather than trusting a family name.

---

## 1. What a rebuild can use

| Verdict | Dictionaries | What it means |
|---|---|---|
| `full` | **64** | Senses read, and the key index resolves and agrees with itself. Phrase and inflection lookup available |
| `sensesOnly` | **20** | Senses read. Keys unusable or unverified, so lookup is by headword only |
| `unreadable` | **2** | No parseable entry. Nothing available |

The unreadable ones, and why:

- **`acc:TTY`** — **`Body.data` decompressed into 1 chunks but yielded no parseable entry** — readable container, unreadable content. keys: KeyText.data: no chunks at 68
- **`AppleDictionary`** — **`Body.data` could not be decompressed.** body: chunk did not decompress; keys: KeyText.data: no chunks at 68

Key-index confidence across the catalogue:

| Confidence | Dictionaries | Meaning |
|---|---|---|
| `verified` | 64 | agreement ≥80% — usable |
| `unverified` | 10 | agreement 50–80% — not certified, not impeached |
| `disagrees` | 10 | agreement <50% — something in the chain is wrong, and this cannot say which link |
| `not attempted` | 2 | no key groups parsed |

## 2. Identity and provenance

Identity comes from `CFBundleIdentifier`, never the filename: `Simplified Chinese - English.dictionary`
contains the Oxford Chinese Dictionary, and Apple re-points generic package names between releases.

| Identifier | Name | Type | Lang | Publisher | Download |
|---|---|---|---|---|---|
| `acc:TTY` | TTY Abbreviations | Monolingual |  | Apple Inc. All Rights Rese | 0 MB |
| `AppleDictionary` | Apple Dictionary | Monolingual |  | Apple Inc. All rights rese | 8 MB |
| `NOAD` | New Oxford American Dictionary | Monolingual | en | Oxford University Press | 36 MB |
| `OAWT` | Oxford American Writer’s Thesaurus | Thesaurus | en | Oxford University Press | 7 MB |
| `ODE` | Oxford Dictionary of English | Monolingual | en | Oxford University Press | 34 MB |
| `OTE` | Oxford Thesaurus of English | Thesaurus | en | Oxford University Press | 7 MB |
| `OxfordFrench` | Oxford-Hachette French Dictionary | Bilingual | fr | Oxford University Press | 24 MB |
| `OxfordGerman` | Oxford German Dictionary | Bilingual | de | Oxford University Press | 31 MB |
| `OxfordItalian` | Oxford Paravia Il Dizionario ingle | Bilingual | it | Oxford University Press | 30 MB |
| `OxfordRussian` | Oxford Russian Dictionary - Русско | Bilingual | ru | Oxford University Press | 17 MB |
| `OxfordSpanish` | Gran Diccionario Oxford - Español- | Bilingual | es | Oxford University Press | 26 MB |
| `ar-en.oup` | Oxford Arabic Dictionary - عربي-إن | Bilingual | ar | Oxford University Press | 10 MB |
| `as-en.oup` | Oxford Assamese Dictionaries - অসম | Bilingual | as | Oxford University Press | 55 MB |
| `bg.oup` | Тълковен речник на съвременния бъл | Monolingual | bg | Oxford University Press | 3 MB |
| `bn-en.oup` | Oxford Bengali Dictionaries - বাংল | Bilingual | bn | Oxford University Press | 11 MB |
| `ca-en.oup` | Diccionari Català-Anglès | Bilingual | ca | Oxford University Press | 11 MB |
| `ca.oup` | Larousse Editorial Diccionari Manu | Monolingual | ca | Oxford University Press | 7 MB |
| `cs-en.oup` | Velký anglicko-český a česko-angli | Bilingual | cs | Oxford University Press | 19 MB |
| `da-en.oup` | Praktisk Engelsk-Dansk Ordbog | Bilingual | da | Oxford University Press | 9 MB |
| `da.oup` | Politikens Nudansk Ordbog | Monolingual | da | Oxford University Press | 13 MB |
| `de.DDDSI` | Duden-Wissensnetz deutsche Sprache | Monolingual | de | Oxford University Press | 77 MB |
| `el-en.oup` | Stavropoulos Oxford Greek-English  | Bilingual | el | Oxford University Press | 13 MB |
| `el.oup` | Λεξικό της κοινής νεοελληνικής | Monolingual | el | Oxford University Press | 14 MB |
| `es.DGLEV` | Larousse Editorial Diccionario Gen | Monolingual | es | Oxford University Press | 19 MB |
| `fi-en.oup` | MOT sanakirja suomi-englanti, engl | Bilingual | fi | Oxford University Press | 31 MB |
| `fr-de.oup` | PONS Großwörterbuch Französisch De | Bilingual |  | Oxford University Press | 23 MB |
| `fr.Multi` | Multidictionnaire de la langue fra | Monolingual | fr | Oxford University Press | 9 MB |
| `gu-en.oup` | Oxford Gujarati Dictionaries - ગુજ | Bilingual | gu | Oxford University Press | 10 MB |
| `he-en.oup` | Oxford Hebrew Dictionary | מילון ע | Bilingual | he | Oxford University Press | 10 MB |
| `he.oup` | מילון אבן-שושן מחודש ומותאם לשנות  | Monolingual | he | Oxford University Press | 20 MB |
| `hi-en.oup` | Oxford Hindi Dictionaries - हिन्दी | Bilingual | hi | Oxford University Press | 15 MB |
| `hi.oup` | राजपाल हिन्दी शब्दकोश | Monolingual | hi | Oxford University Press | 7 MB |
| `hr-en.oup` | Praktický Anglicko-Chorvatský Slov | Bilingual | hr | Oxford University Press | 12 MB |
| `hr.oup` | Hrvatski Enciklopedijski Rječnik | Monolingual | hr | Oxford University Press | 23 MB |
| `hu-en.oup` | Magay Tamás szótár - Magyar-Angol  | Bilingual | hu | Oxford University Press | 49 MB |
| `hu.oup` | Magyar értelmező szótár továbbfejl | Monolingual | hu | Oxford University Press | 62 MB |
| `id-en.oup` | Oxford Study Indonesian Dictionary | Bilingual | id | Oxford University Press | 3 MB |
| `it.Devoto-Oli` | Dizionario italiano da un affiliat | Monolingual | it | Oxford University Press | 26 MB |
| `ja-en.WISDOM` | ウィズダム英和辞典 / ウィズダム和英辞典 | Bilingual | ja | Oxford University Press | 40 MB |
| `ja.Daijirin` | スーパー大辞林 | Monolingual | ja | Oxford University Press | 76 MB |
| `kk-en.oup` | Оксфорд Қазақ Cөздігі | Bilingual | kk | Oxford University Press | 21 MB |
| `kn-en.oup` | Oxford Kannada Dictionaries - ಇಂಗ್ | Bilingual | kn | Oxford University Press | 9 MB |
| `ko-en.NewAce` | 뉴에이스 영한사전 / 뉴에이스 한영사전 | Bilingual | ko | Oxford University Press | 53 MB |
| `ko.NewAce` | 뉴에이스 국어사전 | Monolingual | ko | Oxford University Press | 83 MB |
| `ml-en.oup` | Oxford Malayalam Dictionaries - മല | Bilingual | ml | Oxford University Press | 8 MB |
| `mr-en.oup` | Oxford Marathi Dictionaries - इंग् | Bilingual | mr | Oxford University Press | 14 MB |
| `ms-en.oup` | Kamus Dwibahasa Melayu/Inggeris -  | Bilingual | ms | Oxford University Press | 5 MB |
| `ms.oup` | Kamus Komprehensif Bahasa Melayu - | Monolingual | ms | Oxford University Press | 4 MB |
| `ne-en.oup` | Oxford Nepali Dictionaries - अङ्ग् | Bilingual | ne | Oxford University Press | 37 MB |
| `nl-en.oup` | Prisma Handwoordenboek Engels | Bilingual | nl | Oxford University Press | 13 MB |
| `nl.Prisma` | Prisma woordenboek Nederlands | Monolingual | nl | Oxford University Press | 13 MB |
| `no-en.oup` | Engelsk Ordbok | Bilingual | no | Oxford University Press | 19 MB |
| `no.oup` | Norsk Ordbok | Monolingual | no | Oxford University Press | 11 MB |
| `or-en.oup` | Oxford Odia Dictionaries - ଇଂରାଜୀ- | Bilingual | or | Oxford University Press | 30 MB |
| `pa-en.oup` | Oxford Punjabi Dictionaries - ਪੰਜਾ | Bilingual | pa | Oxford University Press | 12 MB |
| `pl-en.oup` | Oxford PWN Polish-English Dictiona | Bilingual | pl | Oxford University Press | 22 MB |
| `pl.oup` | Uniwersalny słownik języka polskie | Monolingual | pl | Oxford University Press | 28 MB |
| `pt-en.oup` | Oxford Portuguese Dictionary - Por | Bilingual | pt | Oxford University Press | 16 MB |
| `pt.oup` | Dicionário de Português licenciado | Monolingual | pt | Oxford University Press | 29 MB |
| `ro.oup` | Dicţionarul explicativ al limbii r | Monolingual | ro | Oxford University Press | 12 MB |
| `ru.oup` | Толковый словарь русского языка | Monolingual | ru | Oxford University Press | 12 MB |
| `sa-en.oup` | Oxford Sanskrit Dictionaries - आङ् | Bilingual | sa | Oxford University Press | 12 MB |
| `sk-en.oup` | Veľký Anglicko-Slovenský Slovník | Bilingual | sk | Oxford University Press | 24 MB |
| `sv-en.oup` | NE Nationalencyklopedin AB Profess | Bilingual | sv | Oxford University Press | 24 MB |
| `sv.oup` | NE Ordbok | Monolingual | sv | Oxford University Press | 14 MB |
| `ta-en.oup` | Oxford Tamil Dictionaries - தமிழ்- | Bilingual | ta | Oxford University Press | 10 MB |
| `te-en.oup` | Oxford Telugu Dictionaries - తెలుగ | Bilingual | te | Oxford University Press | 9 MB |
| `th-en.oup` | พจนานุกรมอังกฤษ-ไทย & ไทย-อังกฤษ ฉ | Bilingual | th | Oxford University Press | 8 MB |
| `th.oup` | พจนานุกรมไทย ฉบับทันสมัยและสมบูรณ์ | Monolingual | th | Oxford University Press | 5 MB |
| `tr-en.oup` | Oxford Turkish Dictionary - Türkçe | Bilingual | tr | Oxford University Press | 7 MB |
| `tr.oup` | Arkadaş Türkçe Sözlük | Monolingual | tr | Oxford University Press | 15 MB |
| `uk-en.oup` | Українсько-Англійський Словник | Bilingual | uk | Oxford University Press | 9 MB |
| `ur-en.oup` | Oxford Urdu Dictionaries - اردو۔ان | Bilingual | ur | Oxford University Press | 23 MB |
| `vi-en.oup` | Từ điển Lạc Việt | Bilingual | vi | Oxford University Press | 41 MB |
| `vi.oup` | Từ Điển Tiếng Việt | Monolingual | vi | Oxford University Press | 7 MB |
| `yue-en.cp` | 英譯廣東口語詞典 | Bilingual | yue-Hant | Oxford University Press | 1 MB |
| `yue-en.oup` | 牛津粵英雙語詞典 | Bilingual | yue-Hant | Oxford University Press | 10 MB |
| `zh_CN-en.OCD` | 牛津英汉汉英词典 | Bilingual | zh-Hans | Oxford University Press | 32 MB |
| `zh_CN.SDCC` | 现代汉语规范词典 | Monolingual | zh-Hans | Oxford University Press | 16 MB |
| `zh_CN.idioms` | 汉语成语词典 | Thesaurus | zh-Hans | Oxford University Press | 4 MB |
| `zh_CN.thes` | 现代汉语同义词典 | Thesaurus | zh-Hans | Oxford University Press | 1 MB |
| `zh_HK-en.idioms.cp` | 漢英對照成語詞典 | Bilingual | zh-Hant-HK | Oxford University Press | 2 MB |
| `zh_HK.common` | 商務新詞典（全新版） | Thesaurus | zh-Hant-HK | Oxford University Press | 6 MB |
| `zh_TW-en.DrEye` | 譯典通英漢雙向字典 | Bilingual | zh-Hant | Oxford University Press | 23 MB |
| `zh_TW.wn` | 五南國語活用辭典 | Monolingual | zh-Hant | Oxford University Press | 24 MB |
| `zhs-ja.Crown` | 超級クラウン中日辞典 / クラウン日中辞典 | Bilingual |  | Oxford University Press | 30 MB |

## 3. Container and senses

`retention` is the share of the `d:def` elements the markup declares that survive into a sense at the
declared depth. Above 100% means one sense joins several definitions, which is correct — a sense block's
glosses belong to the sense holding them. Below 100% means definitions are being lost.

| Identifier | Chunks | Entries | Senses | Depth | id attr | with id | retention |
|---|---|---|---|---|---|---|---|
| `acc:TTY` | 1 | 0 | 0 | 1 | none | — | 0.0% |
| `AppleDictionary` | — | 0 | 0 | 1 | none | — | 0.0% |
| `NOAD` | 799 | 111,579 | 147,569 | 1 | id | 100.0% | 100.0% |
| `OAWT` | 179 | 16,007 | 35,016 | 1 | id | 29.4% | 100.0% |
| `ODE` | 763 | 116,059 | 155,146 | 1 | id | 100.0% | 100.0% |
| `OTE` | 180 | 16,010 | 35,018 | 1 | id | 29.4% | 100.0% |
| `OxfordFrench` | 521 | 103,891 | 174,908 | 1 | both | 100.0% | 100.0% |
| `OxfordGerman` | 527 | 138,050 | 201,239 | 1 | both | 100.0% | 100.0% |
| `OxfordItalian` | 646 | 142,115 | 222,141 | 1 | both | 100.0% | 100.0% |
| `OxfordRussian` | 339 | 90,848 | 120,561 | 1 | both | 100.0% | 100.0% |
| `OxfordSpanish` | 527 | 116,001 | 167,457 | 1 | id | 100.0% | 100.0% |
| `ar-en.oup` | 245 | 54,645 | 83,381 | 1 | both | 100.0% | 100.0% |
| `as-en.oup` | 329 | 87,218 | 105,569 | 2 | id | 100.0% | 100.0% |
| `bg.oup` | 85 | 16,717 | 30,521 | 1 | lexid | 100.0% | 100.0% |
| `bn-en.oup` | 248 | 51,416 | 64,698 | 1 | id | 22.6% | 100.0% |
| `ca-en.oup` | 172 | 72,281 | 98,483 | 1 | lexid | 100.0% | 99.8% |
| `ca.oup` | 100 | 26,789 | 44,710 | 1 | none | 0.0% | 100.0% |
| `cs-en.oup` | 441 | 120,975 | 182,370 | 1 | lexid | 100.0% | 98.4% |
| `da-en.oup` | 133 | 70,671 | 88,045 | 1 | lexid | 100.0% | 100.0% |
| `da.oup` | 236 | 45,130 | 46,674 | 1 | none | 0.0% | 100.0% |
| `de.DDDSI` | 1,670 | 145,794 | 138,475 | 1 | none | 0.0% | 64.9% |
| `el-en.oup` | 306 | 55,987 | 77,418 | 1 | lexid | 100.0% | 99.3% |
| `el.oup` | 366 | 50,033 | 66,441 | 3 | lexid | 100.0% | 100.0% |
| `es.DGLEV` | 357 | 61,655 | 112,013 | 1 | lexid | 48.2% | 100.0% |
| `fi-en.oup` | 690 | 265,914 | 339,616 | 1 | lexid | 100.0% | 99.1% |
| `fr-de.oup` | 379 | 130,807 | 181,648 | 1 | none | 0.0% | 98.8% |
| `fr.Multi` | 138 | 32,058 | 47,365 | 1 | none | 0.0% | 99.4% |
| `gu-en.oup` | 201 | 112,135 | 158,005 | 1 | lexid | 100.0% | 100.0% |
| `he-en.oup` | 94 | 39,604 | 49,412 | 1 | lexid | 100.0% | 100.0% |
| `he.oup` | 409 | 39,626 | 50,382 | 1 | none | 0.0% | 76.5% |
| `hi-en.oup` | 271 | 50,931 | 81,197 | 1 | id | 84.8% | 88.2% |
| `hi.oup` | 141 | 45,846 | 82,792 | 1 | id | 0.0% | 100.0% |
| `hr-en.oup` | 137 | 65,662 | 80,726 | 1 | lexid | 100.0% | 100.0% |
| `hr.oup` | 406 | 106,993 | 137,333 | 1 | lexid | 100.0% | 100.0% |
| `hu-en.oup` | 348 | 121,096 | 166,436 | 1 | lexid | 98.8% | 98.5% |
| `hu.oup` | 274 | 74,945 | 119,329 | 1 | lexid | 100.0% | 98.9% |
| `id-en.oup` | 61 | 11,164 | 15,524 | 1 | id | 100.0% | 100.0% |
| `it.Devoto-Oli` | 553 | 74,680 | 116,957 | 1 | none | 0.0% | 69.1% |
| `ja-en.WISDOM` | 770 | 90,548 | 133,663 | 1 | id | 68.5% | 96.7% |
| `ja.Daijirin` | 1,100 | 265,055 | 334,237 | 1 | none | 0.0% | 100.0% |
| `kk-en.oup` | 238 | 58,324 | 83,726 | 1 | lexid | 100.0% | 99.7% |
| `kn-en.oup` | 212 | 41,550 | 59,404 | 2 | id | 46.3% | 100.0% |
| `ko-en.NewAce` | 1,207 | 317,804 | 398,122 | 1 | id | 0.0% | 100.0% |
| `ko.NewAce` | 1,980 | 331,237 | 332,260 | 1 | id | 0.0% | 90.1% |
| `ml-en.oup` | 204 | 42,315 | 60,567 | 2 | id | 46.0% | 100.0% |
| `mr-en.oup` | 238 | 46,862 | 66,468 | 1 | lexid | 54.1% | 100.0% |
| `ms-en.oup` | 85 | 35,093 | 38,566 | 1 | lexid | 100.0% | 99.8% |
| `ms.oup` | 79 | 14,649 | 16,910 | 1 | lexid | 100.0% | 100.0% |
| `ne-en.oup` | 530 | 155,626 | 232,982 | 1 | lexid | 100.0% | 98.9% |
| `nl-en.oup` | 224 | 98,216 | 145,609 | 1 | none | 0.0% | 99.3% |
| `nl.Prisma` | 217 | 70,820 | 95,441 | 1 | none | 0.0% | 99.2% |
| `no-en.oup` | 262 | 92,690 | 137,760 | 1 | lexid | 100.0% | 100.0% |
| `no.oup` | 204 | 65,369 | 67,824 | 1 | id | 99.5% | 96.1% |
| `or-en.oup` | 270 | 82,478 | 124,451 | 1 | both | 66.5% | 85.4% |
| `pa-en.oup` | 241 | 55,406 | 76,859 | 1 | both | 87.6% | 77.9% |
| `pl-en.oup` | 519 | 115,553 | 182,284 | 1 | id | 47.7% | 100.0% |
| `pl.oup` | 502 | 92,778 | 117,796 | 1 | id | 100.0% | 100.0% |
| `pt-en.oup` | 400 | 73,035 | 151,601 | 1 | both | 100.0% | 100.0% |
| `pt.oup` | 674 | 126,150 | 240,981 | 1 | none | 0.0% | 100.0% |
| `ro.oup` | 250 | 6,286 | 8,498 | 1 | none | 0.0% | 10.2% |
| `ru.oup` | 177 | 41,027 | 51,630 | 1 | id | 100.0% | 99.0% |
| `sa-en.oup` | 163 | 44,897 | 49,001 | 1 | lexid | 81.6% | 100.0% |
| `sk-en.oup` | 357 | 103,930 | 160,797 | 1 | lexid | 100.0% | 99.1% |
| `sv-en.oup` | 467 | 180,042 | 216,768 | 1 | lexid | 100.0% | 97.5% |
| `sv.oup` | 313 | 61,746 | 67,984 | 1 | none | 0.0% | 99.1% |
| `ta-en.oup` | 261 | 35,739 | 46,688 | 1 | id | 0.3% | 81.9% |
| `te-en.oup` | 171 | 36,569 | 50,937 | 1 | id | 77.0% | 100.0% |
| `th-en.oup` | 164 | 49,219 | 59,813 | 1 | id | 100.0% | 100.0% |
| `th.oup` | 109 | 38,243 | 51,983 | 1 | none | 0.0% | 100.0% |
| `tr-en.oup` | 65 | 36,990 | 47,855 | 1 | lexid | 100.0% | 100.0% |
| `tr.oup` | 192 | 49,207 | 69,110 | 1 | id | 0.8% | 71.7% |
| `uk-en.oup` | 124 | 50,904 | 64,207 | 1 | lexid | 100.0% | 100.0% |
| `ur-en.oup` | 525 | 52,622 | 110,586 | 1 | id | 51.4% | 68.0% |
| `vi-en.oup` | 889 | 280,474 | 478,840 | 1 | lexid | 100.0% | 99.5% |
| `vi.oup` | 164 | 43,751 | 54,804 | 2 | lexid | 100.0% | 100.0% |
| `yue-en.cp` | 12 | 2,472 | 2,472 | 1 | none | 0.0% | 30.8% |
| `yue-en.oup` | 247 | 36,866 | 47,537 | 1 | both | 40.4% | 100.0% |
| `zh_CN-en.OCD` | 589 | 136,288 | 197,386 | 1 | both | 100.0% | 100.0% |
| `zh_CN.SDCC` | 256 | 73,890 | 96,512 | 1 | none | 0.0% | 100.0% |
| `zh_CN.idioms` | 85 | 9,924 | 17,482 | 1 | none | 0.0% | 84.8% |
| `zh_CN.thes` | 19 | 2,113 | 4,228 | 1 | none | 0.0% | 46.0% |
| `zh_HK-en.idioms.cp` | 21 | 4,086 | 4,086 | 1 | none | 0.0% | 23.1% |
| `zh_HK.common` | 89 | 30,804 | 48,870 | 1 | none | 0.0% | 100.0% |
| `zh_TW-en.DrEye` | 430 | 92,850 | 159,047 | 1 | none | 0.0% | 92.9% |
| `zh_TW.wn` | 447 | 60,152 | 97,441 | 1 | none | 0.0% | 100.0% |
| `zhs-ja.Crown` | 452 | 101,994 | 126,938 | 1 | none | 0.0% | 100.0% |

## 4. Keys, and whether their pointers can be followed

`resolved` means a key's pointer landed on a real entry record. `agreement` is whether that entry's
headword **shares an opening** with the key once pronunciation is stripped — not whether it contains it.
Containment fails for every suffix-inflected form and for every dictionary that writes pronunciation
inside the word: it scored Russian 7.9% and Traditional Chinese 6.9% while both resolved correctly.
**`resolved` and `agreement` are different measurements and conflating them is the trap** — but so is
reading a low agreement as a broken mapping, which is what an earlier oracle here did.

| Identifier | Groups | Key strings | Phrases | ids/chunks | offset alone | resolved | agreement | verdict |
|---|---|---|---|---|---|---|---|---|
| `acc:TTY` | 0 | 0 | — | — | — | — | — | not attempted |
| `AppleDictionary` | 0 | 0 | — | — | — | — | — | not attempted |
| `NOAD` | 252,428 | 396,529 | 39.0% | 774/799 | 68.3% | 99.1% | 92.9% | `verified` |
| `OAWT` | 30,676 | 45,726 | 6.6% | 165/179 | 95.3% | 100.0% | 99.0% | `verified` |
| `ODE` | 262,913 | 412,367 | 40.6% | 748/763 | 66.9% | 99.9% | 94.1% | `verified` |
| `OTE` | 30,974 | 46,257 | 7.2% | 165/180 | 94.9% | 100.0% | 99.0% | `verified` |
| `OxfordFrench` | 302,664 | 573,278 | 6.7% | 217/521 | 75.3% | 100.0% | 97.8% | `verified` |
| `OxfordGerman` | 833,680 | 1,646,246 | 0.8% | 252/527 | 69.7% | 100.0% | 99.3% | `verified` |
| `OxfordItalian` | 368,036 | 668,085 | 3.9% | 252/646 | 69.0% | 100.0% | 99.2% | `verified` |
| `OxfordRussian` | 258,153 | 466,686 | 0.4% | 143/339 | 79.4% | 100.0% | 98.1% | `verified` |
| `OxfordSpanish` | 419,373 | 788,103 | 4.1% | 216/527 | 73.9% | 100.0% | 99.5% | `verified` |
| `ar-en.oup` | 50,753 | 78,344 | 0.4% | 102/245 | 87.0% | 100.0% | 98.4% | `verified` |
| `as-en.oup` | 4,031,924 | 7,985,093 | 11.3% | 217/329 | 80.0% | 100.0% | 99.8% | `verified` |
| `bg.oup` | 15,115 | 15,590 | 8.6% | 71/85 | 95.1% | 100.0% | 92.2% | `verified` |
| `bn-en.oup` | 86,131 | 133,565 | 31.0% | 102/248 | 88.2% | 100.0% | 90.5% | `verified` |
| `ca-en.oup` | 325,532 | 614,378 | 3.7% | 76/172 | 85.4% | 100.0% | 99.6% | `verified` |
| `ca.oup` | 133,546 | 177,675 | 2.0% | 87/100 | 91.4% | 100.0% | 94.8% | `verified` |
| `cs-en.oup` | 103,822 | 150,544 | 3.4% | 233/441 | 73.4% | 100.0% | 97.6% | `verified` |
| `da-en.oup` | 165,822 | 266,739 | 0.7% | 65/133 | 86.5% | 100.0% | 97.1% | `verified` |
| `da.oup` | 189,090 | 300,385 | 0.9% | 220/236 | 86.6% | 100.0% | 91.8% | `verified` |
| `de.DDDSI` | 1,407,825 | 2,754,885 | 3.6% | 1641/1670 | 70.2% | 71.1% | 8.1% | `disagrees` |
| `el-en.oup` | 78,775 | 121,594 | 0.7% | 178/306 | 82.7% | 100.0% | 99.0% | `verified` |
| `el.oup` | 99,936 | 153,513 | 3.4% | 345/366 | 83.8% | 100.0% | 93.0% | `verified` |
| `es.DGLEV` | 483,852 | 858,296 | 2.2% | 338/357 | 80.3% | 100.0% | 98.0% | `verified` |
| `fi-en.oup` | 184,476 | 229,992 | 15.1% | 399/690 | 50.5% | 99.7% | 99.3% | `verified` |
| `fr-de.oup` | 278,514 | 472,418 | 0.6% | 187/379 | 73.6% | 100.0% | 94.4% | `verified` |
| `fr.Multi` | 196,879 | 295,413 | 4.7% | 124/138 | 90.5% | 100.0% | 87.9% | `verified` |
| `gu-en.oup` | 47,296 | 47,356 | 10.8% | 75/201 | 78.6% | 100.0% | 100.0% | `verified` |
| `he-en.oup` | 366,123 | 512,229 | 1.1% | 40/94 | 91.5% | 100.0% | 55.1% | `unverified` |
| `he.oup` | 228,060 | 444,743 | 16.1% | 395/409 | 84.4% | 96.9% | 5.0% | `disagrees` |
| `hi-en.oup` | 224,549 | 430,071 | 27.6% | 116/271 | 85.7% | 100.0% | 95.4% | `verified` |
| `hi.oup` | 90,799 | 124,694 | 15.8% | 130/141 | 90.1% | 100.0% | 74.2% | `unverified` |
| `hr-en.oup` | 444,635 | 760,587 | 4.0% | 64/137 | 87.7% | 100.0% | 92.4% | `verified` |
| `hr.oup` | 512,764 | 880,254 | 8.4% | 392/406 | 77.0% | 100.0% | 93.0% | `verified` |
| `hu-en.oup` | 2,962,630 | 5,871,852 | 0.6% | 155/348 | 73.7% | 100.0% | 99.7% | `verified` |
| `hu.oup` | 3,573,023 | 6,416,446 | 1.2% | 258/274 | 80.4% | 100.0% | 94.2% | `verified` |
| `id-en.oup` | 7,677 | 7,717 | 1.6% | 36/61 | 94.2% | 100.0% | 63.1% | `unverified` |
| `it.Devoto-Oli` | 526,269 | 944,102 | 0.6% | 536/553 | 74.2% | 88.3% | 43.7% | `disagrees` |
| `ja-en.WISDOM` | 783,105 | 1,507,960 | 0.0% | 325/770 | 72.2% | 95.5% | 4.4% | `disagrees` |
| `ja.Daijirin` | 2,270,212 | 4,657,642 | 1.0% | 1082/1100 | 43.0% | 98.1% | 9.4% | `disagrees` |
| `kk-en.oup` | 998,093 | 1,970,124 | 1.2% | 93/238 | 86.2% | 100.0% | 99.7% | `verified` |
| `kn-en.oup` | 19,598 | 19,647 | 6.5% | 63/212 | 88.5% | 100.0% | 99.8% | `verified` |
| `ko-en.NewAce` | 166,859 | 272,084 | 31.6% | 387/1207 | 36.4% | 100.0% | 73.5% | `unverified` |
| `ko.NewAce` | 536,455 | 1,010,636 | 23.0% | 1791/1980 | 31.7% | 98.6% | 59.5% | `unverified` |
| `ml-en.oup` | 20,078 | 20,185 | 2.9% | 63/204 | 88.8% | 100.0% | 98.3% | `verified` |
| `mr-en.oup` | 425,248 | 820,830 | 0.5% | 73/238 | 87.6% | 100.0% | 99.4% | `verified` |
| `ms-en.oup` | 16,523 | 16,685 | 13.3% | 33/85 | 92.6% | 100.0% | 71.9% | `unverified` |
| `ms.oup` | 17,676 | 17,733 | 15.9% | 66/79 | 94.9% | 100.0% | 57.6% | `unverified` |
| `ne-en.oup` | 1,226,768 | 2,379,028 | 1.4% | 157/530 | 68.3% | 100.0% | 99.5% | `verified` |
| `nl-en.oup` | 173,068 | 286,394 | 6.3% | 101/224 | 81.0% | 100.0% | 89.3% | `verified` |
| `nl.Prisma` | 203,437 | 301,834 | 9.8% | 204/217 | 82.5% | 100.0% | 86.8% | `verified` |
| `no-en.oup` | 347,531 | 639,849 | 9.8% | 122/262 | 80.9% | 100.0% | 94.4% | `verified` |
| `no.oup` | 177,940 | 277,646 | 2.8% | 190/204 | 81.2% | 97.4% | 45.6% | `disagrees` |
| `or-en.oup` | 1,638,337 | 3,192,387 | 1.0% | 133/270 | 82.9% | 100.0% | 98.4% | `verified` |
| `pa-en.oup` | 98,607 | 139,217 | 42.8% | 101/241 | 87.4% | 100.0% | 56.3% | `unverified` |
| `pl-en.oup` | 114,112 | 183,499 | 20.0% | 263/519 | 69.6% | 100.0% | 94.6% | `verified` |
| `pl.oup` | 530,530 | 987,848 | 28.2% | 487/502 | 72.7% | 100.0% | 92.4% | `verified` |
| `pt-en.oup` | 46,835 | 62,175 | 27.2% | 145/400 | 81.5% | 100.0% | 90.4% | `verified` |
| `pt.oup` | 307,863 | 507,265 | 21.2% | 656/674 | 70.6% | 99.7% | 91.0% | `verified` |
| `ro.oup` | 175,828 | 280,846 | 11.3% | 236/250 | 82.5% | 9.3% | 0.7% | `disagrees` |
| `ru.oup` | 253,373 | 406,035 | 1.1% | 163/177 | 89.5% | 100.0% | 93.6% | `verified` |
| `sa-en.oup` | 414,657 | 779,351 | 0.0% | 40/163 | 91.5% | 100.0% | 93.7% | `verified` |
| `sk-en.oup` | 758,140 | 1,410,420 | 0.7% | 190/357 | 77.5% | 100.0% | 92.7% | `verified` |
| `sv-en.oup` | 285,872 | 492,136 | 2.4% | 204/467 | 64.5% | 100.0% | 95.9% | `verified` |
| `sv.oup` | 198,024 | 323,424 | 3.1% | 298/313 | 84.0% | 99.6% | 8.8% | `disagrees` |
| `ta-en.oup` | 22,720 | 26,140 | 13.9% | 109/261 | 86.5% | 100.0% | 99.8% | `verified` |
| `te-en.oup` | 115,381 | 186,583 | 5.8% | 120/171 | 86.5% | 100.0% | 81.2% | `verified` |
| `th-en.oup` | 38,349 | 55,711 | 1.2% | 36/164 | 88.2% | 100.0% | 94.3% | `verified` |
| `th.oup` | 40,146 | 45,948 | 2.6% | 98/109 | 90.9% | 100.0% | 87.8% | `verified` |
| `tr-en.oup` | 171,629 | 199,337 | 2.5% | 33/65 | 92.9% | 100.0% | 85.7% | `verified` |
| `tr.oup` | 428,489 | 733,588 | 5.8% | 180/192 | 84.0% | 65.1% | 15.7% | `disagrees` |
| `uk-en.oup` | 282,423 | 452,490 | 1.3% | 61/124 | 88.9% | 100.0% | 93.9% | `verified` |
| `ur-en.oup` | 105,947 | 160,481 | 45.5% | 256/525 | 77.0% | 100.0% | 75.1% | `unverified` |
| `vi-en.oup` | 179,562 | 292,343 | 96.7% | 192/889 | 48.0% | 100.0% | 97.6% | `verified` |
| `vi.oup` | 65,308 | 88,033 | 89.6% | 150/164 | 88.5% | 100.0% | 86.1% | `verified` |
| `yue-en.cp` | 7 | 7 | 0.0% | 3/12 | 99.0% | 100.0% | 100.0% | `verified` |
| `yue-en.oup` | 33,744 | 48,565 | 37.2% | 130/247 | 89.2% | 100.0% | 86.7% | `verified` |
| `zh_CN-en.OCD` | 311,243 | 547,444 | 3.6% | 227/589 | 69.8% | 100.0% | 100.0% | `verified` |
| `zh_CN.SDCC` | 216,793 | 358,429 | 0.1% | 248/256 | 80.8% | 100.0% | 95.2% | `verified` |
| `zh_CN.idioms` | 16,648 | 19,441 | 0.0% | 65/85 | 93.5% | 100.0% | 62.1% | `unverified` |
| `zh_CN.thes` | 772 | 772 | 0.0% | 10/19 | 98.5% | 100.0% | 98.1% | `verified` |
| `zh_HK-en.idioms.cp` | 160 | 160 | 0.0% | 8/21 | 98.3% | 100.0% | 100.0% | `verified` |
| `zh_HK.common` | 65,197 | 94,140 | 0.0% | 81/89 | 92.1% | 100.0% | 85.2% | `verified` |
| `zh_TW-en.DrEye` | 213,018 | 395,333 | 35.7% | 110/430 | 80.4% | 100.0% | 100.0% | `verified` |
| `zh_TW.wn` | 209,945 | 356,620 | 0.0% | 435/447 | 79.6% | 99.8% | 96.5% | `verified` |
| `zhs-ja.Crown` | 623,545 | 1,215,924 | 0.0% | 216/452 | 75.2% | 99.2% | 4.2% | `disagrees` |

## 5. Where they diverge, axis by axis

Each axis below is something a reader of one dictionary would never discover. Together they are the
argument for per-dictionary adapters rather than one code path with flags.

### 5.1 Sense depth

**79 of 84 readable dictionaries delimit a sense at `x_xd1`; 5 nest deeper.**
Depth cannot be guessed from the family name — these are all Oxford-published and they disagree.

| Dictionary | Depth | retention at that depth |
|---|---|---|
| `as-en.oup` | 2 | 100.0% |
| `el.oup` | 3 | 100.0% |
| `kn-en.oup` | 2 | 100.0% |
| `ml-en.oup` | 2 | 100.0% |
| `vi.oup` | 2 | 100.0% |

### 5.2 Definitions still lost at the declared depth

**16 dictionaries lose definitions even at their best depth.** No depth recovers these; the
loss is markup the entry reader does not reach, which is a reader defect and not a depth choice.

| Dictionary | retention | definitions lost |
|---|---|---|
| `ro.oup` | 10.2% | 89.8% |
| `zh_HK-en.idioms.cp` | 23.1% | 76.9% |
| `yue-en.cp` | 30.8% | 69.2% |
| `zh_CN.thes` | 46.0% | 54.0% |
| `de.DDDSI` | 64.9% | 35.1% |
| `ur-en.oup` | 68.0% | 32.0% |
| `it.Devoto-Oli` | 69.1% | 30.9% |
| `tr.oup` | 71.7% | 28.3% |
| `he.oup` | 76.5% | 23.5% |
| `pa-en.oup` | 77.9% | 22.1% |
| `ta-en.oup` | 81.9% | 18.1% |
| `zh_CN.idioms` | 84.8% | 15.2% |
| `or-en.oup` | 85.4% | 14.6% |
| `hi-en.oup` | 88.2% | 11.8% |
| `ko.NewAce` | 90.1% | 9.9% |
| `zh_TW-en.DrEye` | 92.9% | 7.1% |

### 5.3 Which attribute carries the publisher's sense id

**Measured by indexing every dictionary twice, once with each attribute pinned** — not by looking for the
string in the markup, because `lexid=` appears on elements that are not senses and a substring count
overstates it. Guessing this wrong loses every id in the dictionaries using the other attribute: pinning
the default to `id` silently dropped 28 dictionaries out of a validation set.

| Carries ids under | Dictionaries |
|---|---|
| `lexid` only | 27 |
| `id` only | 24 |
| both | 10 |
| neither — content keys required | 23 |

**23 of 84 readable dictionaries emit no publisher id at all**, so their senses
can only be named by hashing their own text. That is a real name, not a missing one, and it is the reason
`SenseKey` has a content-addressed form.

The default therefore accepts **either** attribute rather than naming one. Only an adapter that has
measured its dictionaries pins it, and pinning it to the wrong one is silent.

### 5.4 Headwords that are not headwords

**42 of 84 readable dictionaries put a pronunciation inside the headword element**,
delimited by `|`, so the reader gets `roo | ro͞oru |` where it wanted `roo`. A rebuild storing that stores
something no reader will ever type. Splitting it needs per-dictionary knowledge: the delimiters and the
script differ, and a Korean entry carries `《약》` where an English one carries a stress mark.

| Dictionary | entries | with a pronunciation in the headword |
|---|---|---|
| `vi.oup` | 43,751 | 100.0% |
| `yue-en.cp` | 2,472 | 100.0% |
| `zh_HK-en.idioms.cp` | 4,086 | 100.0% |
| `zh_TW.wn` | 60,152 | 100.0% |
| `or-en.oup` | 82,478 | 100.0% |
| `hr.oup` | 106,993 | 100.0% |
| `as-en.oup` | 87,218 | 100.0% |
| `mr-en.oup` | 46,862 | 99.8% |
| `hu.oup` | 74,945 | 99.5% |
| `pa-en.oup` | 55,406 | 99.4% |
| `te-en.oup` | 36,569 | 99.3% |
| `kk-en.oup` | 58,324 | 99.3% |
| … | | and 30 more |

### 5.5 Dictionaries that do not mark a part of speech

**5 dictionaries label a part of speech on fewer than 10% of their senses.** Anything that
narrows candidates by part of speech narrows to nothing in these, so the narrowing has to be optional
rather than assumed — a selector scored against a dictionary that cannot answer is measuring itself.

`yue-en.cp`, `zh_CN.idioms`, `zh_CN.thes`, `zh_HK-en.idioms.cp`, `zh_HK.common`

### 5.6 Inline `d:index` — keys without the key file

**None.** Every dictionary in the catalogue has had its `d:index` elements stripped at build time, so
the keys exist only in `KeyText.data` and the pointer arithmetic in §4 is the only way to them.

### 5.7 Key pointers that cannot be followed

**10 disagree, 10 unverified.** Agreement measures a *chain*: the key mapping, the
headword extraction, and whether the oracle can see that language at all. A low score localises to one of
the three and cannot say which — `he.oup` and `ro.oup` yield `Tranz.` and `(Pop. şi fam.)` as headwords,
which is this module's own `x_xh0` defect and nothing to do with keys. So these are **uncertified, not
impeached**, and the module withholds them rather than claiming they are broken.

| Disagrees | resolved | agreement | ids/chunks |
|---|---|---|---|
| `de.DDDSI` | 71.1% | 8.1% | 1641/1670 |
| `he.oup` | 96.9% | 5.0% | 395/409 |
| `it.Devoto-Oli` | 88.3% | 43.7% | 536/553 |
| `ja-en.WISDOM` | 95.5% | 4.4% | 325/770 |
| `ja.Daijirin` | 98.1% | 9.4% | 1082/1100 |
| `no.oup` | 97.4% | 45.6% | 190/204 |
| `ro.oup` | 9.3% | 0.7% | 236/250 |
| `sv.oup` | 99.6% | 8.8% | 298/313 |
| `tr.oup` | 65.1% | 15.7% | 180/192 |
| `zhs-ja.Crown` | 99.2% | 4.2% | 216/452 |

| Unverified | resolved | agreement | ids/chunks |
|---|---|---|---|
| `he-en.oup` | 100.0% | 55.1% | 40/94 |
| `hi.oup` | 100.0% | 74.2% | 130/141 |
| `id-en.oup` | 100.0% | 63.1% | 36/61 |
| `ko-en.NewAce` | 100.0% | 73.5% | 387/1207 |
| `ko.NewAce` | 98.6% | 59.5% | 1791/1980 |
| `ms-en.oup` | 100.0% | 71.9% | 33/85 |
| `ms.oup` | 100.0% | 57.6% | 66/79 |
| `pa-en.oup` | 100.0% | 56.3% | 101/241 |
| `ur-en.oup` | 100.0% | 75.1% | 256/525 |
| `zh_CN.idioms` | 100.0% | 62.1% | 65/85 |

## 6. What each dictionary needs that the default cannot give

**A mark is work, not a difference.** The id attribute is deliberately *not* a column here: the default
accepts either `lexid` or `id`, so all 84 readable dictionaries are handled without an adapter — that
axis needed a correct default, not per-dictionary code, and counting it would have inflated this table by
74 rows. An earlier version of this document did exactly that and claimed 82 of 86.

| Dictionary | depth | losing defs | headword | no POS | keys | no entries |
|---|---|---|---|---|---|---|
| `acc:TTY` |  |  |  |  |  | ● |
| `AppleDictionary` |  |  |  |  |  | ● |
| `NOAD` |  |  | ● |  |  |  |
| `OAWT` |  |  |  |  |  |  |
| `ODE` |  |  | ● |  |  |  |
| `OTE` |  |  |  |  |  |  |
| `OxfordFrench` |  |  | ● |  |  |  |
| `OxfordGerman` |  |  |  |  |  |  |
| `OxfordItalian` |  |  | ● |  |  |  |
| `OxfordRussian` |  |  |  |  |  |  |
| `OxfordSpanish` |  |  |  |  |  |  |
| `ar-en.oup` |  |  | ● |  |  |  |
| `as-en.oup` | ● |  | ● |  |  |  |
| `bg.oup` |  |  |  |  |  |  |
| `bn-en.oup` |  |  | ● |  |  |  |
| `ca-en.oup` |  |  | ● |  |  |  |
| `ca.oup` |  |  |  |  |  |  |
| `cs-en.oup` |  |  | ● |  |  |  |
| `da-en.oup` |  |  | ● |  |  |  |
| `da.oup` |  |  | ● |  |  |  |
| `de.DDDSI` |  | ● |  |  | ● |  |
| `el-en.oup` |  |  |  |  |  |  |
| `el.oup` | ● |  | ● |  |  |  |
| `es.DGLEV` |  |  |  |  |  |  |
| `fi-en.oup` |  |  |  |  |  |  |
| `fr-de.oup` |  |  | ● |  |  |  |
| `fr.Multi` |  |  |  |  |  |  |
| `gu-en.oup` |  |  |  |  |  |  |
| `he-en.oup` |  |  | ● |  | ● |  |
| `he.oup` |  | ● |  |  | ● |  |
| `hi-en.oup` |  | ● | ● |  |  |  |
| `hi.oup` |  |  |  |  | ● |  |
| `hr-en.oup` |  |  | ● |  |  |  |
| `hr.oup` |  |  | ● |  |  |  |
| `hu-en.oup` |  |  |  |  |  |  |
| `hu.oup` |  |  | ● |  |  |  |
| `id-en.oup` |  |  |  |  | ● |  |
| `it.Devoto-Oli` |  | ● |  |  | ● |  |
| `ja-en.WISDOM` |  |  |  |  | ● |  |
| `ja.Daijirin` |  |  |  |  | ● |  |
| `kk-en.oup` |  |  | ● |  |  |  |
| `kn-en.oup` | ● |  | ● |  |  |  |
| `ko-en.NewAce` |  |  |  |  | ● |  |
| `ko.NewAce` |  | ● |  |  | ● |  |
| `ml-en.oup` | ● |  | ● |  |  |  |
| `mr-en.oup` |  |  | ● |  |  |  |
| `ms-en.oup` |  |  | ● |  | ● |  |
| `ms.oup` |  |  |  |  | ● |  |
| `ne-en.oup` |  |  | ● |  |  |  |
| `nl-en.oup` |  |  | ● |  |  |  |
| `nl.Prisma` |  |  |  |  |  |  |
| `no-en.oup` |  |  | ● |  |  |  |
| `no.oup` |  |  |  |  | ● |  |
| `or-en.oup` |  | ● | ● |  |  |  |
| `pa-en.oup` |  | ● | ● |  | ● |  |
| `pl-en.oup` |  |  |  |  |  |  |
| `pl.oup` |  |  |  |  |  |  |
| `pt-en.oup` |  |  |  |  |  |  |
| `pt.oup` |  |  |  |  |  |  |
| `ro.oup` |  | ● |  |  | ● |  |
| `ru.oup` |  |  |  |  |  |  |
| `sa-en.oup` |  |  | ● |  |  |  |
| `sk-en.oup` |  |  | ● |  |  |  |
| `sv-en.oup` |  |  |  |  |  |  |
| `sv.oup` |  |  |  |  | ● |  |
| `ta-en.oup` |  | ● |  |  |  |  |
| `te-en.oup` |  |  | ● |  |  |  |
| `th-en.oup` |  |  | ● |  |  |  |
| `th.oup` |  |  |  |  |  |  |
| `tr-en.oup` |  |  |  |  |  |  |
| `tr.oup` |  | ● |  |  | ● |  |
| `uk-en.oup` |  |  | ● |  |  |  |
| `ur-en.oup` |  | ● | ● |  | ● |  |
| `vi-en.oup` |  |  | ● |  |  |  |
| `vi.oup` | ● |  | ● |  |  |  |
| `yue-en.cp` |  | ● | ● | ● |  |  |
| `yue-en.oup` |  |  | ● |  |  |  |
| `zh_CN-en.OCD` |  |  |  |  |  |  |
| `zh_CN.SDCC` |  |  |  |  |  |  |
| `zh_CN.idioms` |  | ● |  | ● | ● |  |
| `zh_CN.thes` |  | ● |  | ● |  |  |
| `zh_HK-en.idioms.cp` |  | ● | ● | ● |  |  |
| `zh_HK.common` |  |  | ● | ● |  |  |
| `zh_TW-en.DrEye` |  | ● | ● |  |  |  |
| `zh_TW.wn` |  |  | ● |  |  |  |
| `zhs-ja.Crown` |  |  |  |  | ● |  |

**62 of 86 dictionaries need at least one per-dictionary decision; 24 are handled by the default alone.**

| Axis | Dictionaries | What an adapter has to supply |
|---|---|---|
| sense depth ≠ 1 | 5 | the depth, measured by retention — already in `DictionaryProfile.overrides` |
| losing definitions | 16 | nothing yet: the loss is in the entry reader, not in a declaration |
| pronunciation in the headword | 42 | how to split this dictionary's headword from its phonetics |
| no part of speech | 5 | nothing — but a consumer must not narrow by it |
| keys not certified | 20 | an oracle that can localise the disagreement; possibly its own pointer decoding |
| no parseable entry | 2 | a different container reader, or acceptance that it is not a dictionary |

**The biggest single axis is the headword**, and it is not a key problem or a depth problem — it is one
defect in this module's `x_xh0` capture, recorded in the feature ledger, affecting half the catalogue.
Fixing that one thing is worth more than any per-dictionary adapter on this list.

## 7. The adapters that exist

Five, covering the languages this project needs first: Simplified Chinese, Traditional Chinese, Cantonese,
Korean, Japanese. They declare the id attribute and the authorship, and **never the sense depth** — depth
is measured over the whole catalogue by retention, and an adapter that declared it would silently outrank
that measurement.

Authorship is recorded rather than assumed: Apple licenses its whole third-party programme through Oxford,
so nearly every bundle looks Oxford at a glance. Only Simplified Chinese and Cantonese carry an
Oxford-authored work; Japanese is Sanseido, Korean DIOTEK, Traditional Chinese INVENTEC.

## 8. Traps, so they are not rediscovered

| Trap | What happens | Where |
|---|---|---|
| `COMPRESSION_ZLIB` is **raw deflate** | Every chunk fails to decompress until the 2-byte zlib header is dropped | `ContainerReader.inflate` |
| `KeyText.data`'s per-chunk size field is **0 in some chunks** | A size-driven walk stops early and returns a partial index that looks complete. Walk by the fixed 8,192 stride | `ContainerReader.keyChunks` |
| The two bytes after a key's length are **not a tag** | For a key starting `č` they are U+010D itself; read as a tag they truncate every key into a word that still looks like a word | `KeyIndexReader` |
| `class` is a space-separated **token list** | Matching `class == "x_xd1"` exactly returns 0 senses everywhere | `DictionaryProfile.marksSense` |
| `d:def` is a **flag attribute**, not the text | The definition lives in a nested element; reading the attribute hashes the string `"1"` | `EntryIndexer` |
| A sense block may hold **several** `d:def` | Emitting one sense each gives two senses one publisher id; keeping only the first destroys co-equal glosses. Join them | `EntryIndexer` |
| An in-chunk offset is **not unique** | Only 68.3% of NOAD's records sit at an offset no other record shares | `BodyLayout` |
| `resolved` is **not** `correct` | One dictionary resolves 100% of pointers and 96.5% are the wrong entry | `KeyResolutionReport.confidence` |
| A gated test **passes while measuring nothing** | Green is not evidence the measurement ran; the tests print what they measured | all gated suites |

## 9. Regenerating this document

The catalogue lists every asset with a download URL, so the full set can be recovered on any Mac:

```
/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS/
  com_apple_MobileAsset_DictionaryServices_dictionary3macOS.xml
```

Each asset's zip is `__BaseURL + __RelativePath`; the whole catalogue is about 1.7 GB. Unzip them, point
`DictionaryLocator` at the directory, and call `DictionarySurvey.measure` on each bundle — every number in
this document is a field of `DictionaryFacts`.

**Nothing derived from these bundles may be redistributed.** The text is licensed to the reader whose Mac
it is on, which is why a rebuild happens locally and why no fixture in this repository quotes one.

