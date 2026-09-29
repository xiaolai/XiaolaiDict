"""Executable FSRS-6 specification for XiaolaiDict; not linked into the app.

Numerical contract: py-fsrs commit 9446cb06605c597a063aeee49f7d188d42e34dc2,
one 10-minute learning/relearning step, no fuzz, whole elapsed days, ties-to-even
interval rounding. Formulas/parameters derived from the MIT-licensed py-fsrs
project; see UPSTREAM-LICENSE.txt. Product enrollment/transactions are external.
"""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from math import exp, isfinite


WEIGHTS = (
    .212, 1.2931, 2.3065, 8.2956, 6.4133, .8334, 3.0194,
    .001, 1.8722, .1666, .796, 1.4835, .0614, .2629,
    1.6483, .6014, 1.8729, .5425, .0912, .0658, .1542,
)
LOWER = (.001,.001,.001,.001,1,.001,.001,.001,0,0,.001,.001,.001,.001,0,0,1,0,0,0,.1)
UPPER = (100,100,100,100,10,4,4,.75,4.5,.8,3.5,5,.25,.9,4,1,6,2,2,.8,.8)
VERSION = 'fsrs6-py9446cb0-one10m-no-fuzz-v1'


@dataclass(frozen=True)
class Card:
    stability: float | None = None
    difficulty: float | None = None
    phase: str = 'new'
    last_review: datetime | None = None
    due: datetime | None = None


def utc(value):
    if not isinstance(value,datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError('A timezone-aware timestamp is required')
    return value.astimezone(timezone.utc)


def positive(value):
    if not isinstance(value,(int,float)) or isinstance(value,bool) or not isfinite(value) or value <= 0:
        raise ValueError('Expected a finite positive number')


class Scheduler:
    def __init__(self, retention=.9, maximum_days=36500, weights=WEIGHTS):
        positive(retention)
        if retention >= 1:
            raise ValueError('Retention must be strictly between zero and one')
        if type(maximum_days) is not int or maximum_days < 1:
            raise ValueError('Maximum interval must be a positive integer')
        if len(weights) != 21 or any(
            not isfinite(v) or not lo <= v <= hi
            for v,lo,hi in zip(weights,LOWER,UPPER)
        ):
            raise ValueError('Invalid FSRS-6 parameter vector')
        self.w = tuple(weights)
        self.retention = retention
        self.maximum_days = maximum_days
        self.decay = -self.w[20]
        self.factor = .9 ** (1 / self.decay) - 1

    def recall(self, elapsed_days, stability):
        """Continuous mathematical curve; pass whole elapsed days for scheduler parity."""
        positive(stability)
        if not isfinite(elapsed_days) or elapsed_days < 0:
            raise ValueError('Elapsed time must be finite and nonnegative')
        return (1 + self.factor * elapsed_days / stability) ** self.decay

    def interval(self, stability, retention=None):
        positive(stability)
        target = self.retention if retention is None else retention
        positive(target)
        if target >= 1:
            raise ValueError('Retention must be below one')
        return stability / self.factor * (target ** (1 / self.decay) - 1)

    def scheduled_days(self, stability):
        return min(self.maximum_days,max(1,round(self.interval(stability))))

    def initial_difficulty(self, grade):
        # Raw value: the mean-reversion anchor must NOT be clamped first.
        return self.w[4] - exp(self.w[5] * (grade - 1)) + 1

    def review(self, card, grade, now):
        """Pure grade transition. Eligibility/idempotency are the caller's contract."""
        if type(grade) is not int or grade not in (1,2,3,4):
            raise ValueError('Grade must be 1, 2, 3, or 4')
        now = utc(now)
        w = self.w
        if card.phase == 'new':
            if any(v is not None for v in (card.stability,card.difficulty,card.last_review,card.due)):
                raise ValueError('New card must have no invented memory state')
            stability = max(.001,w[grade-1])
            difficulty = min(10,max(1,self.initial_difficulty(grade)))
            phase = 'learning'
        else:
            if card.phase not in ('learning','review','relearning'):
                raise ValueError('Unknown card phase')
            positive(card.stability)
            if card.stability < .001 or card.difficulty is None or not isfinite(card.difficulty) or not 1 <= card.difficulty <= 10:
                raise ValueError('Invalid memory state')
            previous_time = utc(card.last_review)
            utc(card.due)
            if now < previous_time:
                raise ValueError('Clock rollback: review precedes the previous review')
            days = (now - previous_time).days
            s, d = card.stability,card.difficulty
            if days == 0:
                gain = exp(w[17] * (grade - 3 + w[18])) * s ** -w[19]
                stability = s * (max(1,gain) if grade >= 2 else gain)
            else:
                r = self.recall(days,s)
                if grade == 1:
                    after_lapse = w[11] * d ** -w[12] * ((s+1) ** w[13]-1) * exp(w[14]*(1-r))
                    ceiling = s / exp(w[17]*w[18])
                    stability = min(after_lapse,ceiling)
                else:
                    multiplier = w[15] if grade == 2 else w[16] if grade == 4 else 1
                    stability = s * (1 + exp(w[8])*(11-d)*s**-w[9]*(exp(w[10]*(1-r))-1)*multiplier)
            stability = max(.001,stability)
            damped = d - w[6]*(grade-3)*(10-d)/9
            difficulty = min(10,max(1,w[7]*self.initial_difficulty(4)+(1-w[7])*damped))
            phase = card.phase

        if phase in ('learning','relearning'):
            if grade == 1:
                delay = timedelta(minutes=10)
            elif grade == 2:
                delay = timedelta(minutes=15)
            else:
                phase = 'review'
                delay = timedelta(days=self.scheduled_days(stability))
        elif grade == 1:
            phase = 'relearning'
            delay = timedelta(minutes=10)
        else:
            delay = timedelta(days=self.scheduled_days(stability))
        if not isfinite(stability) or not isfinite(difficulty):
            raise ValueError('Nonfinite calculated state')
        return Card(stability,difficulty,phase,now,now+delay)


if __name__ == '__main__':
    scheduler = Scheduler()
    now = datetime(2026,9,23,tzinfo=timezone.utc)
    card = Card()
    print('grade  stability  difficulty  next interval  phase')
    for grade in (3,3,3,1,3,3):
        card = scheduler.review(card,grade,now)
        print(f'{grade:5}  {card.stability:9.4f}  {card.difficulty:10.4f}  {str(card.due-now):>13}  {card.phase}')
        now = card.due
