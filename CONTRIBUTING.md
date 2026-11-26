# Contributing to Hailing Station

Hailing Station is public while still early and security-sensitive. Issues, design discussion, and reproducible test reports are welcome.

## Code contributions

External code contributions are not yet being accepted. The project is intended to remain available under AGPL-3.0-or-later while also supporting separately licensed official distributions. A contributor agreement that grants the necessary relicensing rights will be published before outside code is merged.

Please do not submit code copied from another project or a pull request containing substantive implementation until that agreement is in place.

## Reports and proposals

When opening an issue:

- describe the behavior and supported Apple platform involved;
- provide the smallest reproducible example possible;
- remove device names, network addresses, account identifiers, transcripts, recordings, and signing information; and
- use GitHub's private vulnerability reporting flow for security defects.

## Maintainer workflow

For any PR touching `.github/` or `scripts/`, the maintainer diffs those changes themselves at the exact head before merging: the PR contract workflows run from the PR's own workflow files, and the checker scripts take effect once merged.

Changes are developed from issue specifications and kept small enough to review. Pull requests should identify the issue they close or advance, name the tests that cover their acceptance criteria, and pass the repository verification scripts.

Before opening a PR, read [AGENTS.md](AGENTS.md), `scripts/pr-shape.py`, and the PR template. Check the first spec reference, open issue/spec label, four-production-file limit, security label, and test traceability before submitting. Finish intended commits before requesting independent review and retain the full current head SHA.

A draft still awaiting review may fail the review-record check; record that as a pending review, not a hash/implementation failure or an invented verdict. Smart review selection, skipped review, quota errors, and absent findings from a failed review are not approval. Preserve exact-head independent review requirements and old comment history; any later push requires a fresh review.

After completed independent exact-head review, publish any required newest second-key top-level comment in the enforced format **first**, then make a meaningful PR-body update containing the actual comment evidence link and truthful completed round record. Initial PR-open checks may have run before the comment existed, and comment publication alone does not trigger PR-shape. Reapplying an identical body may be a no-op; a successful `gh pr edit` or local PR-shape result does not prove an edited-event check was queued or passed.

Run PR-shape locally, then inspect the newest actual GitHub run and required checks. Confirm the run follows the meaningful edit, the PR's full reviewed head remains current, and check statuses/conclusions correspond to that head rather than an older run. Privileged base-branch workflows may report the base SHA, so verify the PR head separately. Diagnose the specific failure, including a missing new run, and repair metadata without a source push solely for metadata or label toggling to manufacture a run. Keep pending records honest; do not invent verdicts, weaken draft/branch protections or checks, or repeat unchanged failing runs.

Run before pushing:

```sh
scripts/verify.sh all
```

Simulator verification additionally requires the full Xcode toolchain:

```sh
scripts/verify.sh sim
```

When adding or updating a remote Swift package used by an iOS product, generate
the project and resolve the packages for the Hail-iOS scheme in Xcode. Review
and commit the workspace lock that Xcode uses for that scheme. The project
directory is ignored, so stage just the lock with
`git add -f HailingStation.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The simulator build and release archive use only the resolved versions. After
the simulator build, run `scripts/check-mobile-licenses.py` to check the
selected checkouts against the committed pins. For local path packages, commit
the manifest, selected sources, resources, and license evidence with the app.

Never commit credentials, Apple signing material, device identifiers, private network information, captured media, transcripts, generated Xcode projects, or local configuration.

## Opt-in host-path guard

Run `scripts/install-hooks.sh` to enable the pre-push hook for this clone. The installer is
idempotent and refuses to replace a different `core.hooksPath`. It also refuses to bypass
executable, non-`.sample` hooks in the clone's default hooks directory, listing their names;
integrate those hooks manually or explicitly override that refusal with `--force`.
The hook needs Python 3 and checks added lines and full messages in **every commit**
being pushed, including intermediate commits later cleaned up. It rejects absolute
macOS and Linux home paths, except for the exact documentation usernames `me` and `<you>`
and the non-personal components listed below.
Detection normalizes mixed plain and JSON-escaped separators and repeated slashes,
and matches the home prefix without case sensitivity. Only a slash or line end
ends a home-directory component; interior carriage returns remain part of it.
Write documentation placeholders with a trailing slash, such as `/Users/me/` or
`/Users/<you>/`, so closing quotes or punctuation cannot become part of the username.
Standard system paths under `/Applications/`, `/usr/`, `/opt/homebrew/`, `/System/`,
and `/Library/` are allowed when they contain no home-path match. The non-personal
home components `/Users/Shared/`, `/home/linuxbrew/`, and `/home/runner/` are also
allowed (exact components, case-insensitive). Any `..` component that climbs above the
home component after normalization is rejected, including after a placeholder or
non-personal component and intervening `.` or child components.
Only GitHub API user endpoints are exempt: lower-case `users/<login>` directly after
`https://api.github.com/`, `api.github.com/`, `gh api `, or `gh api /`. The exemption
covers only that endpoint; all following text is checked. All other URLs, including
`file://`, are checked.
Binary or UTF-16 content is not scanned; deletions and
unchanged lines are skipped. Untracked/ignored build products are not scanned, and build
products must never be committed.

New tests must use the `me` or `<you>` placeholders, or build synthetic home paths from
parts. Existing synthetic names elsewhere are also flagged when a commit adds or changes
a line containing them.

For extra local rules, put one Python regex per line in
`$(git rev-parse --git-common-dir)/info/host-path-patterns`. Blank lines and lines starting
with `#` (after whitespace) are ignored. Keep this optional file untracked; never commit
host-specific names. Regexes match added lines and full commit messages independently of
the placeholder/non-personal allowlists and GitHub API exemption, against both the raw
text and its normalized form.

You can also run `scripts/check-host-paths.py <base>..<head>` directly. For a new remote
branch, the hook uses the merge-base with the remote's locally known default branch,
falling back to its `main` or `origin/main`; missing history fails the check without fetching.
CI checks the PR's entire base-to-head commit range and runs the synthetic script tests.

If a path is reported, clean the tree and **rewrite the branch** so none of its pushed
commits contains it. For example, with a clean working tree and the intended parent in
`base`, preserve a backup branch, then squash the cleaned tree into one commit:

```sh
git branch backup-before-host-path-rewrite
clean_commit=$(git commit-tree 'HEAD^{tree}' -p "$base" -m "Describe the cleaned change")
git reset --soft "$clean_commit"
scripts/check-host-paths.py "$base..HEAD"
```

A squash merge does not remove intermediate commits from the PR's commit list. Fix the
branch before pushing; deleting the path in a later commit is insufficient.
