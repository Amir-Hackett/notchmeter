# site

The marketing site: static pages, two stylesheets, no build step and no dependencies.

```
site/
  index.html            the landing page
  pricing.html          Free forever, pay what you want
  privacy.html          the privacy policy
  terms.html            the terms, with the vendors' own words
  style.css             the whole design
  landing.css           what the usage-tracker pages add, built from style.css's tokens
  usage-trackers/       the hub of the usage-tracker pages, one folder per page beside it
  sitemap.xml           every page at its canonical URL
  robots.txt            allows everything and names the sitemap
  img/                  copied from ../docs/media by scripts/site-assets.sh
```

Open `index.html` in a browser to look at it, or serve the folder:

```bash
python3 -m http.server -d site 8000
```

## Deploying

It is deployed by Vercel from `main` with `site` as the root directory, so a merge to `main` is a deploy (the pull request gets a preview). It is plain static files, so anything else would host it too; two that need no configuration:

- **GitHub Pages** — Settings › Pages › Deploy from a branch, folder `/site`.
- **Vercel** — root directory `site`, output directory `.`, no build command; that is the live configuration.
- **Netlify** — publish directory `site` (relative to the repository root), no build command.

The site is at https://www.notchmeter.com; both pages carry that host in their canonical and share URLs.

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

## The usage-tracker pages

`usage-trackers/` is a hub and the nine folders beside it are one page each, one per tool or question people search
for (`claude-code-usage-tracker/`, `claude-code-rate-limit-reset/`, `claude-code-opus-weekly-limit/`,
`codex-cli-usage-tracker/`, `cursor-usage-tracker/`, `copilot-usage-tracker/`, `gemini-cli-quota-tracker/`,
`antigravity-usage-tracker/`, `ai-usage-tracker-mac/`). Each is a folder with an `index.html` so its URL is the
folder on any static host, with no rewrite rule: `https://www.notchmeter.com/claude-code-usage-tracker/`. They share
`landing.css`, loaded after `style.css` and built only from its tokens, so nothing in it can change the other pages.

Each page says what Notchmeter shows for that tool, where every figure comes from (a table naming the endpoint or
file, the login it uses and what the card labels it), what the Advice strip says about it, and four to six questions
with answers. Nothing on a page goes past `docs/accuracy.md`, `docs/features.md`, `docs/hooks.md` and the code; a
rule is quoted with the section it lives in, and the page links that section rather than restating a figure that
could drift. The site is dark only, by decision (the head of `style.css`: the product lives in a black notch), and
these pages declare it with `<meta name="color-scheme" content="dark">` so that what the browser draws for itself,
the scrollbar under the sources table or a code block at phone width, follows the palette rather than the OS's
light scheme; without it a light-mode Windows or Linux reader gets a white scrollbar track across a dark card.
Each page carries a canonical URL, Open Graph tags and two JSON-LD blocks for search engines: a
`SoftwareApplication` (this app, free, macOS 15+, with aliases that are its own name and never another product's) and
a `FAQPage` that repeats the visible questions and answers word for word. No page names a competitor, and none runs a
script.

`sitemap.xml` lists every page at its canonical URL and `robots.txt` allows everything and names the sitemap. To add
a page: copy a folder, change its head, add it to the hub, to `sitemap.xml` and to `SiteLandingPages` in
`Tests/NotchmeterTests/SiteLandingPagesTests.swift`, which holds the head, the JSON-LD against the visible FAQ, the
links, the images, the heading order and the no-script rule.
