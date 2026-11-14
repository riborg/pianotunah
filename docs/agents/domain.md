# Domain docs

This file tells the engineering skills how to use this repo's domain documentation when they explore the codebase.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, or
- **`CONTEXT-MAP.md`** at the repo root if it exists: it points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in. In multi-context repos, also check `src/<context>/docs/adr/` for context-scoped decisions.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill, which `/grill-with-docs` and `/improve-codebase-architecture` call, creates them when terms or decisions get resolved, not before.

## File structure

Single-context repo (most repos):

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

Multi-context repo, marked by a `CONTEXT-MAP.md` at the root:

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Use the glossary's vocabulary

When your output names a domain concept, use the term as defined in `CONTEXT.md`. That includes issue titles, refactor proposals, hypotheses and test names. Don't switch to synonyms the glossary tells you to avoid.

If the concept you need isn't in the glossary yet, one of two things is true. Either you're inventing language the project doesn't use, and should reconsider, or the glossary has a real gap, which you should note for `/domain-modeling`.

## Flag ADR conflicts

If your output contradicts an existing ADR, say so in the output. Don't override the ADR without mentioning it:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
