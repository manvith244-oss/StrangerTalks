# StrangerTalks Identity

Status: full-color brand candidate integrated on the brand branch. Main admission and deployment remain separate gates.

## Brand idea

StrangerTalks creates a temporary human space in which a real conversation can begin before either person knows who the other is. The identity should feel **unknown yet safe**: anonymous without coldness, contained without confinement, and open without demanding exposure.

## Master concept — Interrupted Safe Form

The master symbol is an asymmetric protective enclosure with one deliberate diagonal opening. The enclosure represents enough safety and containment for a conversation to exist. The interruption represents voluntary entry, curiosity, and impermanence: a StrangerTalks conversation is a space people enter, not an identity container that owns them.

The form is intentionally not a literal speech bubble, door, person, mask, lock, shield, heart, `S`, or `ST` monogram.

## Why this territory won

Three territories were explored and rendered at small sizes.

| Criterion summary | A — Moment of Contact | B — Interrupted Safe Form | C — Held Gap |
| --- | ---: | ---: | ---: |
| Total / 150 | 109 | **134** | 124 |

A collapsed toward an X/bow-tie. C repeatedly drifted toward braces, pause-like forms, or paired objects. B remained readable at favicon scale, avoided category clichés, and carried the strongest StrangerTalks-specific meaning.

## Geometry

- ViewBox: `0 0 96 96`.
- One asymmetric enclosure, one internal aperture, one diagonal opening.
- Slight asymmetry is intentional; do not normalize it into a perfect circle or rounded square.
- Do not close, rotate, mirror, widen, or convert the opening into a speech-bubble tail.
- SVG geometry is canonical. Raster exports are presentation derivatives only.

## Color is part of the identity

Color is not optional decoration in the default StrangerTalks expression. The canonical symbol uses a restrained emotional spectrum rather than a generic rainbow.

- **Deep Violet `#5B3DF6`** — depth, trust, introspection.
- **Warm Coral `#FF6B6B`** — human warmth and connection.
- **Calm Teal `#14B8A6`** — openness, ease, conversational safety.
- **Soft Amber `#F4B942`** — hope, guidance, forward movement.

Supporting neutrals:

- **Midnight `#0F1024`** — light-background wordmark and compact icon tile.
- **Warm Neutral `#FFFBF2`** — dark-background wordmark.

The colors should read as one emotional journey through a conversation, not four unrelated badges. Do not assign them to demographic groups, user identities, Doors, safety states, or psychological diagnoses.

### Color psychology principle

The palette is intended to influence tone subtly without making manipulative or medical claims. Violet leads with depth; coral adds humanity; teal cools the experience toward ease; amber resolves it with optimism. The full-color mark is the default brand expression because StrangerTalks is a human conversation product, not a sterile utility.

The geometry must still remain identifiable in monochrome for accessibility, printing, legal, and technically constrained contexts.

## Wordmark

The companion wordmark is exactly `StrangerTalks`. Keep it neutral so the colorful symbol carries the emotional load without turning the full lockup into visual noise.

- Light surfaces: Midnight wordmark.
- Dark surfaces: Warm Neutral wordmark.
- Do not split `Stranger` and `Talks` into different colors or typefaces.

Standalone SVG lockup assets are retained for marketing/export use. In the application shell, the canonical symbol is rendered inline beside the visible HTML `StrangerTalks` wordmark so the existing no-`img` presentation invariant remains intact. The product typography continues to inherit the existing Inter/system stack.

## Canonical assets

- `priv/static/images/strangertalks-mark.svg` — full-color master symbol.
- `priv/static/images/strangertalks-mark-reversed.svg` — full-color symbol for dark contexts.
- `priv/static/images/strangertalks-lockup.svg` — full-color symbol + Midnight wordmark for light/export surfaces.
- `priv/static/images/strangertalks-lockup-reversed.svg` — full-color symbol + Warm Neutral wordmark for dark/export surfaces.
- `priv/static/images/favicon.svg` — full-color symbol on a Midnight rounded tile.
- `priv/static/index.html` — inline full-color header symbol plus visible `StrangerTalks` wordmark; no `<img>` dependency.

## Minimum sizes

The master geometry was inspected at 64, 32, 24, and 16 px before color was introduced. The opening and aperture remain distinguishable at 16 px.

Recommended minimums:

- UI symbol: 16 px absolute minimum; 20–24 px preferred.
- Header symbol: 28 px preferred.
- Standalone marketing mark: vector source may scale freely.

At tiny sizes, recognizability outranks preserving every subtle gradient transition.

## Clear space

Keep at least one quarter of the symbol width clear on every side when it stands alone. In a horizontal lockup, preserve the authored symbol-to-wordmark spacing and never squeeze text into the diagonal opening.

## Dark and light use

- Use `strangertalks-lockup.svg` on light export/marketing surfaces.
- Use `strangertalks-lockup-reversed.svg` on Carbon Deep, Midnight, or similarly dark export/marketing surfaces.
- The live dark app header uses the same full-color symbol inline with a neutral visible wordmark.
- The symbol remains full-color in both contexts.
- Do not add glow, drop shadow, bevels, glass effects, texture, or 3D styling to compensate for poor placement.

## Accessibility

In the application header, the inline symbol is decorative (`aria-hidden="true"`) because the visible `StrangerTalks` wordmark already provides the brand name. When a logo image is the only visible brand name in another context, provide equivalent accessible text.

The logo must never be the sole carrier of a safety, privacy, consent, error, or product-state message. Brand color is emotional identity, not status color.

## Misuse

Do not:

- close or reshape the opening;
- rotate or mirror the symbol;
- place an `S`, face, lock, shield, heart, or door inside it;
- stretch it non-uniformly;
- recolor it with unrelated gradients or a generic rainbow;
- animate it continuously;
- use different symbol geometry for favicon, app, header, and marketing contexts;
- use a raster export as the editable master.

## Motion principle

Motion is optional. If introduced later, the opening may settle gently into its resting geometry once. No spinning, pulsing, bouncing, endless loops, or loading-spinner behavior. Respect reduced-motion preferences.

## Product integration law

Brand integration is presentation-only. It must not change matchmaking, Four Doors semantics, queues, privacy, safety, conversation lifecycle, authentication, provider boundaries, or Agent behavior.

## Admission checklist

Before mainline admission:

1. The current dark app header uses the inline full-color canonical symbol beside the visible `StrangerTalks` wordmark and preserves the shell no-`img` invariant.
2. The app references the full-color SVG favicon.
3. Static tests prove the legacy placeholder `S` is gone, the inline header contains the canonical colors, and export assets remain self-contained SVGs.
4. Real Chromium desktop and mobile verification proves the identity renders without clipping, overflow, broken URLs, or layout shift.
5. Run repository-required `mix precommit` and diff/clean-tree checks without weakening tests.
6. Reconcile with fresh `origin/main`, rerun exact-candidate evidence, and admit only after the required gates are green.
7. Production deployment remains separately authorized.
