"""Native Library acceptance checks. Operates only inside learning's isolated ledger fixture."""
import json
import pathlib
import sqlite3
import subprocess
import sys
import time
import uuid

BUNDLE = "com.xiaolaidict"
PANES = ("History", "Saved", "Review", "Discarded")
# One secret per layout, each on its own Saved row. The list pass reveals its answer and checks the
# reveal survives a layout switch, so that answer is on screen for the rest of the run: a grid pass
# asking the same row whether selection alone reveals it would be measuring the list pass's reveal.
REVEALS = {"list": ("LAYOUT_EXPLICIT_REVEAL_ONLY_7E29", 0), "grid": ("LAYOUT_EXPLICIT_REVEAL_ONLY_B41C", 2)}
# The copied sentence is new, so an offset into the original one would point at the wrong word.
# These are `lookups`' real column names; asserted present, because a name that matched nothing was
# skipped in silence and left every copied range pointing into the original sentence.
RANGE_COLUMNS = ["context_range_location", "context_range_length"]


def command(*args):
    # A helper that fails says why on its own output; `check_output` kept that and reported only the
    # exit status, so fourteen failures on the E2E Mac read as one sentence about nothing.
    done = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    if done.returncode != 0:
        said = done.stdout.strip()[-300:] or "nothing"
        raise subprocess.SubprocessError(
            f"{pathlib.Path(args[0]).name} {' '.join(args[1:])} exited {done.returncode}: {said}")
    return done.stdout.strip()


def validate_toolbar(report, layout):
    known = {n["identifier"]: n for n in report["nodes"] if n.get("identifier")}
    for mode in ["list", "grid"]:
        key = f"library-layout-{mode}"
        assert key in known, f"criterion 1: visible accessible {mode.title()} control is missing"
        assert key in report["controls"], f"criterion 1: {mode.title()} is not an enabled real control"
        assert bool(known[key].get("frame")), f"criterion 1: {mode.title()} has no visible frame"
        active = known[key].get("selected") is True or known[key].get("value") == 1
        assert active == (mode == layout), f"criterion 1: selected state does not name {layout}"


def identity(kind, index):
    """A distinct target of the live note's own kind. `study_notes`' CHECK says what each kind uses
    and what it must leave empty, so a clone that changed one field for every kind broke the others."""
    if kind == "sense":
        return {"entry_id": f"layout-entry-{index}", "sense_key": f"layout-sense-{index}"}
    if kind == "entry":
        return {"entry_id": f"layout-entry-{index}", "sense_key": ""}
    if kind == "phrase":
        return {"entry_id": "", "sense_key": "", "sense_key_kind": "", "phrase_text": f"layout phrase {index}"}
    raise ValueError(f"positive control: a live lookup cannot have produced a {kind!r} target")


def seed(ledger, lookup_id, output):
    db = sqlite3.connect(ledger)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    original = dict(db.execute("SELECT * FROM lookups WHERE id=?", (lookup_id,)).fetchone())
    missing = [key for key in RANGE_COLUMNS if key not in original]
    assert not missing, f"positive control: lookups has no {missing}; the range cannot be cleared"
    note = dict(db.execute("SELECT n.* FROM study_notes n JOIN study_note_lookups k ON k.note_id=n.id WHERE k.lookup_id=? LIMIT 1", (lookup_id,)).fetchone())
    answer = db.execute("SELECT * FROM study_answers WHERE note_id=?", (note["id"],)).fetchone()
    assert answer is not None, "positive control: live fixture must have an answer to clone"

    def insert(table, values):
        columns = list(values)
        db.execute(f'INSERT INTO "{table}" ({",".join(columns)}) VALUES ({",".join("?" for _ in columns)})', [values[k] for k in columns])

    fixture = {"history": [], "saved": [], "discarded": [], "reveal": {}}
    secrets = {index: (layout, secret) for layout, (secret, index) in REVEALS.items()}
    highest = db.execute("SELECT max(id) FROM lookups").fetchone()[0]
    epoch = time.time()
    for index in range(432):
        row = dict(original)
        encounter = highest + index + 1
        word = f"layoutword{index:04d}"
        row.update(id=encounter, lemma=word, surface=word, context=f"They read {word} in the native Library fixture.", looked_up_at=epoch-index)
        row.update({key: None for key in RANGE_COLUMNS})
        row["disposition"] = "kept" if index < 221 else "discarded"
        insert("lookups", row)
        pane = "history" if index < 221 else "discarded"
        fixture[pane].append(encounter)
        if pane == "history":
            saved = dict(note)
            saved.update(id=str(uuid.uuid4()).upper(), enrollment="active", confirmed_at=epoch,
                         created_at=epoch-index, **identity(note["target_kind"], index))
            insert("study_notes", saved)
            fixture["saved"].append(saved["id"])
            db.execute("INSERT INTO study_note_lookups VALUES (?,?,?)", (saved["id"], encounter, epoch-index))
            if index != 1:  # Unavailable answer, with a real saved identity.
                back = dict(answer)
                if index in secrets:
                    layout, secret = secrets[index]
                    fixture["reveal"][layout] = {"note": saved["id"], "secret": secret}
                    back.update(note_id=saved["id"], text=secret + " " + "A long saved meaning. "*80)
                else:
                    back.update(note_id=saved["id"], text=f"Meaning for {word}")
                insert("study_answers", back)
    custom = dict(note)
    custom.update(id=str(uuid.uuid4()).upper(), target_kind="custom", entry_id="", sense_key="",
                  sense_key_kind="", phrase_text="layout custom without lookup", enrollment="active",
                  confirmed_at=epoch, created_at=epoch-0.5)
    insert("study_notes", custom)
    back = dict(answer)
    back.update(note_id=custom["id"], origin="reader", text="The custom target owns this answer.")
    insert("study_answers", back)
    fixture["custom"] = custom["id"]
    fixture["saved"].insert(1, custom["id"])
    assert db.execute("SELECT count(*) FROM study_note_lookups WHERE note_id=?", (custom["id"],)).fetchone()[0] == 0
    db.commit()
    assert not db.execute("PRAGMA foreign_key_check").fetchall()
    pathlib.Path(output).write_text(json.dumps(fixture, indent=2))


class Library:
    """The live Library window, driven through the helpers, and the verdicts recorded against it."""

    def __init__(self, helpers, evidence):
        self.helpers, self.evidence = pathlib.Path(helpers), pathlib.Path(evidence)
        self.results = []

    def record(self, name, check, *args):
        try:
            check(self, *args)
            self.results.append({"test": name, "status": "passed"})
            print(f"PASS\t{name}", flush=True)
            return True
        except (AssertionError, subprocess.SubprocessError, ValueError, KeyError, StopIteration) as error:
            self.results.append({"test": name, "status": "failed", "failure": str(error)})
            print(f"FAIL\t{name}: {error}", flush=True)
            return False

    def click(self, target, *flags):
        command(str(self.helpers / "click-element"), BUNDLE, *flags, target)

    def key(self, code):
        command(str(self.helpers / "keys"), code)

    def snapshot(self, name):
        # An absence is meaningful only after the actual Library was read completely.
        #
        # **Read again until one walk finishes, because a walk can start before the view settles.**
        # Straight after a layout switch SwiftUI is still rebuilding the window, and every element the
        # walk had queued answers AXError -25202 (invalid element) — measured on the E2E Mac, grid to
        # list. That is the tree changing under the walk, not content missing, so it is waited out;
        # anything else incomplete, or a tree still changing after ten tries, still fails, naming why.
        for _ in range(10):
            report = json.loads(command(str(self.helpers / "panel"), BUNDLE))
            settling = report["incomplete"] and all("AXError -25202" in why for why in report["incomplete"])
            if report["complete"] or not settling:
                break
            time.sleep(0.5)
        (self.evidence / f"{name}.json").write_text(json.dumps(report, indent=2))
        if name.startswith(("layout-", "geometry-")):
            command("screencapture", "-x", str(self.evidence / f"{name}.png"))
        assert report["complete"], f"Accessibility report is incomplete ({report.get('incomplete')}); absence cannot be asserted"
        # Titled by its pane, with the count after it; "Library" names no window.
        windows = [w for w in report["windows"] if w["title"].startswith(PANES)]
        assert len(windows) == 1, "positive control: exactly one live Library window"
        return windows[0]

    def expect_selection(self, pane, layout, wanted, label):
        """Asserts the selected rows, and returns the report it read them from."""
        report = self.snapshot(f"selection-{pane}-{layout}-{label}")
        actual = {key for key, n in nodes(report).items() if key.startswith(f"library-{pane.lower()}-row-") and selected(n)}
        assert actual == wanted, f"criterion 3: {label} selected {actual}, expected {wanted}"
        return report


def nodes(report):
    return {n["identifier"]: n for n in report["nodes"] if n.get("identifier")}


def selected(node):
    return node.get("selected") is True or node.get("value") == 1


def row_key(pane, identity):
    return f"library-{pane.lower()}-row-{identity}"


def check_grid_default(library, pane):
    validate_toolbar(library.snapshot(f"layout-{pane}-initial"), "grid")


def check_layout_remembered(library, report, layout):
    validate_toolbar(report, layout)
    assert_equal(command("defaults", "read", BUNDLE, "libraryLayout"), layout, "persisted layout")


def check_modifier_selection(library, pane, layout, ordered, visible):
    assert all(key in visible for key in ordered[:4]), "fixture rows are not reachable"
    library.click(ordered[0], "--row")
    library.expect_selection(pane, layout, {ordered[0]}, "ordinary")
    library.click(ordered[2], "--row", "--command")
    library.expect_selection(pane, layout, {ordered[0], ordered[2]}, "command-add")
    library.click(ordered[2], "--row", "--command")
    library.expect_selection(pane, layout, {ordered[0]}, "command-toggle")
    library.click(ordered[0], "--row")
    library.click(ordered[2], "--row", "--shift")
    library.expect_selection(pane, layout, set(ordered[:3]), "shift-range")
    library.click(ordered[3], "--row", "--command", "--shift")
    library.expect_selection(pane, layout, set(ordered[:4]), "command-shift-range")


def check_keyboard_columns(library, pane, layout, ordered):
    library.click(ordered[0], "--row")
    library.key("126")
    # **Measured after selecting, never before.** A selection opens the inspector, which narrows the
    # grid — at the standard size two columns become one — so a count taken from the snapshot
    # before the click names a layout that is no longer on screen when the arrow key lands.
    report = library.expect_selection(pane, layout, {ordered[0]}, "up-at-first")
    columns = 1
    if layout == "grid":
        frames = nodes(report)
        top = frames[ordered[0]]["frame"]["y"]
        columns = sum(abs(frames[k]["frame"]["y"]-top) < 2 for k in ordered if k in frames and frames[k].get("frame"))
        assert 0 < columns < len(ordered), f"actual Grid column count cannot be measured ({columns})"
    library.key("125")
    library.expect_selection(pane, layout, {ordered[columns]}, "down-by-columns")


def check_reveal(library, pane, layout, target, secret):
    library.click(target, "--row")
    hidden = library.snapshot(f"reveal-{pane}-{layout}-hidden")
    assert secret not in str(hidden["texts"]), "criterion 4: selection revealed the answer"
    original_frame = nodes(hidden)[target]["frame"]
    library.click("Show the Meaning")
    shown = library.snapshot(f"reveal-{pane}-{layout}-shown")
    assert secret in str(shown["texts"]), "positive control: deliberate reveal must show this answer"
    assert nodes(shown)[target]["frame"]["height"] == original_frame["height"], "criterion 4: reveal changed card height"
    other = "grid" if layout == "list" else "list"
    library.click(f"library-layout-{other}")
    switched = library.snapshot(f"reveal-{pane}-{layout}-switched")
    assert secret in str(switched["texts"]), "criterion 4: layout switch lost the deliberate reveal"
    library.expect_selection(pane, layout, {target}, "switch-keeps-selection")
    library.click(f"library-layout-{layout}")


def check_context_menu(library, pane, layout, ordered):
    library.click(ordered[0], "--row")
    library.click(ordered[1], "--row", "--command")
    library.click(ordered[0], "--row", "--secondary")
    menu = library.snapshot(f"context-{pane}-{layout}")
    assert any(n["role"] == "AXMenuItem" for n in menu["nodes"]), "criterion 5: secondary click did not open a native context menu"
    library.key("53")
    library.expect_selection(pane, layout, set(ordered[:2]), "context-keeps-selection")


def check_grid_geometry(library, pane):
    library.click("library-layout-grid")
    report = library.snapshot(f"geometry-{pane}-standard")
    # The cards, not the "Show more" row that ends the collection under the same prefix.
    frames = [n["frame"] for key, n in nodes(report).items()
              if key.startswith(f"library-{pane.lower()}-row-") and not key.endswith("-more") and n.get("frame")]
    assert len(frames) > 2, "positive control: populated grid needs visible cards"
    top = min(f["y"] for f in frames)
    first = [f for f in frames if abs(f["y"]-top) < 2]
    assert len(first) == 2, f"criterion 7: expected two standard-width columns, found {len(first)}"
    for i, one in enumerate(frames):
        assert one["width"] >= 200, "criterion 7: card width is unreadable"
        for other in frames[i+1:]:
            overlap = min(one["x"]+one["width"], other["x"]+other["width"])-max(one["x"], other["x"])
            vertical = min(one["y"]+one["height"], other["y"]+other["height"])-max(one["y"], other["y"])
            assert overlap <= 1 or vertical <= 1, "criterion 7: cards overlap"


def check_review(library, review):
    assert_equal(any(key.startswith("library-layout-") for key in nodes(review)), False, "Review layout controls")
    assert_equal("Study scripts" in str(review["texts"]), False, "removed Library script filter")


def run(helpers, ledger, evidence):
    library = Library(helpers, evidence)
    fixture = json.loads((library.evidence / "layout-fixture.json").read_text())
    for pane in ["History", "Saved", "Discarded"]:
        library.click(f"library-pane-{pane.lower()}", "--row")
        time.sleep(0.3)
        # Each pane yields its own baseline failure before dependent checks are attempted.
        if not library.record(f"criterion1_{pane}_accessibleGridDefault", check_grid_default, pane):
            continue
        expected = fixture[pane.lower()]
        ordered = [row_key(pane, identity) for identity in expected[:8]]
        for layout in ["list", "grid"]:
            library.click(f"library-layout-{layout}")
            before = library.snapshot(f"layout-{pane}-{layout}")
            library.record(f"criterion1_{pane}_{layout}_selectedAndRemembered", check_layout_remembered, before, layout)
            library.record(f"criterion3_{pane}_{layout}_modifierSelection", check_modifier_selection,
                           pane, layout, ordered, nodes(before))
            library.record(f"criterion3_{pane}_{layout}_keyboardUsesActualColumns", check_keyboard_columns,
                           pane, layout, ordered)
            if pane == "Saved":
                target = fixture["reveal"][layout]
                library.record(f"criterion4_Saved_{layout}_answerAbsentUntilRevealAndStableCard", check_reveal,
                               pane, layout, row_key(pane, target["note"]), target["secret"])
            library.record(f"criterion5_{pane}_{layout}_contextRetainsSelection", check_context_menu,
                           pane, layout, ordered)
        library.record(f"criterion7_{pane}_twoColumnsWithoutOverlap", check_grid_geometry, pane)

    library.click("library-pane-review", "--row")
    review = library.snapshot("layout-Review")
    library.record("criterion9_ReviewHasNoLayoutOrStudyScriptControls", check_review, review)
    (library.evidence / "layout-results.json").write_text(json.dumps(library.results, indent=2))
    print("DONE", flush=True)
    return 0 if all(r["status"] == "passed" for r in library.results) else 1


def assert_equal(actual, expected, label):
    assert actual == expected, f"{label}: {actual!r}, expected {expected!r}"


if __name__ == "__main__":
    if sys.argv[1] == "seed":
        seed(sys.argv[2], int(sys.argv[3]), sys.argv[4])
    elif sys.argv[1] == "run":
        sys.exit(run(*sys.argv[2:]))
    else:
        raise SystemExit("usage: library-layout.py seed <isolated-ledger> <lookup> <manifest> | run <helpers> <ledger> <evidence>")
