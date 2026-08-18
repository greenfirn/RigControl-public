[Get started](https://github.com/greenfirn/RigControl#get-started)

Alien...
![Screenshot-wp-alien.png](https://github.com/greenfirn/RigControl/blob/main/images/Screenshot-wp-alien.png)

Phantom Menace...
![phantom-menace](https://github.com/greenfirn/RigControl/blob/main/images/Screenshot-wp-phantom-menace.png)

X-Files...
![x-files](https://github.com/greenfirn/RigControl/blob/main/images/Screenshot-wp-x-files.png)

# RigControl Dashboard Theme Assets

* recommend leaving out of themes extra icon in: send cmd, themes, settings, and logout

## Asset sources (wallpapers & icons)

Reference list for sourcing dashboard theme assets — background wallpapers and toolbar icons.

> **Usage warning:** license terms below are a general guide, not legal advice, and sites change their terms over time. Always check the license on the *specific* file before shipping it in a public/commercial build, especially for anything used outside personal or internal tooling. "Free" on these sites usually means free to use, not free of all restrictions — attribution, no-resale, and no-trademark-use clauses are common. When in doubt, prefer CC0/public-domain assets, which carry no attribution or usage restrictions at all.

### Wallpaper / background art

| Site | License / usage notes |
|---|---|
| [Unsplash](https://unsplash.com) | Unsplash License — free for commercial and personal use, no attribution required. Cannot be sold unmodified as a standalone wallpaper/stock photo product, and cannot be used to imply endorsement by the photo's subject. Best default source — used for the built-in themes so far. |
| [Pexels](https://pexels.com) | Pexels License — similar terms to Unsplash, free commercial use, no attribution required. Same restriction on reselling unmodified photos, and identifiable people/private property/logos in a photo may still need separate permission for certain commercial uses. |
| [Pixabay](https://pixabay.com) | Pixabay Content License — free for most uses without attribution, but a small subset of content is marked "Editorial Use Only" (not for commercial use) — check the label on each item before use. |
| [Wikimedia Commons](https://commons.wikimedia.org) | Mixed licensing — public domain, CC0, and various CC-BY/CC-BY-SA licenses coexist on the same site. Attribution and share-alike requirements vary per file; the file page states the exact license. Check every file individually before use. |
| [Wallhaven](https://wallhaven.cc) | No consistent license — community-uploaded, provenance/ownership often unclear, and the site includes NSFW content (has a content filter, but verify it's set). Treat as personal-use only unless you can independently verify rights to a specific image; not recommended as a source for shipped/distributed themes. |
| [Pinterest](https://pinterest.com) | ⚠ Use with caution — see warning below. Handy for finding a specific look (fan art, movie stills, character themes) fast, but Pinterest is an aggregator: pins are re-uploads from other sites, original source/license is usually lost, and the same image is often re-hosted by multiple unrelated accounts. Treat as personal/internal-use only. |
| [Craiyon](https://craiyon.com) | Free AI image generator (ex-DALL-E mini) — good for a fully custom/original wallpaper when nothing off-the-shelf matches a theme. No copyright claim on the underlying image content itself in the US (AI-only output generally isn't copyrightable), but Craiyon's own terms grant them a broad license to the images too, and outputs can visually echo training-data material — treat as personal/internal-use only, same as Pinterest. |

> **Pinterest warning:** images on Pinterest are frequently copyrighted material (movie stills, official art, fan art, professional photography) reposted without the rights holder's permission, and the `i.pinimg.com` URL a pin resolves to isn't a stable, licensed asset — it can 404 if the pin is deleted, and it comes with no license information at all. Fine for a personal dashboard theme (like the Scooby-Doo one), but do not use Pinterest-sourced images in anything public, shared, or commercial — go back to Unsplash/Pexels/Pixabay/Wikimedia Commons for anything that leaves your own machine.

### Icons

| Site | License / usage notes |
|---|---|
| [SVG Repo](https://svgrepo.com) | Mixed per-icon licenses, but most are CC0/public domain or MIT — the license is shown on each icon's page. No attribution needed for CC0 items; verify per icon before assuming. |
| [Iconduck](https://iconduck.com) | Aggregator — license belongs to the original icon set (CC0, MIT, Apache, etc.), shown per icon. Filter by license before picking one to avoid pulling in an attribution-required set by accident. |
| [Icons8](https://icons8.com) | Free tier requires attribution (a linkback) or a paid plan to remove it. Attribution requirement is enforced per their terms — don't ship free-tier icons without a credit line or a license purchase. |
| [Flaticon](https://flaticon.com) | Free tier requires attribution per icon (they auto-generate the credit text) or a premium subscription to go attribution-free. Terms apply per-download, not per-account. |
| [Twemoji (via jsDelivr CDN)](https://cdn.jsdelivr.net/gh/twitter/twemoji@latest/assets/72x72/) | CC-BY 4.0 — free for commercial use but technically requires attribution (e.g. a credit in an about/credits page); no per-icon restrictions otherwise. Renders cleanly at small sizes like 16x16 toolbar buttons. |

For toolbar buttons specifically, prefer flat/simple icons (SVG Repo or Twemoji) — they hold up better at 16px than detailed/gradient styles from Icons8 or Flaticon. If RigCloud's dashboard is ever distributed outside personal/internal use, favor CC0 sources (SVG Repo, Iconduck-filtered-to-CC0) to avoid tracking attribution obligations across dozens of icons.
