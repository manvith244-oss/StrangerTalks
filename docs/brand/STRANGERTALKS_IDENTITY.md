# StrangerTalks Identity

Status: brand candidate prepared for product integration. Source admission and deployment are separate gates.

## Brand idea

StrangerTalks creates a temporary human space in which a real conversation can begin before either person knows who the other is. The identity should feel **unknown yet safe**: anonymous without coldness, contained without confinement, and open without demanding exposure.

## Master concept — Interrupted Safe Form

The master symbol is an asymmetric protective enclosure with one deliberate diagonal opening. The enclosure represents enough safety and containment for a conversation to exist. The single interruption represents voluntary entry, curiosity, and the fact that the space is never a closed identity container.

The form is intentionally not a literal speech bubble, door, person, mask, lock, shield, or `ST` monogram. Its slightly irregular squircle geometry also connects to the product's existing organic shape language without copying the Four Doors marks.

## Decision matrix

Scores are 1–10. The matrix was applied after monochrome rendering and 64/32/24/16 px inspection.

| Criterion | A — Moment of Contact | B — Interrupted Safe Form | C — Held Gap |
| --- | ---: | ---: | ---: |
| Simplicity | 8 | 9 | 8 |
| Recognizability | 7 | 9 | 8 |
| StrangerTalks relevance | 7 | 9 | 9 |
| Distinctiveness | 4 | 8 | 7 |
| Emotional meaning | 6 | 9 | 9 |
| Scalability | 8 | 9 | 8 |
| Longevity | 6 | 9 | 8 |
| Favicon performance | 8 | 9 | 8 |
| App-icon performance | 7 | 9 | 8 |
| Monochrome performance | 10 | 10 | 10 |
| Dark/light performance | 10 | 10 | 10 |
| Global/cultural neutrality | 9 | 9 | 8 |
| Avoidance of category clichés | 3 | 8 | 6 |
| Future animation potential | 9 | 9 | 9 |
| Stands without wordmark | 7 | 9 | 8 |
| **Total / 150** | **109** | **134** | **124** |

### Why A lost

The contact idea is strategically valid, but the rendered geometry collapses toward a generic X/bow-tie at small sizes. That violates the cliché filter and creates transport/logistics/math associations that are not worth fighting.

### Why C lost

The negative-space idea is strong and emotionally on-brand. In rendering, however, the paired masses repeatedly drift toward braces, pause-like forms, or paired organic objects. It communicates the concept well but is less ownable as a standalone mark.

## Geometry

- ViewBox: `0 0 96 96`.
- One continuous filled silhouette with one internal aperture and one diagonal opening.
- Slight asymmetry is intentional; do not "correct" it into a perfect circle or rounded square.
- The diagonal opening is part of the master geometry and must not be closed, widened casually, or converted into a tail.
- Raster artwork is not the source of truth. SVG is canonical.

## Wordmark

The companion wordmark is `StrangerTalks` in the project's existing Inter family, using a restrained semibold treatment. The prepared vector lockup converts the letters to outlines so the asset does not require bundled font files at render time.

Do not split "Stranger" and "Talks" into unrelated typefaces or colors. Do not turn the mark into an `S` or `ST` monogram.

## Color

The logo does not introduce a new palette. It uses the product's existing core neutrals:

- Carbon Deep: `#0b0d12`
- Carbon: `#12141c`
- Warm Cream: `#fffceb`

Contextual product accents remain product accents rather than being forced into the master mark. The existing warm accent `#dfb55f` may accompany the identity in UI composition, but it is not required inside the logo.

## Files

- `priv/static/images/strangertalks-mark.svg` — dark-on-light master mark.
- `priv/static/images/strangertalks-mark-reversed.svg` — warm-cream reversed mark.
- `priv/static/images/favicon.svg` — adaptive light/dark SVG favicon.
- Prepared lockups use the same geometry plus the existing Inter wordmark and should retain that exact pairing if admitted.

## Minimum sizes

The mark has been raster-inspected at 64, 32, 24, and 16 px. The opening and inner aperture remain distinguishable at 16 px.

Recommended production minimums:

- UI symbol: 16 px absolute minimum; 20–24 px preferred.
- Header lockup: 28 px mark height or larger.
- Standalone marketing mark: no practical upper limit because the source is vector.

## Clear space

Keep at least one quarter of the symbol's width clear on every side when it stands alone. In the horizontal lockup, preserve the authored symbol-to-wordmark spacing; do not squeeze the wordmark toward the opening.

## Dark and light use

- Use `strangertalks-mark.svg` on light surfaces.
- Use `strangertalks-mark-reversed.svg` on Carbon Deep, Carbon, or similarly dark surfaces.
- Do not add glow, shadow, gradient, texture, or 3D effects to rescue contrast.

## Accessibility

When a logo image is the only visible brand name, give it accessible text such as `alt="StrangerTalks"`. If the symbol sits next to a visible `StrangerTalks` wordmark, treat the symbol as decorative to avoid duplicated accessible names.

Do not encode essential product state or safety meaning through the logo alone.

## Misuse

Do not:

- close the opening;
- rotate the mark arbitrarily;
- mirror it;
- turn the opening into a speech-bubble tail;
- place an `S`, face, lock, shield, or door inside the aperture;
- stretch the symbol non-uniformly;
- recolor it with unrelated gradients;
- use a raster export as the editable master;
- change the aperture or opening independently between favicon, header, and app contexts.

## Motion principle

Animation is not required for initial admission. If motion is added later, the opening may ease from slightly narrower to its resting geometry once, or the enclosure may settle gently into place. No spinning, pulsing, bouncing, endless loops, or attention-seeking loading behavior. Respect reduced-motion preferences.

## Product integration law

Brand integration must remain presentation-only. It must not change matchmaking, Four Doors semantics, queue behavior, privacy, safety, conversation lifecycle, authentication, providers, or Agent behavior.

## Admission checklist

Before mainline admission:

1. Replace the legacy header `S` treatment with the reversed master mark plus the existing `StrangerTalks` wordmark on the current dark header.
2. Add the SVG favicon reference while retaining any required legacy fallback.
3. Launch the actual application and inspect desktop and mobile widths.
4. Verify no clipping, baseline issues, layout shift, broken URLs, or dark-background disappearance.
5. Run the repository-required `mix precommit` and relevant browser/static checks without weakening tests.
6. Rebase or merge onto fresh `origin/main`, rerun exact-candidate checks, and merge only after required gates are green.
7. Production deployment remains separately authorized.
