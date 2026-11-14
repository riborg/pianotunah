# Issue tracker: GitHub

This repo keeps its issues and specs as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`. Filter the comments with `jq` and fetch the labels too.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`. Add `--label` and `--state` filters as needed.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

Infer the repo from `git remote -v`; `gh` does this automatically when run inside a clone.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --comments` and `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments` then keep only PRs whose `authorAssociation` is `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE`, and drop `OWNER`, `MEMBER` and `COLLABORATOR`.
- **Comment, label or close**: `gh pr comment`, `gh pr edit --add-label` or `--remove-label`, `gh pr close`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either. Try `gh pr view 42` first and fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

`/wayfinder` uses these operations. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Claiming a ticket assigns it to the driving dev.
- **Blocking**: use GitHub's native issue dependencies. They are the canonical record, and the GitHub UI shows them. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub's `issue_dependencies_summary.blocked_by` counts open blockers only, so it tells you whether the ticket is blocked right now. Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children with `gh issue list --state open`, scoped to the map's sub-issues or task list. Drop any child that has an assignee or an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line). Take the first remaining child in map order.
- **Claim**: run `gh issue edit <n> --add-assignee @me` as the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`, then append a context pointer (a gist and a link) to the map's Decisions-so-far.
