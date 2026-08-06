# Product

## Register

product

## Users

Solo lifters running structured strength programs, plus a small closed circle of
training partners ("companions") who pair via QR code and watch each other's
progress. The primary context is the gym floor mid-workout: phone in one hand,
90 seconds of rest between sets, sweaty fingers, glancing rather than reading.
The secondary context is at home after training, reviewing the month and
scrolling PR history at leisure.

The job to be done: log the sets I just did in under thirty seconds, and tell me
whether I am actually getting stronger.

## Product Purpose

Arc turns a training log into a progress instrument. Anyone can record weight and
reps; Arc's reason to exist is the derived layer on top — estimated 1RM per lift,
PR detection at save time, per-muscle-group session history, and a strength curve
that answers "am I moving" without the user doing arithmetic.

Success looks like: logging is fast enough that it never competes with the
workout, and the progress view is convincing enough that the user opens Arc on
rest days.

## Brand Personality

Bold, athletic, factual. The voice is a training partner who counts your reps
and does not compliment you. Volt-green energy against a quiet neutral field;
numerals carry the personality, not decoration.

Emotional goal: earned confidence. The peak moment is saving a workout that
contains a PR — that moment should feel like a win, not a database write.

Never encouraging-coach ("Great job! 🎉"), never clinical ("Session persisted").

## Anti-references

- **Corporate SaaS dashboards** (Linear, Notion, admin consoles). Arc is a
  personal athletic instrument, not a metrics console. No sidebar chrome, no KPI
  tile grids, no gray-card sameness.
- **Apple Fitness and stock Material.** Whatever the platform hands you by
  default — rings, unmodified components, no point of view. Arc's design is a
  deliberate direction and should never dissolve into system defaults.
- Corollary: resist the reflex to solve every layout with another identical
  white rounded card. That is the failure mode both anti-references share.

## Design Principles

1. **The numbers are the interface.** Weight, reps, and 1RM are the content.
   Typography and layout exist to make numerals scannable at arm's length;
   chrome that competes with a number loses.
2. **Logging beats browsing.** The primary action is always reachable in one
   thumb-tap from any screen. Any friction added to the log flow must buy
   something the user asked for.
3. **Earn the accent.** Volt is a signal, not a decoration. It marks the primary
   action, today, and a new record. When it appears everywhere it means nothing.
4. **Show the trend, not the trophy.** Progress is a direction over weeks. Prefer
   a real axis with real units over a hero number with a decorative sparkline.
5. **Built for one hand and bad light.** Gym-floor ergonomics beat visual density.
   If a control is hard to hit with a sweaty thumb, it is broken regardless of
   how it looks.

## Accessibility & Inclusion

Target **WCAG 2.2 AA**.

- 4.5:1 contrast for body text, 3:1 for large text and meaningful UI boundaries.
- Minimum 44×44 logical-pixel touch targets on every interactive control.
- Every icon-only control carries a screen-reader label; charts expose a text
  summary. TalkBack and VoiceOver must be able to complete the log-workout flow.
- Layout survives system text scaling to 200% without clipping numerals.
- Muscle-group identity (Push / Pull / Legs / Core) must never be conveyed by
  color alone — red/green sits directly on the most common color-vision
  deficiency.
- Honor reduced-motion; press-scale and chart animation are enhancements.
