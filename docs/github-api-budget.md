# GitHub API budget

Every agent session, Codex task, CI watcher and host job on the maintainer's Mac spends one GitHub account's budget (#550). A rate-limit error in the middle of a spoken answer means a slow or empty reply, so agents working on this repo keep their GitHub calls few and cheap.

## The limits

| Resource | Budget | Who spends it |
| --- | --- | --- |
| `core` (REST) | 5,000 requests per hour | `gh api`, `gh run watch`, `gh pr merge` |
| `graphql` | 5,000 points per hour | `gh issue list`, `gh pr list`, `gh pr view`, `gh pr checks` |
| `search` | 30 requests per minute | `gh issue list --search`, `gh api search/...` |

GitHub also enforces **secondary limits** on bursts of requests. They are not shown in `rate_limit`. A burst of `gh issue list --search` calls can be refused with `GraphQL: API rate limit already exceeded` while the hourly GraphQL budget still shows thousands of points left. When that happens, REST (`gh api ...`) usually still works.

## Check the budget

```sh
gh api rate_limit --jq '.resources | to_entries[] | select(.key == "core" or .key == "graphql" or .key == "search") | "\(.key)\t\(.value.remaining)/\(.value.limit)\tresets \(.value.reset | strflocaltime("%H:%M:%S"))"'
```

It prints one line per resource with the remaining budget and the local reset time, for example `graphql	4909/5000	resets 17:36:08`. Calls to `rate_limit` do not count against the budget. GitHub does not say which process spent the budget. To find a heavy spender, use the host inventory below.

## Rules for agents

- **One search per question.** Combine terms in one REST search instead of a loop of `gh issue list --search`:
  `gh api -X GET search/issues -f q='repo:mickdarling/hailing-station is:issue (mute OR headset OR AirPods)'`
- **Space out searches.** Search allows 30 requests a minute in total, shared by every session.
- **On a rate-limit error, check the budget once.** Never retry in a loop. If the hourly budget is spent, wait for the reset time it prints. If budget remains, it was a secondary limit: switch to REST (`gh api`) or wait a minute.
- **Watch CI slowly.** `gh pr checks --watch` polls GraphQL every 10 seconds by default and `gh run watch` polls REST every 3 seconds. For runs that take minutes, pass `--interval 60` (`-i 60`), or watch one run with `gh run watch <id> -i 60`.
- **Prefer REST for writes when GraphQL is refused:** for example `gh api -X PUT repos/OWNER/REPO/pulls/N/merge -f sha=<head>` instead of `gh pr merge`.
- **Fail soft in voice replies.** If a lookup is rate-limited, say so in one sentence and offer to check again after the reset time, rather than stalling.

## Timed pollers

Hailing Station itself has **no timed GitHub pollers**. `haild` and the apps make no GitHub calls. Every workflow in `.github/workflows/` runs on pull request events, not on a schedule.

The same account's budget is also spent by these, as of 2026-10-17:

| Poller | Interval | Backoff |
| --- | --- | --- |
| Agent CI watches (`gh pr checks --watch`, `gh run watch`) | 10 s and 3 s by default, for as long as the run lasts | None: they fail on the first error. Use `--interval 60`. |
| Project Atlas scan (`com.mickdarling.project-atlas-scan` LaunchAgent) | Once a day at 07:00 | Not checked; runs with `--no-github` to skip GitHub |
| RightyO review gate (`rightyo` `.github/workflows/ai-review.yml`) | Event-driven: pull request events and manual rechecks, no schedule | Not applicable |

Add a row here when a new timed job calls GitHub. Give it a conditional request (ETag) or webhook where one exists, back off on 403 and 429 using `Retry-After` or `x-ratelimit-reset`, and log its call rate.
