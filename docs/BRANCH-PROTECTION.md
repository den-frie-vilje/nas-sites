# Branch protection on `nas-sites`

The pull-only deploy model's threat model assumes that pushing a commit to
`nas-sites/main` is *not* sufficient to alter what runs on the NAS — the
operator's manual `tools/update-agent.sh` is the only path. That assumption
holds operationally only if `main` itself is protected against direct push
of unreviewed or unsigned code.

This document is the canonical source of truth for the GitHub repo
settings that need to be in place. Apply via `gh` CLI or the GitHub UI;
re-apply if a settings drift audit shows mismatch.

## Required protections on `main`

| Setting | Value | Why |
|---|---|---|
| Restrict deletions | on | A deleted-and-recreated `main` would lose its history and protections. |
| Block force pushes | on | A force-push could quietly rewrite the audited history. |
| Require a pull request before merging | on | No direct pushes to `main`. |
| Required approving reviews | 1 (raise as headcount allows) | A second pair of eyes. |
| Dismiss stale approvals on new commits | on | Force re-review after the operator reads the new diff. |
| Require review from Code Owners | on | Pairs with [.github/CODEOWNERS](../.github/CODEOWNERS). |
| Require signed commits | **on** | Push access alone is not sufficient — the committer also needs the signing key. This is the second factor that turns "GitHub credential compromise" from "deploy your own code" into "deploy your own code AND sign as someone with merge rights." |
| Require status checks to pass before merging | on (when CI exists for nas-sites) | Currently nas-sites has no CI of its own; this becomes relevant once `bash -n` and yamllint workflows are added. |
| Require linear history | on | Easier to audit `git log main` for "what landed when." |
| Do not allow bypass | on | Repo admins must follow the same rules as everyone else. |

## Required protections on `staging` (if used)

The same set, with one exception: required approving reviews can be 0 if
the team is small and `staging` is meant for fast iteration. Signed
commits + Code Owners review still apply.

## Apply via `gh` CLI

The GitHub web UI is the discoverable path. The `gh` CLI is reproducible —
useful when standing up a forked or migrated repo, and as drift detection.

```sh
# Requires gh >=2.40 and the `gh` admin token / PAT with `repo` scope.

gh api -X PUT /repos/den-frie-vilje/nas-sites/branches/main/protection \
    --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "required_signatures": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON
```

Notes on this payload:

- `required_signatures: true` is the part that trips many setups — every
  commit on `main` (including merge commits!) must have a verified GPG or
  SSH signature. GitHub's web merge button signs commits with GitHub's
  key, which counts as verified. Local merge requires the operator's
  signing key.
- `enforce_admins: true` is the "no bypass" — drop it only with a written
  reason.
- `required_status_checks: null` is correct only because nas-sites has
  no CI yet. When `bash -n` / yamllint workflows are added (see
  [Roadmap](#roadmap)), update this to require those checks.

## Verify what's in place

```sh
gh api /repos/den-frie-vilje/nas-sites/branches/main/protection \
    | jq '{
        signatures: .required_signatures.enabled,
        force_push: .allow_force_pushes.enabled,
        deletions:  .allow_deletions.enabled,
        reviews:    .required_pull_request_reviews,
        admins:     .enforce_admins.enabled,
        linear:     .required_linear_history.enabled
      }'
```

Run periodically — settings drift is a real failure mode.

## Signed-commit setup for the operator

Each operator with merge rights needs a signing key configured locally and
registered with GitHub.

```sh
# 1. Create an SSH signing key (or use an existing one; same key can sign
#    git commits AND authenticate ssh).
ssh-keygen -t ed25519 -C "ole signing key" -f ~/.ssh/id_ed25519_signing

# 2. Tell git to use it for signing.
git config --global gpg.format ssh
git config --global user.signingkey "$(cat ~/.ssh/id_ed25519_signing.pub)"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# 3. Register the public key with GitHub as a SIGNING key (note: this is a
#    different list from authentication keys, even though the key bytes
#    can be the same).
gh ssh-key add ~/.ssh/id_ed25519_signing.pub --title "ole signing key" --type signing
```

After this, `git commit` produces signed commits automatically and
`git log --show-signature main` displays "Good signature from …" lines.

## Roadmap items that interact with this

- **CI for nas-sites itself**: a small workflow that runs `bash -n
  tools/**/*.sh nas-agent/*.sh` and `python -c 'yaml.safe_load(...)'`
  on every PR. Once present, add it to `required_status_checks` above.
- **Tag-signed releases**: cut tagged releases (`v1.0`, `v1.1`, …) of the
  agent script and have `tools/update-agent.sh` accept `--tag <name>` to
  pin to a specific tag instead of `main`. Combined with signed tags, the
  operator can require not just "main" but "main at a signed tag I read."
- **Periodic drift audit**: a scheduled GitHub Action that calls
  `gh api .../branches/main/protection` and opens an issue if the live
  settings differ from the JSON in this doc. Closes the gap between
  "we documented the rules" and "the rules are actually in force."
