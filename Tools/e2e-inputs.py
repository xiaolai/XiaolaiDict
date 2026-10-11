#!/usr/bin/env python3
"""The inputs of each end-to-end stage, hashed into one key — so a stage whose inputs are unchanged since a fresh pass
is carried forward, marked, instead of run again.

    e2e-inputs.py keys                       stage<TAB>key<TAB>why, for every stage (key `-` where none can be made)
    e2e-inputs.py plan KEYS STATUS HOST OS [--full] [--asked "a b"] [--within "a b"]
                                             stage<TAB>run|carried|not-asked<TAB>why
    e2e-inputs.py settle BEFORE AFTER        stage<TAB>key, `-` where the key moved while the stages ran
    e2e-inputs.py table PLAN [RUN_LOG]       the table a person reads: PASS, FAIL, CARRIED (and why), NO RESULT
    e2e-inputs.py release-gate STATUS        exit 1, naming each stage without a fresh pass of this source tree
    e2e-inputs.py tree                       the git tree of a clean working copy, or `-`
    e2e-inputs.py mode BUILD                 `development` or `release`, from the shape of a build number
    e2e-inputs.py snapshot DIR               DIR/keys and DIR/tree, taken before `make e2e` builds the bundle
    e2e-inputs.py since-build BEFORE NOW     stage<TAB>key<TAB>why, `-` where a key moved between build and run
    e2e-inputs.py check                      exit 1, naming every problem with the declarations

**What a key covers** — `Tools/e2e/stage-inputs.tsv` declares it, one row per input:

- `module M`: every file of SwiftPM target M and, transitively, of every target it depends on, read off the package
  graph (`swift package dump-package`) and never listed by hand a second time;
- `own M`: the files of target M alone — the app target, which every stage runs and which links nearly everything;
- `path P`: a file, a directory or a glob under the repository;
- the stage's own region of `Tools/e2e.sh`, from its `if want <stage>; then` to the next stage's;
- and, for every stage, the `*` rows and everything in `Tools/e2e.sh` outside the stages' regions.

**A carried result is a development-loop optimisation and nothing more.** A merge or a release needs a fresh pass of
every stage of a development bundle built from its own clean source tree (`release-gate`), and a CARRIED row is refused
there. The release artifact itself is not what the harness ran: ADR-0010 compiles the instruments the stages observe
through out of a release, and `verify_bundle` is what checks that artifact (`release_gap`).

**A false skip is far worse than an extra run**, so every doubt resolves to "run it": a declared pattern that matches
nothing, a module the package does not have, a stage with no entry — each leaves the stage without a key, and a stage
without a key always runs.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import re
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
INPUTS = REPO / "Tools" / "e2e" / "stage-inputs.tsv"
SCRIPT = REPO / "Tools" / "e2e.sh"
KINDS = ("module", "own", "path", "unexercised")
IGNORED_NAMES = {".DS_Store"}
NO_KEY = "-"


@dataclasses.dataclass(frozen=True)
class Row:
    stage: str      # a stage, `*` for every stage, `-` for an unexercised module
    kind: str
    value: str
    reason: str


@dataclasses.dataclass(frozen=True)
class Target:
    name: str
    type: str
    path: str
    deps: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class Key:
    value: str | None
    why: str


@dataclasses.dataclass(frozen=True)
class Record:
    """One row of `.build/e2e-status.tsv`, as `Tools/e2e-status.sh record` writes it:
    stage, result, build, when, key, host, os, tree, mode — `key`, `host` and `os` absent from a row filed before keys
    existed, `tree` and `mode` from one filed before the release receipt; each reads as `-`."""
    stage: str
    result: str
    build: str
    when: str
    key: str
    host: str
    os: str
    tree: str
    mode: str


@dataclasses.dataclass(frozen=True)
class Decision:
    stage: str
    run: bool
    carried: bool
    why: str


# ---------------------------------------------------------------------------------------------------------------------
# The declarations.

def parse_inputs(text: str) -> list[Row]:
    rows = []
    for number, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise ValueError(f"stage-inputs line {number}: four tab-separated fields, got {len(fields)}: {line!r}")
        stage, kind, value, reason = (field.strip() for field in fields)
        if kind not in KINDS:
            raise ValueError(f"stage-inputs line {number}: kind {kind!r} is not one of {', '.join(KINDS)}")
        if not value or not reason:
            raise ValueError(f"stage-inputs line {number}: a value and a reason are both required")
        if (kind == "unexercised") != (stage == "-"):
            raise ValueError(f"stage-inputs line {number}: `unexercised` rows, and only they, have the stage `-`")
        if stage not in ("*", "-") and not re.fullmatch(r"[a-z]+", stage):
            raise ValueError(f"stage-inputs line {number}: {stage!r} is not a stage name")
        if kind == "path":
            parts = pathlib.PurePosixPath(value).parts
            if value.startswith("/") or ".." in parts:
                raise ValueError(f"stage-inputs line {number}: {value!r} must be a path inside the repository")
        rows.append(Row(stage, kind, value, reason))
    return rows


def known_stages(script_text: str) -> tuple[str, ...]:
    found = re.search(r"^KNOWN_STAGES=\(([^)]*)\)$", script_text, re.MULTILINE)
    if not found:
        raise ValueError("Tools/e2e.sh has no KNOWN_STAGES line")
    return tuple(found.group(1).split())


HEREDOC = re.compile(r"(?<!<)<<-?\s*'?([A-Za-z_][A-Za-z0-9_]*)'?")


def _heredoc_bodies(lines: list[str]) -> set[int]:
    """The line numbers inside a heredoc other than `SH` — the remote run script is one `SH` heredoc holding every
    stage, so it is read as code; the Python validators inside it are not, and their `if x:` is not the shell's."""
    inside: set[int] = set()
    marker = None
    quoted = False      # inside a `python3 -c '…'` block, which ends at the next apostrophe, as e2e.sh's guard reads it
    for number, line in enumerate(lines):
        if quoted:
            inside.add(number)
            quoted = "'" not in line
            continue
        if marker is not None:
            if line == marker:
                marker = None
            else:
                inside.add(number)
            continue
        if line.lstrip().startswith("#"):
            continue
        if line.rstrip().endswith("python3 -c '"):
            quoted = True
            continue
        opened = HEREDOC.search(line)
        if opened and opened.group(1) != "SH":
            marker = opened.group(1)
    return inside


def _regions(script_text: str) -> tuple[dict[str, list[str]], str]:
    """Each stage's region — its `if want <stage>; then` line through the `fi` that closes it — and the rest of the
    script, which every stage shares. The closing `fi` is found by balancing the `if` and `fi` at the start of a line,
    outside heredocs: a function written between two stages belongs to neither, and taking the next stage's opening as
    the end handed `selection_box`, which the selection stage calls, to the accessibility stage."""
    lines = script_text.split("\n")
    skipped = _heredoc_bodies(lines)
    regions: dict[str, list[str]] = {}
    shared: list[str] = []
    current: str | None = None
    depth = 0
    for number, line in enumerate(lines):
        if current is None:
            opened = re.fullmatch(r"if want ([a-z]+); then", line)
            if opened:
                current, depth = opened.group(1), 1
                regions.setdefault(current, []).append(f"# region {len(regions.get(current, []))}")
                regions[current].append(line)
            else:
                shared.append(line)
            continue
        regions[current].append(line)
        if number in skipped:
            continue
        if re.match(r"if\b", line) and not line.rstrip().endswith(":"):
            # `if …; then …; fi` on one line opens and closes nothing.
            if not re.search(r";\s*fi\s*(#.*)?$", line):
                depth += 1
        elif re.match(r"fi\b", line):
            depth -= 1
            if depth == 0:
                current = None
    if current is not None:
        raise ValueError(f"Tools/e2e.sh: the {current} region is never closed")
    return regions, "\n".join(shared)


def split_script(script_text: str, stages) -> tuple[dict[str, str], str]:
    regions, shared = _regions(script_text)
    for stage in stages:
        if stage not in regions:
            raise ValueError(f"Tools/e2e.sh has no `if want {stage}; then` region")
    for stage, lines in regions.items():
        if sum(1 for line in lines if line.startswith("# region ")) != 1:
            raise ValueError(f"Tools/e2e.sh opens the {stage} region more than once")
    return {stage: "\n".join(lines) for stage, lines in regions.items()}, shared


# ---------------------------------------------------------------------------------------------------------------------
# The package graph.

def dump_package(repo: pathlib.Path) -> dict:
    done = subprocess.run(["swift", "package", "dump-package"], cwd=repo, capture_output=True, text=True,
                          timeout=600, check=False)
    if done.returncode != 0:
        raise RuntimeError(f"swift package dump-package failed: {done.stderr.strip()}")
    return json.loads(done.stdout)


def targets_from_dump(dump: dict) -> dict[str, Target]:
    targets = {}
    for target in dump["targets"]:
        deps = []
        for dependency in target.get("dependencies") or []:
            (kind, value), = dependency.items()
            # `product` is another package's; `Package.resolved`, a shared input, is what moves when one changes.
            if kind in ("byName", "target"):
                deps.append(value[0])
        default = "Tests" if target["type"] == "test" else "Sources"
        targets[target["name"]] = Target(target["name"], target["type"], target.get("path") or f"{default}/{target['name']}",
                                         tuple(deps))
    # A `byName` that names no target here is another package's product: dropped, for the reason above.
    return {name: dataclasses.replace(t, deps=tuple(d for d in t.deps if d in targets)) for name, t in targets.items()}


def closure(targets: dict[str, Target], names) -> set[str]:
    seen: set[str] = set()
    pending = list(names)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        if name not in targets:
            raise KeyError(name)
        seen.add(name)
        pending.extend(targets[name].deps)
    return seen


def _files_under(repo: pathlib.Path, path: pathlib.Path) -> list[str]:
    if path.is_file():
        return [path.relative_to(repo).as_posix()]
    if not path.is_dir():
        return []
    return [p.relative_to(repo).as_posix() for p in path.rglob("*") if p.is_file() and p.name not in IGNORED_NAMES]


def target_own_files(repo: pathlib.Path, targets: dict[str, Target], name: str) -> list[str]:
    if name not in targets:
        raise KeyError(name)
    return sorted(_files_under(repo, repo / targets[name].path))


def module_closure_files(repo: pathlib.Path, targets: dict[str, Target], names) -> list[str]:
    return sorted({f for name in closure(targets, names) for f in target_own_files(repo, targets, name)})


def pattern_files(repo: pathlib.Path, pattern: str) -> list[str]:
    if any(c in pattern for c in "*?["):
        matches = list(repo.glob(pattern))
    else:
        matches = [repo / pattern]
    return sorted({f for match in matches for f in _files_under(repo, match)})


# ---------------------------------------------------------------------------------------------------------------------
# The key.

def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stage_keys(repo: pathlib.Path, script_text: str, rows: list[Row], targets: dict[str, Target],
               only=None) -> dict[str, Key]:
    stages = known_stages(script_text)
    regions, shared = _regions(script_text)
    shared_rows = [row for row in rows if row.stage == "*"]
    hashed: dict[str, str] = {}

    def file_hash(relative: str) -> str:
        if relative not in hashed:
            hashed[relative] = _digest((repo / relative).read_bytes())
        return hashed[relative]

    keys = {}
    for stage in stages:
        if only is not None and stage not in only:
            continue
        own_rows = [row for row in rows if row.stage == stage]
        if not own_rows:
            keys[stage] = Key(None, "no entry in Tools/e2e/stage-inputs.tsv, so it always runs")
            continue
        if stage not in regions:
            keys[stage] = Key(None, f"no `if want {stage}; then` region in Tools/e2e.sh")
            continue
        files: set[str] = set()
        problem = None
        for row in shared_rows + own_rows:
            try:
                if row.kind == "module":
                    found = module_closure_files(repo, targets, [row.value])
                elif row.kind == "own":
                    found = target_own_files(repo, targets, row.value)
                else:
                    found = pattern_files(repo, row.value)
            except KeyError as missing:
                problem = f"module {missing.args[0]} is not in the package"
                break
            if not found:
                problem = f"{row.value} matches no file"
                break
            files |= set(found)
        if problem:
            keys[stage] = Key(None, f"{problem}, so it always runs")
            continue
        lines = ["declaration\t" + "\t".join((row.stage, row.kind, row.value)) for row in shared_rows + own_rows]
        lines.append("region:shared\t" + _digest(shared.encode()))
        lines.append(f"region:{stage}\t" + _digest("\n".join(regions[stage]).encode()))
        lines.extend(f"file\t{relative}\t{file_hash(relative)}" for relative in sorted(files))
        keys[stage] = Key(_digest("\n".join(lines).encode()), f"{len(files)} files")
    return keys


# ---------------------------------------------------------------------------------------------------------------------
# The record, and what it allows.

def read_status(text: str) -> dict[str, Record]:
    records = {}
    for line in text.split("\n"):
        if not line.strip():
            continue
        fields = line.split("\t")
        fields += [NO_KEY] * (9 - len(fields))
        records[fields[0]] = Record(*fields[:9])
    return records


def decide(stages, keys: dict[str, Key], records: dict[str, Record], host: str, os_version: str,
           asked=(), full: bool = False, within=()) -> list[Decision]:
    """`asked`: run those, fresh, and nothing else. `full`: run every stage fresh. `within`: incremental over those
    stages alone. None of them: incremental over every stage."""
    decisions = []
    for stage in stages:
        key = keys.get(stage, Key(None, "no key"))
        record = records.get(stage)
        if within and stage not in within:
            decisions.append(Decision(stage, False, False, "not asked for"))
        elif asked:
            decisions.append(Decision(stage, stage in asked, False, "asked for" if stage in asked else "not asked for"))
        elif full:
            decisions.append(Decision(stage, True, False, "a full run"))
        elif key.value is None:
            decisions.append(Decision(stage, True, False, key.why))
        elif record is None:
            decisions.append(Decision(stage, True, False, "never recorded"))
        elif record.result != "pass":
            decisions.append(Decision(stage, True, False, f"last result {record.result}"))
        elif record.key in (NO_KEY, ""):
            decisions.append(Decision(stage, True, False, "its last pass was recorded without an inputs key"))
        elif record.key != key.value:
            decisions.append(Decision(stage, True, False, f"inputs changed since the pass on build {record.build}"))
        elif record.host != host:
            decisions.append(Decision(stage, True, False, "its last pass was on another Mac"))
        elif record.os != os_version:
            decisions.append(Decision(stage, True, False, f"its last pass was on macOS {record.os}"))
        else:
            decisions.append(Decision(stage, False, True, f"inputs unchanged ({key.value[:12]}); fresh pass "
                                                          f"{record.when} on build {record.build}"))
    return decisions


def settle(before: dict[str, str], after: dict[str, str]) -> dict[str, str]:
    """The keys to file: a stage whose inputs moved while it ran passed on something no key describes."""
    return {stage: key if after.get(stage) == key else NO_KEY for stage, key in before.items()}


def since_build(before: dict[str, str], now: dict[str, str]) -> list[tuple[str, str, str]]:
    """The keys a run may plan and file under: those taken before the bundle was built, where they still hold. A key
    that moved in between describes files the bundle may not have been built from, so the stage runs and its pass can
    never be carried — the same rule as `settle`, one step earlier."""
    out = []
    for stage, key in now.items():
        if key != NO_KEY and before.get(stage) == key:
            out.append((stage, key, "inputs unchanged since the build"))
        elif key == NO_KEY:
            out.append((stage, NO_KEY, "no key could be made, so it always runs"))
        else:
            out.append((stage, NO_KEY, "its inputs changed between the build and the run, so it runs and cannot be "
                                       "carried from this pass"))
    return out


def source_tree(repo: pathlib.Path) -> str | None:
    """The git tree a clean working copy is, or None — a modified or untracked file is source no commit names, and a
    directory that is not a repository has no tree. Ignored files (`.build`, `dev-docs`, `local.mk`) are not source."""
    def ask(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=120, check=False)
    status = ask("status", "--porcelain", "--untracked-files=normal")
    if status.returncode != 0 or status.stdout.strip():
        return None
    tree = ask("rev-parse", "HEAD^{tree}")
    value = tree.stdout.strip()
    return value if tree.returncode == 0 and re.fullmatch(r"[0-9a-f]{40,64}", value) else None


def build_mode(build: str) -> str:
    """`build-bundle.sh` numbers a release from the release counter — a positive integer, and nothing else may be one —
    and a development bundle from the clock, `year.monthday.time`."""
    if re.fullmatch(r"[1-9][0-9]{0,8}", build):
        return "release"
    if re.fullmatch(r"[0-9]+(\.[0-9]+)+", build):
        return "development"
    return NO_KEY


def release_refusals(stages, records: dict[str, Record], tree: str | None) -> list[str]:
    """Every reason a release may not go out on this E2E record. `tree` is the release's own clean source tree."""
    if tree is None:
        return ["the source tree has uncommitted or untracked changes, so no end-to-end pass can be shown to be of "
                "what would be released: commit, then make e2e-full"]
    refused = []
    passes = []
    for stage in stages:
        record = records.get(stage)
        if record is None:
            refused.append(f"{stage}: never recorded")
        elif record.result == "carried":
            refused.append(f"{stage}: CARRIED, which is never valid for a merge or a release")
        elif record.result != "pass":
            refused.append(f"{stage}: last result {record.result}")
        elif record.tree in (NO_KEY, ""):
            refused.append(f"{stage}: its last pass recorded no clean source tree (a dirty tree, a run not started by "
                           f"make e2e, or a tree that moved during the run)")
        elif record.tree != tree:
            refused.append(f"{stage}: stale — its last fresh pass was of source tree {record.tree[:12]}, "
                           f"not this one, {tree[:12]}")
        elif record.mode in (NO_KEY, ""):
            refused.append(f"{stage}: its last pass recorded no build mode")
        elif record.mode != "development":
            refused.append(f"{stage}: its last pass ran a {record.mode} bundle; the evidence is a development bundle "
                           f"built from this tree")
        elif record.host in (NO_KEY, "") or record.os in (NO_KEY, ""):
            refused.append(f"{stage}: its last pass recorded no E2E Mac or macOS build")
        else:
            passes.append(record)
    if passes:
        first = passes[0]
        for record in passes[1:]:
            if (record.host, record.os) != (first.host, first.os):
                refused.append(f"{record.stage}: passed on {record.host} macOS {record.os}, where {first.stage} passed "
                               f"on {first.host} macOS {first.os} — the evidence is one E2E Mac's, on one macOS build")
    return refused


def status_lines(stages, records: dict[str, Record], on_disk: str, keys: dict[str, Key] | None,
                 seen: tuple[str, ...] | None) -> list[tuple[str, str, str]]:
    """What each recorded row is worth now, for `make e2e-status`: (name, verdict, text), sorted by name.

    FAILED — its last result failed, on whatever build. FRESH PASS — a pass on the bundle on disk. Otherwise a pass on an
    older build is judged by the planner's own rule (`decide`), against the keys now and the E2E Mac the last run saw:
    CARRIED where a plain `make e2e` would carry it, STALE where it would run it, and UNKNOWN where that cannot be
    established — the keys could not be made, or no run has recorded an E2E Mac — because a carry shown on a guess is
    a false green. A row that is not a stage (the preflight, the cleanup) is FRESH PASS or STALE by its build alone."""
    lines = []
    for name in sorted(records):
        record = records[name]
        tested = f"build {record.build}, {record.when}"
        if record.host not in (NO_KEY, ""):
            tested += f", on {record.host[:8]} macOS {record.os}"
        if record.result == "fail":
            lines.append((name, "FAILED", tested))
        elif record.result != "pass":
            lines.append((name, "UNKNOWN", f"last result {record.result!r}, {tested}"))
        elif record.build == on_disk:
            lines.append((name, "FRESH PASS", tested))
        elif name not in stages:
            lines.append((name, "STALE", f"ran on {tested}"))
        elif keys is None:
            lines.append((name, "UNKNOWN", f"ran on {tested}; the stages' keys could not be made, so whether it would "
                                           f"be carried is unknown"))
        elif seen is None:
            lines.append((name, "UNKNOWN", f"ran on {tested}; no run has recorded which E2E Mac it would be carried to"))
        else:
            decision = decide((name,), keys, records, seen[0], seen[1])[0]
            if decision.carried:
                lines.append((name, "CARRIED", f"fresh pass on {tested}; inputs unchanged, if the E2E Mac is still "
                                               f"{seen[0][:8]} on macOS {seen[1]} as last seen {seen[2] if len(seen) > 2 else ''}"
                                               f" — does not satisfy a merge or a release"))
            else:
                lines.append((name, "STALE", f"ran on {tested}; {decision.why}"))
    return lines


def show(lines: list[tuple[str, str, str]], on_disk: str, status: str) -> str:
    out = [f"end-to-end stages, against build {on_disk} on disk"]
    if not lines:
        out.append("  nothing recorded yet")
    out += [f"  {name:<14} {verdict:<10} {text}" for name, verdict, text in lines]
    if any(verdict != "FRESH PASS" for _, verdict, _ in lines):
        out.append("  only a fresh pass of every stage counts for a merge or a release; CARRIED, STALE, UNKNOWN and "
                   "FAILED rows do not satisfy one (Tools/e2e-status.sh require-fresh)")
    out.append(f"  {status}")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------------------------------
# What a release cannot have run.

def release_refused_instruments(bundle_script: str) -> tuple[str, ...]:
    """The launch modes a release refuses, read from the list `verify_capture_instruments` holds the binary to."""
    found = re.search(r"local flags=\(([^)]*)\)", bundle_script)
    if not found:
        raise ValueError("Tools/build-bundle.sh has no `local flags=(…)` list of the instruments a release refuses")
    return tuple(found.group(1).split())


def instruments_by_stage(script_text: str, flags) -> dict[str, list[str]]:
    """Each stage that calls a refused instrument — in its own region, or through a shared function that does, however
    deeply — and which. Comments and the Python validators' bodies are not calls."""
    regions, shared = _regions(script_text)
    bodies: dict[str, list[str]] = {}
    current = None
    for line in _code(shared).split("\n"):
        opened = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\(\) \{", line)
        if opened:
            current = opened.group(1)
            bodies[current] = []
        if current:
            bodies[current].append(line)
            if line.startswith("}"):
                current = None
    calls = {name: {flag for flag in flags if re.search(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", "\n".join(body))}
             for name, body in bodies.items()}
    changed = True
    while changed:
        changed = False
        for name, body in bodies.items():
            text = "\n".join(body)
            for other in bodies:
                if other != name and re.search(rf"\b{other}\b", text) and not calls[other] <= calls[name]:
                    calls[name] |= calls[other]
                    changed = True
    used = {}
    for stage, lines in regions.items():
        text = _code("\n".join(lines))
        found = {flag for flag in flags if re.search(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", text)}
        for name, through in calls.items():
            if through and re.search(rf"\b{name}\b", text):
                found |= through
        if found:
            used[stage] = sorted(found)
    return used


def release_gap(script_text: str, bundle_script: str) -> str:
    used = instruments_by_stage(script_text, release_refused_instruments(bundle_script))
    lines = ["The evidence is a development bundle built from this source tree, not the release artifact: ADR-0010",
             "compiles the instruments below out of a release, so the harness cannot drive the signed artifact.",
             "verify_bundle is what checks the artifact itself. Observations that rest on an instrument a release lacks:"]
    lines += [f"  {stage:<14} {' '.join(flags)}" for stage, flags in used.items()]
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------------------
# The declarations, against the tree.

HELPER_REFERENCE = r"\$\{?helpers\}?/([A-Za-z0-9._-]+)"


def _code(text: str) -> str:
    """The shell of a region: no comment lines, and no heredoc bodies but `SH`'s."""
    lines = text.split("\n")
    skipped = _heredoc_bodies(lines)
    return "\n".join(line for number, line in enumerate(lines)
                     if number not in skipped and not line.lstrip().startswith("#"))


def problems(repo: pathlib.Path, script_text: str, rows: list[Row], targets: dict[str, Target]) -> list[str]:
    found = []
    stages = known_stages(script_text)
    try:
        regions, shared = split_script(script_text, stages)
    except ValueError as error:
        return [str(error)]
    for stage in stages:
        if not any(row.stage == stage for row in rows):
            found.append(f"{stage}: no entry in stage-inputs.tsv")
    for row in rows:
        if row.stage not in ("*", "-") and row.stage not in stages:
            found.append(f"{row.stage}: declared in stage-inputs.tsv but not a stage")
        if row.kind in ("module", "own", "unexercised") and row.value not in targets:
            found.append(f"{row.value}: not a module of the package")
        if row.kind == "path" and not pattern_files(repo, row.value):
            found.append(f"{row.stage}: {row.value} matches no file, a silent hole")
    # Every module that ships is claimed — transitively by `module`, directly by `own` — or said to be exercised by none.
    claimed: set[str] = set()
    for row in rows:
        if row.kind == "module" and row.value in targets:
            claimed |= closure(targets, [row.value])
        elif row.kind == "own" and row.value in targets:
            claimed.add(row.value)
    unexercised = {row.value for row in rows if row.kind == "unexercised"}
    for name, target in sorted(targets.items()):
        if target.type == "test":
            continue
        if name not in claimed and name not in unexercised:
            found.append(f"{name}: claimed by no stage and not in the unexercised table")
        if name in claimed and name in unexercised:
            found.append(f"{name}: both claimed by a stage and in the unexercised table")
    # Every file a region uses from `Tools/e2e` is declared for it; one the shared code uses is declared for every stage.
    helpers = {p.stem if p.suffix == ".swift" else p.name: p.relative_to(repo).as_posix()
               for p in (repo / "Tools" / "e2e").iterdir() if p.is_file()}
    def declared(stage: str) -> set[str]:
        return {f for row in rows if row.stage in (stage, "*") and row.kind == "path" for f in pattern_files(repo, row.value)}
    for stage, text in list(regions.items()) + [("*", shared)]:
        if stage != "*" and stage not in stages:
            continue
        have = declared(stage) if stage != "*" else {f for row in rows if row.stage == "*" and row.kind == "path"
                                                     for f in pattern_files(repo, row.value)}
        for name in sorted(set(re.findall(HELPER_REFERENCE, _code(text)))):
            path = helpers.get(name)
            if path is None:
                found.append(f"{stage}: uses $helpers/{name}, which is no file in Tools/e2e")
            elif path not in have:
                found.append(f"{stage}: uses {path} and does not declare it")
    # A function one region defines is that region's alone: the shared code or another stage calling it would make an
    # edit there move the wrong key.
    for stage, text in regions.items():
        for name in re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\(\) \{", _code(text), re.MULTILINE):
            # Called as a command: first on its line, or after `;`, `&&`, `||`, `|`, `(`, `$(`, `then`, `do`, `else`,
            # `!`, `if`, `while`, `until`, or handed to `at_exit` — never a word inside a sentence.
            word = re.compile(rf"(?:^|[;&|(]|\$\(|\b(?:then|do|else|if|while|until|at_exit)\s|!\s)\s*{re.escape(name)}(?=\s|$|[;)|&])",
                              re.MULTILINE)
            for other, other_text in list(regions.items()) + [("the shared harness", shared)]:
                if other != stage and word.search(_code(other_text)):
                    found.append(f"{name}: defined in the {stage} region and used in {other}")
    return found


# ---------------------------------------------------------------------------------------------------------------------
# The table.

def _results(run_log: str) -> dict[str, str]:
    results: dict[str, str] = {}
    for line in run_log.split("\n"):
        fields = line.split("\t")
        if len(fields) == 3 and fields[0] == "RESULT":
            if fields[2] == "fail" or fields[1] not in results:
                results[fields[1]] = fields[2]
    return results


def table(plan: list[Decision], run_log: str | None) -> str:
    results = _results(run_log) if run_log is not None else {}
    out = ["end-to-end stages:"]
    for decision in plan:
        if decision.carried:
            status = "CARRIED"
        elif not decision.run:
            status = "NOT ASKED"
        elif run_log is None:
            status = "RUN"
        else:
            status = {"pass": "PASS", "fail": "FAIL"}.get(results.get(decision.stage, ""), "NO RESULT")
        out.append(f"  {decision.stage:<14} {status:<9} {decision.why}")
    if any(decision.carried for decision in plan):
        out.append("  CARRIED rows are a development-loop shortcut and are not valid for a merge or a release: "
                   "those need a fresh run of every stage (make e2e-full)")
    return "\n".join(out)


def _read_plan(path: str) -> list[Decision]:
    plan = []
    for line in pathlib.Path(path).read_text().split("\n"):
        if line:
            stage, verdict, why = line.split("\t", 2)
            plan.append(Decision(stage, verdict == "run", verdict == "carried", why))
    return plan


def _read_keys(path: str) -> dict[str, str]:
    return {fields[0]: fields[1] for fields in (line.split("\t") for line in pathlib.Path(path).read_text().split("\n")
                                                if line)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="e2e-inputs.py")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("keys")
    commands.add_parser("check")
    plan = commands.add_parser("plan")
    plan.add_argument("keys")
    plan.add_argument("status")
    plan.add_argument("host")
    plan.add_argument("os")
    plan.add_argument("--full", action="store_true")
    plan.add_argument("--asked", default="")
    plan.add_argument("--within", default="")
    settled = commands.add_parser("settle")
    settled.add_argument("before")
    settled.add_argument("after")
    shown = commands.add_parser("table")
    shown.add_argument("plan")
    shown.add_argument("run_log", nargs="?")
    gate = commands.add_parser("release-gate")
    gate.add_argument("status")
    commands.add_parser("tree")
    shown_status = commands.add_parser("show")
    shown_status.add_argument("status")
    shown_status.add_argument("build")
    shown_status.add_argument("--keys")
    shown_status.add_argument("--seen")
    mode = commands.add_parser("mode")
    mode.add_argument("build")
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("directory")
    since = commands.add_parser("since-build")
    since.add_argument("before")
    since.add_argument("now")
    args = parser.parse_args(argv)

    script_text = SCRIPT.read_text()
    if args.command == "keys":
        keys = stage_keys(REPO, script_text, parse_inputs(INPUTS.read_text()), targets_from_dump(dump_package(REPO)))
        for stage, key in keys.items():
            print(f"{stage}\t{key.value or NO_KEY}\t{key.why}")
        return 0
    if args.command == "check":
        found = problems(REPO, script_text, parse_inputs(INPUTS.read_text()), targets_from_dump(dump_package(REPO)))
        for problem in found:
            print(f"stage-inputs: {problem}", file=sys.stderr)
        return 1 if found else 0
    if args.command == "plan":
        keys = {stage: Key(None if value == NO_KEY else value, why)
                for stage, value, why in (line.split("\t", 2) for line in pathlib.Path(args.keys).read_text().split("\n")
                                          if line)}
        status = pathlib.Path(args.status)
        records = read_status(status.read_text()) if status.exists() else {}
        asked, within = tuple(args.asked.split()), tuple(args.within.split())
        unknown = sorted(set(within) - set(known_stages(script_text)))
        if unknown:
            print(f"e2e-inputs: no stage called {', '.join(unknown)}", file=sys.stderr)
            return 1
        for decision in decide(known_stages(script_text), keys, records, args.host, args.os, asked=asked, full=args.full,
                               within=within):
            verdict = "run" if decision.run else "carried" if decision.carried else "not-asked"
            print(f"{decision.stage}\t{verdict}\t{decision.why}")
        return 0
    if args.command == "settle":
        for stage, key in settle(_read_keys(args.before), _read_keys(args.after)).items():
            print(f"{stage}\t{key}")
        return 0
    if args.command == "table":
        print(table(_read_plan(args.plan), pathlib.Path(args.run_log).read_text() if args.run_log else None))
        return 0
    if args.command == "release-gate":
        status = pathlib.Path(args.status)
        tree = source_tree(REPO)
        refused = release_refusals(known_stages(script_text), read_status(status.read_text()) if status.exists() else {},
                                   tree)
        for line in refused:
            print(f"refused: {line}")
        if refused:
            print("a release needs a fresh pass of every stage, of a development bundle built from this clean source "
                  "tree: commit, then make e2e-full")
        else:
            print(f"end-to-end evidence: a fresh pass of every stage of source tree {tree}")
        print(release_gap(script_text, (REPO / "Tools" / "build-bundle.sh").read_text()))
        return 1 if refused else 0
    if args.command == "show":
        status = pathlib.Path(args.status)
        records = read_status(status.read_text()) if status.exists() else {}
        keys = None
        if args.keys and pathlib.Path(args.keys).exists() and pathlib.Path(args.keys).read_text().strip():
            keys = {stage: Key(None if value == NO_KEY else value, why)
                    for stage, value, why in (line.split("\t", 2) for line in pathlib.Path(args.keys).read_text().split("\n")
                                              if line)}
        seen = None
        if args.seen and pathlib.Path(args.seen).exists():
            fields = pathlib.Path(args.seen).read_text().strip().split("\t")
            seen = tuple(fields) if len(fields) >= 2 and all(fields[:2]) else None
        print(show(status_lines(known_stages(script_text), records, args.build, keys, seen), args.build, args.status))
        return 0
    if args.command == "tree":
        print(source_tree(REPO) or NO_KEY)
        return 0
    if args.command == "mode":
        print(build_mode(args.build))
        return 0
    if args.command == "snapshot":
        directory = pathlib.Path(args.directory)
        directory.mkdir(parents=True, exist_ok=True)
        keys = stage_keys(REPO, script_text, parse_inputs(INPUTS.read_text()), targets_from_dump(dump_package(REPO)))
        (directory / "keys").write_text("".join(f"{stage}\t{key.value or NO_KEY}\t{key.why}\n"
                                                for stage, key in keys.items()))
        (directory / "tree").write_text((source_tree(REPO) or NO_KEY) + "\n")
        return 0
    if args.command == "since-build":
        for stage, key, why in since_build(_read_keys(args.before), _read_keys(args.now)):
            print(f"{stage}\t{key}\t{why}")
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
