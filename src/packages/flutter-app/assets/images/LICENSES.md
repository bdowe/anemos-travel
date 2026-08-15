# Bundled image licenses

Every raster shipped in `assets/images/` and `assets/splash/`, with where it
came from and what the license requires of us. Add a row here when you add an
image — an asset whose provenance nobody recorded is the problem this file
exists to prevent.

Destination suggestion photos have their own generated record:
[`destinations/CREDITS.md`](destinations/CREDITS.md).

## Brand art — generated in-repo

| File | Source | License |
| --- | --- | --- |
| `anemos_logo.png`, `anemos_mark.png`, `anemos_mark_light.png` | Rendered from `docs/branding/*.svg` via `scripts/brand-render.sh` | Golden Tempo LLC, all rights reserved |
| `../splash/mark_light_4x.png`, `../splash/mark_light_android12.png` | Same render pipeline | Golden Tempo LLC, all rights reserved |

Never hand-edit these — edit the SVGs and re-render (`docs/branding/README.md`).

## Third-party

| File | Source | Author | License | Attribution required? |
| --- | --- | --- | --- | --- |
| `hero_santorini.jpg` | Unsplash — **specific photo not recorded** (see note) | Unknown | [Unsplash License](https://unsplash.com/license) | No |
| `google_g_logo.png` | Google's "G" mark, added for Sign in with Google (`specs/google-sso`, commit `09b4de1`) — exact download URL not recorded | Google LLC | Google trademark, used under its [sign-in branding guidelines](https://developers.google.com/identity/branding-guidelines) | Trademark, not copyright: must be used unmodified and only on the sign-in button |

### Note on `hero_santorini.jpg`

Added in commit `334298c` ("redesign home hero with destination photo"), whose
message records only that the photo is "Unsplash-licensed". The photo ID,
photographer and URL were never captured, and the image carries no EXIF
credit.

This is a **provenance gap, not a compliance one**: the Unsplash License grants
irrevocable, worldwide, non-exclusive rights to use the photo commercially with
no permission and no attribution required, so nothing is owed to anyone. What
we cannot currently do is *prove* the chain if asked.

To close it, drop the Unsplash photo URL into the table above. Until then,
prefer sourcing new photography the way `destinations/` does — through
`scripts/fetch-destination-photos.py`, which records author and license from
the source API at generation time and refuses share-alike licenses outright.
