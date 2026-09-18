"""Publishing: replacing XiaolaiDict.icon and MenuBarIcon.svg in the Resources dir, both or neither.

Two paths cannot be swapped in one atomic step, so the swap is made recoverable instead. The new
outputs are staged in .make-icon-publish/new/ beside the old ones and flushed to disk. Then a
journal is committed, recording whether each output existed before and the SHA-256 of every file of
both pairs, previous and new. Only then is each output renamed into place, its predecessor moved to
.make-icon-publish/old/.

The window: from the first rename to the last, the pair on disk is mixed, or an output is missing.
A run that dies inside it leaves it so, and nothing here can close it at that moment. The next run
closes it before it reads anything: every copy is always at one of three points (staged, set aside,
published), which can be read from what exists, so recover() rolls forward when every new file
matches the journal, rolls back when every previous one does, and otherwise moves nothing and names
every path. Nothing consumes the pair inside the window: Tools/build-bundle.sh, its one consumer,
runs this generator synchronously under its bundle lock, and a pair a crash left mixed no longer
matches its digest of the outputs' bytes, so it is regenerated, never used; and the generator's
first act is recover(). A lock on the Resources dir keeps two runs of the generator from overlapping.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

from . import PROG, fail

ARTIFACTS = ("XiaolaiDict.icon", "MenuBarIcon.svg")
WORK = ".make-icon-publish"  # beside the outputs, so that every move is a rename within one volume


@contextmanager
def locked(directory: Path) -> Iterator[None]:
    """An exclusive flock on the directory itself, so there is no lock file to leave behind."""
    fd = os.open(directory, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # releases the lock


def flush(path: Path) -> None:
    """Push a file's data, or a directory's entries, to stable storage. On macOS plain fsync stops
    at the drive's own cache; F_FULLFSYNC goes through it."""
    fd = os.open(path, os.O_RDONLY)
    try:
        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
        except (AttributeError, OSError):
            os.fsync(fd)
    finally:
        os.close(fd)


def digests(base: Path, name: str) -> dict[str, str]:
    """The SHA-256 of every file of output `name` under `base`, by path relative to `base`."""
    root = base / name
    found = [root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file()) \
        if root.is_dir() else []
    return {p.relative_to(base).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in found}


def stage(new: Path, files: dict[str, bytes]) -> None:
    """Write every file under `new`, read the tree back, flush it all to disk. A name that collides
    on a case-insensitive volume, or a write that silently came up short, stops the run here."""
    for rel, data in files.items():
        (new / rel).parent.mkdir(parents=True, exist_ok=True)
        (new / rel).write_bytes(data)
    written = {p.relative_to(new).as_posix(): p.read_bytes() for p in new.rglob("*") if p.is_file()}
    if written != files:
        fail(f"staged outputs in {new} do not read back as written")
    for path in [*new.rglob("*"), new]:
        flush(path)


def plan(resources: Path, files: dict[str, bytes]) -> dict:
    """The journal: which outputs exist now, and the SHA-256 of every file of both pairs."""
    previous = {}
    for name in ARTIFACTS:
        previous.update(digests(resources, name))
    return {"had": {name: os.path.lexists(resources / name) for name in ARTIFACTS}, "previous": previous,
            "new": {rel: hashlib.sha256(data).hexdigest() for rel, data in files.items()}}


def commit(work: Path, journal: dict) -> None:
    """Write the journal whole or not at all, and have it on disk before anything published moves."""
    pending = work / "journal.tmp"
    pending.write_text(json.dumps(journal, sort_keys=True))
    flush(pending)
    os.replace(pending, work / "journal")
    flush(work)


def roll_forward(resources: Path, work: Path) -> None:
    """Put each staged output in place, its predecessor aside; an output already in place stays."""
    for name in ARTIFACTS:
        new, old, published = work / "new" / name, work / "old" / name, resources / name
        if os.path.lexists(new):
            if os.path.lexists(published):
                os.rename(published, old)
            os.rename(new, published)
    flush(resources)


def roll_back(resources: Path, work: Path) -> None:
    """Undo roll_forward from wherever it stopped: each new output back out, each predecessor in."""
    for name in reversed(ARTIFACTS):
        new, old, published = work / "new" / name, work / "old" / name, resources / name
        if not os.path.lexists(new) and os.path.lexists(published):
            os.rename(published, new)
        if os.path.lexists(old):
            os.rename(old, published)
    flush(resources)


def retire(work: Path) -> None:
    """Remove a finished or undone publish. The journal goes first: once it is gone, whatever is
    left is known to be discardable."""
    os.remove(work / "journal")
    flush(work)
    shutil.rmtree(work)


def feasible(resources: Path, work: Path, journal: dict) -> tuple[bool, bool]:
    """Whether rolling forward, and rolling back, would each end in a consistent pair. Every output
    must be at a point the swap passes through: not yet moved, its predecessor set aside, or in
    place. Forward also needs every new file to match the journal; back, every previous file."""
    forward = backward = True
    for name in ARTIFACTS:
        new, old, published = (os.path.lexists(p) for p in (work / "new" / name, work / "old" / name,
                                                             resources / name))
        had = journal["had"][name]
        unmoved = new and not old and published == had
        aside = new and old and not published and had
        forward = forward and (unmoved or aside or (not new and published))
        backward = backward and (unmoved or aside or (not new and published and old == had))
    if forward:
        found = {}
        for name in ARTIFACTS:
            found.update(digests(work / "new" if os.path.lexists(work / "new" / name) else resources, name))
        forward = found == journal["new"]
    if backward:  # never restore a damaged or partial previous pair
        found = {}
        for name in ARTIFACTS:
            if os.path.lexists(work / "old" / name):  # set aside
                found.update(digests(work / "old", name))
            elif os.path.lexists(work / "new" / name):  # not moved yet, so the published copy
                found.update(digests(resources, name))
        backward = found == journal["previous"]
    return forward, backward


def read_journal(work: Path) -> dict:
    path = work / "journal"
    try:
        journal = json.loads(path.read_text())
        if set(journal["had"]) != set(ARTIFACTS) or not all(isinstance(journal[k], dict) for k in
                                                           ("new", "previous")):
            raise ValueError("unexpected contents")
    except (ValueError, KeyError, TypeError) as e:
        fail(f"cannot read the publish journal {path} ({e}); nothing was moved: inspect {work} by hand")
    return journal


def stuck(resources: Path, work: Path) -> str:
    """Why an interrupted publish is left alone, naming the path of every copy it involves."""
    lines = [f"the interrupted publish recorded in {work / 'journal'} can be neither finished nor "
             "undone: in each pair a copy is missing, out of place, or not the file the journal "
             "recorded. Nothing was moved. Every copy:"]
    for name in ARTIFACTS:
        for label, path in (("staged", work / "new" / name), ("previous", work / "old" / name),
                            ("published", resources / name)):
            lines.append(f"  {label:9s} {path}  {'present' if os.path.lexists(path) else 'missing'}")
    return "\n".join(lines)


def settle(resources: Path, work: Path, journal: dict, back_first: bool) -> str:
    """Bring an unfinished swap to a pair the journal vouches for, in the preferred direction if it
    can, and retire it. Fails, moving nothing, when neither pair verifies."""
    forward, backward = feasible(resources, work, journal)
    ways = [("rolled back to the previous outputs", backward, roll_back),
            ("rolled forward to the new outputs", forward, roll_forward)]
    for done, possible, move in ways if back_first else reversed(ways):
        if possible:
            move(resources, work)
            retire(work)
            return done
    fail(stuck(resources, work))


def recover_locked(resources: Path) -> None:
    """Deal with whatever an interrupted publish left in `resources`; the caller holds the lock."""
    work = resources / WORK
    strays = sorted(p.name for p in resources.glob(".make-icon-*") if p.name != WORK)
    if strays:
        fail(f"unrecognised leftovers in {resources}: {', '.join(strays)}. They may hold the only copy "
             "of earlier outputs, so they are not touched: inspect them and remove them by hand")
    if not work.exists():
        return
    if not (work / "journal").exists():  # nothing published had moved yet, or all of it had
        shutil.rmtree(work)
        notice = f"discarded {work}, left by a publish that had not begun its swap or had finished it"
    else:
        notice = f"recovered an interrupted publish: {settle(resources, work, read_journal(work), False)}"
    print(f"{PROG}: {notice}", file=sys.stderr)


def recover(resources: Path) -> None:
    """Finish or undo an interrupted publish, if one is there. Every run starts with this."""
    try:
        with locked(resources):
            recover_locked(resources)
    except OSError as e:
        fail(f"could not recover the interrupted publish in {resources / WORK}: {e}")


def publish_outputs(resources: Path, files: dict[str, bytes]) -> None:
    """Replace XiaolaiDict.icon and MenuBarIcon.svg under `resources` with `files`: both, or neither."""
    if {rel.split("/")[0] for rel in files} != set(ARTIFACTS):
        fail(f"internal: outputs {sorted(files)} are not exactly {', '.join(ARTIFACTS)}")
    work, settled = resources / WORK, ""
    try:
        with locked(resources):
            recover_locked(resources)
            try:
                stage(work / "new", files)
                (work / "old").mkdir()
                journal = plan(resources, files)
                commit(work, journal)
            except BaseException:
                shutil.rmtree(work, ignore_errors=True)  # nothing published has moved yet
                raise
            try:
                roll_forward(resources, work)
            except BaseException:  # undo, if the previous pair verifies; should this fail too, the
                settled = settle(resources, work, journal, True)  # journal stays for the next run
                raise
            retire(work)
    except OSError as e:
        pending = work / "journal"
        hint = (f"; then {settled}" if settled else
                f"; {pending} records it, and the next run finishes or undoes it" if pending.exists() else "")
        fail(f"could not publish into {resources}: {e}{hint}")
