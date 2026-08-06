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

## SC-1: fail-closed robots route — adopted

robots.txt is a prerendered route, never a static file. Only the literal
`PUBLIC_ALLOW_INDEXING === 'true'`, imported from `$env/static/public`, bakes
the Allow variant with the sitemap advert; any other value, including an unset
variable, bakes `Disallow: /` with no advert. The route deploys atomically
with the image, so it is the primary strap; infra-side straps rot. The
Disallow list is a shared constant that also feeds the derived-sitemap filter
(reference shape: `src/lib/seo/robots.ts` on chrishemmings.co.uk).

Probe, repository: `src/routes/robots.txt/+server.ts` exists, contains
`=== 'true'` and imports `$env/static/public`.
Probe, staging origin: `/robots.txt` body contains `Disallow: /` and no
`Sitemap:` line.

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
