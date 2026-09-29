"""Generate the parity vectors the Swift port is measured against.

The Swift scheduler has to reproduce this kernel exactly, and "we ported it carefully" is not a
check. This writes every transition of a seeded walk — before state, grade, instant, after state —
so `MemorySchedulerParityTests` can assert bit-for-bit agreement rather than plausibility.

Deterministic: same seed, same file. Regenerate only when the kernel's numbers are meant to change,
and expect the Swift suite to go red when they do — that is the gate working.

    python3 Tools/fsrs/vectors.py > Tools/fsrs/parity-vectors.json

Instants are epoch seconds as whole numbers. Not ISO strings: two languages' parsers are one more
thing that can disagree, and the disagreement would read as a scheduler defect. Whole seconds also
keep `floor(elapsed / 86400)` exactly representable on both sides, so a day boundary is a boundary
in both and not a float accident.
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone

from fsrs6 import Card, Scheduler, VERSION

# The spec's own differential scope, so the port is checked over the range the kernel was.
RETENTIONS = (.80, .85, .90, .95, .97)
GRADES = (1, 2, 3, 4)
HISTORIES = 100
REVIEWS = 20
SEED = 20260929

# One minute to a year, in whole seconds. The short-term branch is below 24 hours and the long-term
# branch above it, so both sides of that boundary have to be walked — including the boundary itself.
DELAYS = (60, 600, 3600, 86_399, 86_400, 86_401, 172_800, 604_800, 2_592_000, 31_536_000)


def transitions():
    rng = random.Random(SEED)
    start = datetime(2026, 9, 29, tzinfo=timezone.utc)
    for history in range(HISTORIES):
        retention = RETENTIONS[history % len(RETENTIONS)]
        scheduler = Scheduler(retention=retention)
        card = Card()
        now = start + timedelta(seconds=history * 97)
        for _ in range(REVIEWS):
            grade = rng.choice(GRADES)
            before = card
            card = scheduler.review(card, grade, now)
            yield {
                'retention': retention,
                'grade': grade,
                'now': now.timestamp(),
                'before': state(before),
                'after': state(card),
            }
            now = now + timedelta(seconds=rng.choice(DELAYS))


def state(card):
    return {
        'stability': card.stability,
        'difficulty': card.difficulty,
        'phase': card.phase,
        'lastReview': card.last_review.timestamp() if card.last_review else None,
        'due': card.due.timestamp() if card.due else None,
    }


def main():
    rows = list(transitions())
    # Compact: a generated fixture is never read by eye, and a diff of it is unreadable at any
    # indentation. One transition per line keeps a regeneration's diff countable all the same.
    sys.stdout.write('{"version": %s, "seed": %d, "generator": "Tools/fsrs/vectors.py",\n'
                     ' "transitions": [\n' % (json.dumps(VERSION), SEED))
    for index, row in enumerate(rows):
        sys.stdout.write('  %s%s\n' % (json.dumps(row, sort_keys=True),
                                       ',' if index < len(rows) - 1 else ''))
    sys.stdout.write(' ]}')
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
