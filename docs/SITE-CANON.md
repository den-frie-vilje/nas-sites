# Site canon

The cross-site patterns every den-frie-vilje docker-hosted site follows. Each
pattern has an identifier, a short statement, a reference implementation, and a
probe: a check that measures conformance in the repository or on the live
origin. `tools/check-canon.sh` runs every probe against every site in
`tools/canon-sites.txt` and prints the fleet scorecard. Conformance is
measured, not remembered.

A pattern enters this file when it has been proven on at least one site and
declared canonical. Porting a pattern across the fleet is a campaign: one
tracking issue in this repository with a checkbox per site, one agent per site,
staging-first, probes verifying each port. The campaign protocol lives with the
org's coordination documents; this file is the technical register.

Status values: **adopted** (probes enforced fleet-wide) and **proposed**
(reference implementation exists, fleet rollout pending).

## SC-1: fail-closed robots route, serving a readable noindex — adopted

robots.txt is a prerendered route, never a static file. Only the literal
`PUBLIC_ALLOW_INDEXING === 'true'`, imported from `$env/static/public`, bakes
the production variant with the sitemap advert; any other value, including an
unset variable, bakes the staging variant with no advert. The route deploys
atomically with the image, so it is the primary strap; infra-side straps rot.

**The staging variant allows crawling.** It carries `Allow: /`, disallows only
paths that are genuinely sensitive (`/admin/`), advertises no sitemap, and
relies on the `X-Robots-Tag: noindex` that SC-3 already requires on every
staging response. Ideally `noindex, nofollow, noarchive, nosnippet`; a bare
`noindex` is a WARN.

**Why this clause changed, on 2026-08-17.** It used to require a blanket
`Disallow: /` on staging, and that is the combination that cannot deindex
anything. Google's own documentation is explicit:

> "For the `noindex` rule to be effective, the page or resource must not be
> blocked by a robots.txt file, and it has to be otherwise accessible to the
> crawler. If the page is blocked by a robots.txt file or the crawler can't
> access the page, the crawler will never see the `noindex` rule, and the page
> can still appear in search results, for example if other pages link to it."

So a Disallow-all staging site serves a `noindex` header no compliant crawler
will ever read, and a single inbound link is enough to put the URL in an index
without a snippet. Four of the five sites were in exactly that state and the
scorecard called them PASS, because the clause measured the intention rather
than the effect. `gosscounselling.co.uk` was the only site doing it correctly
and was the only FAIL.

**The tradeoff, accepted deliberately.** Allowing the crawl means compliant
crawlers fetch staging content, so it can reach caches and corpora belonging to
parties that honour robots.txt but not `noindex`. Blocking the crawl does not
prevent that either, since anything ignoring `noindex` tends to ignore
robots.txt too; it only prevents the well-behaved from reading the instruction
we most want them to obey. `noarchive` and `nosnippet` narrow the residue. If a
staging site ever holds material that must not be fetched at all, the answer is
authentication, not a robots directive.

Reference implementation: `gosscounselling.co.uk`.

Probe, repository: `src/routes/robots.txt/+server.ts` exists, contains
`=== 'true'` and imports `$env/static/public`.
Probe, staging origin: `/robots.txt` advertises no `Sitemap:`, does not carry a
blanket `Disallow: /`, and the origin serves an `X-Robots-Tag` containing
`noindex`. WARN when that header lacks `noarchive` or `nosnippet`; FAIL when a
crawlable origin serves no `noindex` at all, which is the genuinely indexable
combination.

## SC-2: per-mode env contract — adopted

Committed `.env.staging` and `.env.production` files carry the build-time
public config: `PUBLIC_ALLOW_INDEXING` (true only in production) and
`PUBLIC_SITE_URL` where the site's seo wiring uses it. `PUBLIC_*` values only,
never secrets. Consumers import `$env/static/public` only; `$env/dynamic/public`
silently masks a missing declaration in prerendered output. The build selects
the mode explicitly and never writes `pnpm build -- --mode` (the bare `--`
swallows the mode and silently builds production). `.dockerignore` re-includes
the committed env files.

Probe, repository: both env files exist; staging declares
`PUBLIC_ALLOW_INDEXING=false`, production `=true`; no `build -- --mode` in
`package.json` or `deploy/Dockerfile`.

## SC-3: staging noindex header backstop — adopted

`deploy/Caddyfile.staging` sets `X-Robots-Tag "noindex, nofollow"` on all
responses. Backstop only; SC-1 is the primary strap.

Probe, repository: the directive is present in `deploy/Caddyfile.staging`.
Probe, staging origin: the header is served on `/`.

## SC-4: git-sha meta — adopted

Every deployed page names its own commit: CI passes
`PUBLIC_GIT_SHA=${{ github.sha }}` as a build-arg, the Dockerfile exports it,
and `src/app.html` carries `<meta name="git-sha" …>`. Pull-only CD means CI
never confirms the rollout; the live page is the only trustworthy statement of
what is deployed. Verify deploys against the origin host, not the CDN apex.

Probe, repository: `src/app.html` contains `name="git-sha"`.
Probe, staging origin: the page serves a non-empty git-sha meta.

## SC-5: reusable workflow pinned by the newest tag — adopted

Site workflows call `build-and-sign.yml` pinned to a release tag of this
repository, not `@main`. A floating branch reference is unreviewable and is a
weak point for a workflow that signs images. `v1` is the first tag; the tag
moves only for deliberate, reviewable releases.

A tag pin is only safe if something measures its freshness, so the probe
compares each pin against the newest tag rather than merely checking that a
tag is used. A pin left behind a later release shows as WARN, which is the
signal to open a bump. If that bump traffic ever becomes real work, a
self-hosted Renovate delivering bump PRs is the documented next step.

**Changing a pin changes what the signature says.** The Fulcio SAN on a
keyless signature is `build-and-sign.yml` at the ref the *caller* selected,
not the calling repository or its branch. So a pin is not only a supply-chain
choice, it is the signing identity, and the NAS agent verifies against a regex
of identities it will accept. On 2026-08-05 the first tag pins moved two sites
to `refs/tags/v1`, the agent accepted `refs/heads/(main|staging)` only, and it
failed closed on correctly signed images until the agent was widened (#36).
The lockstep this repository already documents for the cosign *version* applies
to the *identity* too.

Probe, repository: every `uses:` of `build-and-sign.yml` references the newest
tag on this repository, and the identity that pin produces is accepted by
`COSIGN_IDENTITY_REGEX`, read out of `nas-agent/deploy-agent.sh`. A pin the
agent would reject is FAIL, because merging it stops that site deploying. A
tag that is not the newest is WARN; a branch reference is FAIL. The probe
fails closed throughout: an unreadable workflow list, no caller at all, or an
unreadable agent regex are all FAIL, never PASS. Before any tag exists the
probe reports WARN, since there is nothing to pin to.

Fleet rollout is campaign 2 (issue #34).

## SC-6: canon mirror — proposed

Each site repository carries the shared agent canon at root (`AGENTS.md`), so
an agent starting in the repository sees the org's principles and the repo's
design mode without external context. Present today on skovbyesexologi.com and
denfrievilje.dk; rollout to the remaining sites is a campaign.

Probe, repository: `AGENTS.md` exists at the repository root.

## SC-7: self-tested CMS config key-diff — proposed

Sites with a git-CMS (Sveltia) keep `config.yml` in lockstep with the typed
content via a deterministic config-to-content key-diff at every nesting depth,
and the checker is self-tested with an injected fault before its clean pass is
trusted. An unmapped key is silently dropped on the editor's next save. No
site carries the checker yet; reference method proven in the m-path build.

Probe: none until the first implementation lands and names the script.

## SC-8: a reachable editor sign-in — adopted

A site whose CMS config names a `backend.base_url` must ship a stack that
serves it. Sveltia builds its whole OAuth handshake from that value, asking for
`${base_url}/auth` and then `${base_url}/callback`, so the path needs three
things and all three are easy to have half of:

1. **A proxy service** in `deploy/compose.staging.yml`
   (`vencax/netlify-cms-github-oauth-provider`, digest-pinned, on the
   per-project internal network). Its CSRF variable is `ORIGINS`, **plural** —
   the singular makes the container crash on startup with "Cannot read property
   'match' of undefined". Caddy depends on it with `required: false`, so a
   broken sign-in cannot take the public page down with it.
2. **A prefix-STRIPPING route**: `handle_path /auth/*`, never `handle`. The
   upstream serves `/auth` and `/callback` at its own root, so a route that
   forwards the prefix asks it for `/auth/auth` and 404s every sign-in.
3. **The credentials documented** in `deploy/staging.env.example`
   (`OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`), with the callback URL to
   register. The real values live only in the NAS copy of the env file.

Reference implementation: `chrishemmings.co.uk/deploy/`.

**Why this is a clause and not a note.** It was missed on gosscounselling.co.uk
for the whole build. The stack had been scaffolded before that site had a CMS
and its compose file and Caddyfile both said so — "No CMS, no OAuth proxy —
there is no app yet" — and stayed saying it after the CMS landed. Every file
was individually correct. Nothing watched the seam between a file in `static/`
and a file in `deploy/`, and the failure is invisible from the dev server,
where Sveltia's local-repository mode needs no proxy at all. The site could not
be edited on the only host it was configured for.

**Operating it, which the deploy manual did not cover.** The OAuth secrets are
stack env, and an env-only change moves no image digest, so the agent's next
fire does nothing with it — `deploy-agent.sh` only acts on a digest change or
on nothing running. It needs a force-recreate, and both of its arguments are
somewhere other than where they look:

```sh
sudo docker compose \
  -p gosscounselling-co-uk-staging \
  -f /volume1/docker/<domain>/repo/deploy/compose.staging.yml \
  --env-file /volume1/docker/<domain>/staging/staging.env \
  up -d --force-recreate sveltia-auth
```

- The **compose file is in the repo checkout** (`<domain>/repo/`), not beside
  the env file in the stack directory (`<domain>/staging/`). Only the env file
  lives there.
- The **project name is `$DOMAIN-$ENV_NAME` with dots turned to dashes**
  (`deploy-agent.sh:316`), passed as `-p`, which OVERRIDES the `name:` field
  inside the compose file. Those two disagree on every site in the fleet, and
  the one in the file is the one that is ignored. `docker compose ls` is the
  answer that cannot be wrong.

PULL-DEPLOY-MODEL.md §"Rotating Cloudflare / OAuth secrets" said of the
force-recreate "Document this if it bites in practice." It bit.

**Register the OAuth App under the ORGANISATION, not a personal account.**
`den-frie-vilje` has OAuth App access restrictions on, so a personally-owned
app produces a token that authenticates perfectly and cannot read the org's
repositories. The failure is invisible until someone tries to SAVE, and what
they see is "There was an error while saving the entry" — which reads as a bug
in the editor rather than as a permission that was never granted. It is also
easy to cause: the authorization screen carries a per-organisation Grant button
that the green Authorize button does not require you to touch.

An org-owned app is not subject to its own org's restrictions, so it cannot
happen at all. Register at
`https://github.com/organizations/<org>/settings/applications/new`.

To repair a personally-owned one already in use, without changing any secret or
touching the stack: approve it at
`https://github.com/organizations/<org>/settings/oauth_application_policy`.
The token already issued starts working.

Probe, repository: `scripts/check-deploy.ts` exists and is wired into the
`check` script. It parses the CMS config's own `base_url` rather than
matching on the literal `/auth`, so a site that mounts it elsewhere is still
measured. Reference: gosscounselling.co.uk.
Probe, staging origin: `/auth/auth` does not 404. It will redirect to GitHub
or complain about credentials; either is proof something is listening.

## SC-9: fonts served from our own origin — adopted

A site serves its own typefaces. No stylesheet, `@font-face` `src`, or
`preconnect` in the repository or on the live origin names a third-party font
host.

The hosts that count as third-party for this clause: `fonts.googleapis.com`,
`fonts.gstatic.com` (Google Fonts), `cdn.jsdelivr.net` and `unpkg.com` (npm
CDNs, which is how Fontsource is served by default), `use.typekit.net`,
`use.fontawesome.com`, and `fonts.bunny.net`. Bunny is on the list despite
being the privacy-conscious option: the clause is about who receives the
visitor's IP address, and the answer has to be us.

Self-hosting means the font files ship with the site: the Fontsource npm
packages pinned in `package.json`, copied into the build, and declared in our
own `@font-face` rules.

**Why this is a clause.** A font request tells the host who is reading the
page, from where, and when. A German court held that serving Google Fonts from
Google transfers the visitor's IP address without consent, which is the whole
argument in `sveltia/sveltia-cms#443`, and Sveltia moved its own fonts off
Google for exactly that reason in v0.174. Our sites carry the same exposure
for every visitor rather than for two editors, on sites whose entire
architecture, static build, git-backed CMS, self-hosted OAuth, pull-only
deploys, was chosen so that nothing runs on somebody else's infrastructure.
Fonts were the last runtime call to a third party, and they were there by
default rather than by decision.

**What this is not.** Not a ban on the typefaces. Every family currently
loaded from Google is on Fontsource under the same open licence; this changes
who serves the bytes, not which bytes.

**Three things a port must measure rather than assume.** A search and replace
produces a slower site that renders differently:

1. **Subsetting.** Google's `css2` endpoint serves per-browser subsets split by
   `unicode-range`. A naive self-host ships every glyph in the family. Danish
   and Norwegian need Latin Extended; check what the site's copy actually uses.
2. **Variable versus static.** Families served with an axis (`opsz`, `wght`) or
   an italic have both shapes on Fontsource, and the wrong one changes the
   rendering.
3. **`display=swap`.** It is in the Google URL and has to be reproduced in our
   own `@font-face`, or the site gains a flash of invisible text it did not
   have.
4. **The family name changes.** Fontsource suffixes variable families with
   `Variable`, so `'DM Sans'` becomes `'DM Sans Variable'` and the site's CSS
   tokens have to name both: `'DM Sans Variable', 'DM Sans', sans-serif`. A
   port that swaps the imports and leaves the tokens alone renders in
   `sans-serif` and **still passes this probe**, because the probe measures
   which hosts are named, not which typeface arrives. Found on the first port.
   The instrument is `document.fonts` after a build, not the scorecard.

Reference implementation: pending; `denfrievilje.dk` settles the approach,
being ours, so a typography regression costs us and not a client.

Probe, repository: `src/app.html` names no third-party font host.
Probe, live origin: the served home page names none either, which catches a
site that moved the link into a component or a stylesheet rather than removing
it.
