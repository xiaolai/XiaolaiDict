"""The ledger's schema as the Swift sources declare it, for the tests that seed one.

The end-to-end fixtures write rows straight into an isolated ledger with SQL, and a seed that violates
the schema is found out only on the E2E Mac, ten minutes into a run. So the tests build their ledgers
from the literals `StudyKit` itself executes, read out of the sources rather than restated here:
a test that passes cannot be passing against a shape the app no longer writes.

Shared by `test_library_layout` and `test_review`, which each had a copy of the first two readers.
"""
from __future__ import annotations

import pathlib
import re
import sqlite3

REPO = pathlib.Path(__file__).resolve().parents[2]
# The ledger left the core for its own target on 2026-10-08 (the core split's P2).
STUDY_KIT = REPO / "Sources" / "StudyKit"
# The scheduler and the card types left the core for their own target on 2026-10-04 (ADR-0047).
REVIEW_KIT = REPO / "Sources" / "ReviewKit"


def swift_literal(source: str, name: str) -> str:
    """The body of `static let <name> = \"\"\" … \"\"\"`, as the Swift compiler would hand it to SQLite.

    **Or the literals it is joined from**, `static let <name> = <a> + "\\n" + <b>`: the migration
    rebuilds a table from its own statement, so `studySchema` and `studyCardSchema` became each table's
    literal joined (audit-fix round 2). Resolved the way Swift resolves it, from the source, so a test
    still cannot pass against a shape the app no longer writes.
    """
    match = re.search(rf'static let {name} = """\n(.*?)\n\s*"""', source, re.S)
    if match:
        return match.group(1)
    joined = re.search(rf'static let {name} = (\w+(?: \+ "\\n" \+ \w+)+)\n', source)
    assert joined, f"{name} is no longer a multi-line literal or a join of them; this test reads the schema from it"
    return "\n".join(swift_literal(source, part) for part in joined.group(1).split(' + "\\n" + '))


# **What the walk below must be seen to read**, named rather than counted: a glob of a directory the
# ledger has left reads the files that remain, and would fail only at the first table it cannot find.
LEDGER_FILES = ("Ledger.swift", "StudyLedger.swift", "LookupKeeping.swift")


def _study_kit_sources() -> str:
    paths = sorted(STUDY_KIT.glob("*.swift"))
    unread = sorted(set(LEDGER_FILES) - {path.name for path in paths})
    assert not unread, f"the walk of {STUDY_KIT} no longer reads {unread}; the ledger has moved"
    return "\n".join(path.read_text() for path in paths)


def _created(sources: str, table: str) -> str:
    create = re.search(rf"CREATE TABLE {table} \(.*?\);", sources, re.S)
    assert create, f"the {table} table is no longer created where this test looks"
    return create.group(0)


def lookups_schema() -> list[str]:
    """`lookups` as the migrations leave it: the table they create and every column they add."""
    sources = _study_kit_sources()
    added = re.findall(r"ALTER TABLE lookups ADD COLUMN [^;]*;", sources, re.S)
    assert len(added) >= 20, f"found only {len(added)} lookups columns added; the scan has gone blind"
    return [_created(sources, "lookups"), *added]


def study_ledger(path: pathlib.Path) -> None:
    """An empty ledger with every table the review fixture writes or the review queue reads.

    `studyKeepingSchema` is included because it is what makes a new note *collected*: its trigger
    gives every inserted note an explicit keep, and without it no seeded card is askable at all.
    """
    sources = _study_kit_sources()
    study = (STUDY_KIT / "StudyLedger.swift").read_text()
    keeping = (STUDY_KIT / "LookupKeeping.swift").read_text()
    db = sqlite3.connect(path)
    try:
        for statement in lookups_schema():
            db.executescript(statement)
        db.executescript(_created(sources, "sense_encounters"))
        for name in ("studySchema", "studyAnswerSchema", "studyCardSchema"):
            db.executescript(swift_literal(study, name))
        db.executescript(swift_literal(keeping, "studyKeepingSchema"))
        db.commit()
    finally:
        db.close()


def askable_predicate() -> str:
    """`Ledger.askableNotePredicate` with every predicate it interpolates put in its place, so a test
    can ask the queue's own question of a seeded ledger rather than a paraphrase of it.

    **Every `\\(Ledger.name)`, resolved from the sources, and none left behind.** This replaced one
    named interpolation by hand, so when WI-4 split two clauses out into `evidencedNotePredicate` and
    `gradableAnswerPredicate` the literal reached SQLite with `\\(` still in it — an "unrecognized
    token" from a predicate the app itself compiles. A clause that moves must not need this file edited.
    """
    sources = _study_kit_sources()
    askable = swift_literal(sources, "askableNotePredicate")
    assert r"\(Ledger.collectedNotePredicate)" in askable, \
        "askableNotePredicate no longer interpolates collectedNotePredicate"
    for _ in range(8):
        names = set(re.findall(r"\\\(Ledger\.(\w+)\)", askable))
        if not names:
            break
        for name in names:
            askable = askable.replace(rf"\(Ledger.{name})", swift_literal(sources, name))
    assert r"\(" not in askable, f"an interpolation this reader cannot resolve is left in: {askable}"
    return askable


def scheduler_version() -> str:
    """`MemoryScheduler.version`: what a card the app writes carries in `scheduler_version`."""
    source = (REVIEW_KIT / "MemoryScheduler.swift").read_text()
    match = re.search(r'public static let version = "([^"]+)"', source)
    assert match, "MemoryScheduler.version is no longer a string literal where this test looks"
    return match.group(1)
