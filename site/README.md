# site

The marketing site: static pages, one stylesheet, no build step and no dependencies.

```
site/
  index.html     the landing page
  pricing.html   Free, pay what you want, and why
  privacy.html   the privacy policy
  terms.html     the terms of use
  guides/        index.html and one page per guide
  sitemap.xml    every page at its canonical URL
  robots.txt     allows everything and names the sitemap
  style.css      the whole design, dark and light
  img/           copied from ../docs/media by scripts/site-assets.sh
```

Open `index.html` in a browser to look at it, or serve the folder:

```bash
python3 -m http.server -d site 8000
```

## The guides

Each guide in `guides/` answers one question people search for at the moment it matters (why the cost estimate
does not match the bill, whether a window lasts to its reset, why a notification never came), and each carries the
date it was written, *Tested on Notchmeter* with the version it was checked against, and a Sources list with the
date every outside page was read. A guide says nothing the app and its documents cannot back: its figures and rules
are quoted from `docs/accuracy.md`, `docs/features.md`, `docs/hooks.md` and the code, and it links to the rule rather
than restating a number that could drift. When a rule changes, the guide quoting it changes in the same pull request.

To add one: copy an existing guide (its head carries the title, description, canonical URL, Open Graph tags and the
published date), add a card to `guides/index.html` and a line to `sitemap.xml`. `ReleasePackagingTests` (`SiteGuides`)
fails when a guide is missing its stamp, its date, its canonical URL or its sitemap entry, when the index and the
folder disagree, or when any page loads a script or a tracker. The comparison guide's star counts are dated
2026-09-24; refresh them with `gh api repos/<owner>/<repo> --jq .stargazers_count` and change the date with them.

## Light and dark

Dark by default, since the product lives in a black notch. A reader whose Mac asks for light pages gets a light page
(`prefers-color-scheme: light`), with every pair of colours measured at 4.5:1 or better for text; the pictures keep
their dark frame in both, so the panel is never shown floating on white. There is no toggle, because a toggle would
need browser storage and the privacy page promises none.

## Deploying

It is deployed by Vercel from `main` with `site` as the root directory, so a merge to `main` is a deploy (the pull request gets a preview). It is plain static files, so anything else would host it too; two that need no configuration:

- **GitHub Pages** — Settings › Pages › Deploy from a branch, folder `/site`.
- **Vercel** — root directory `site`, output directory `.`, no build command; that is the live configuration.
- **Netlify** — publish directory `site` (relative to the repository root), no build command.

The site is at https://www.notchmeter.com; every page carries that host in its canonical and share URLs, and
`sitemap.xml` lists each at the canonical URL it names.

## Keeping the pictures current

The images are the app's own renders, not screenshots. Regenerate them and copy them across whenever the UI changes:

```bash
scripts/build.sh
.build/release/Notchmeter --render-assets docs/media
scripts/site-assets.sh
```

## What the pages promise

The download button links at the `Notchmeter.dmg` of the latest GitHub release, so it serves whichever release is
current (v0.1.0 since 2026-09-05), and the Homebrew line names the tap. The figures on the pages (energy, resident
size, poll cadence, what is and is not read) are the README's; change them there first and here second, because a
number on this page that the README cannot back is the one defect the README's own energy section exists to rule out.

The Install section says, for everyone, that Notchmeter is a Mac app with no Windows or Linux version, and links
[the Windows issue](https://github.com/Amir-Hackett/notchmeter/issues/32), which is where demand for one goes. The
one script on the site (the foot of `index.html`) checks `navigator.userAgentData.platform`, or the user-agent
string, and on Windows shows that notice with the issue as the headline button and the DMG demoted to the ghost
one, hides the DMG row and the static line, and rewrites the hero's platform line to say there is no Windows or
Linux version; the check runs in the browser and the result goes nowhere, so the page still makes no request and
sets nothing.
