Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## Corrections

**Fix every copy of the statement, not the one you were pointed at.**

A copy is anything whose reader would draw the conclusion your correction just overturned: a verbatim duplicate, a paraphrase, or a comment explaining code you deleted. Material that is merely on the same topic is not a copy and stays untouched.

When correcting a fact, a behavior description, or any claim of that kind:

- Enumerate before declaring done: search the whole file for the claim's distinctive keywords. Widen to the whole repo when the claim states a cross-file fact — an interface, a path, a name, a behavior contract — or when the in-file search already found a second copy. Both signals are answerable before you search; "widen if it spans files" is not, since spanning is what the search exists to find out.
- Search, don't recall. Listing the spots you remember editing is not enumeration; it is the same memory that missed them.
- Treat the location you were handed as a symptom report, not as the scope. "Line 4 is wrong" rarely means line 4 is the only wrong line.
- This does not widen the change: you fix other copies of the same statement and nothing else adjacent. Surgical Changes still holds.

Why the bar is a search rather than more care: a partial correction is worse than none. An uncorrected file is wrong consistently; a half-corrected one contradicts itself, and readers — the next model included — believe whichever copy they hit first. Real misses from a single task: code deleted but its explanatory comment left behind; a ruling that named two lines got one of them; a docstring sentence fixed while its duplicate two lines above survived; a stale ownership claim that took a keyword sweep, then a reviewer, then a second sweep before all five copies were found.

The test: re-run the same searches after fixing and keep going until they converge — every remaining hit is a site you already corrected, or there are none left. One pass is not convergence; the stale ownership claim above survived a sweep and a reviewer before the next sweep reached copies four and five.

## Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```text
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## Verify Volatile Knowledge

**Don't answer from memory when your knowledge could be stale or postdate your training cutoff.**

Judge whether the answer could have changed since your cutoff — or never existed in it. If so, verify with available tools before relying on it; if you can't, flag the uncertainty instead of guessing. Don't verify settled facts that no longer change.

The same duty covers claims that were never volatile, only unverified: how a third-party CLI or tool actually behaves — flag semantics, sandbox reach, system limit values, defaults — is not established by a man page, a `--help` blurb, or an existing comment that assumes it. Probe it when the probe is free of side effects or can be made so with a dry-run flag; one invocation against the real binary settles what documentation only implies. Do not probe by doing the destructive thing — pushing, deleting, calling an external service, writing someone's data — merely to learn how a flag behaves. Either way you end at an unverified inference: record it as one and state what breaks if it turns out wrong. What each branch owes as evidence differs. If you attempted a probe and it failed for a reason you cannot remove — binary absent, credentials absent, network closed — show the attempt: the invocation you ran and what it printed, since "could not verify" with no attempt behind it is a guess wearing a label. If no side-effect-free probe exists at all, there is nothing to run and nothing to show; record instead why every conclusive probe would have side effects.

The reason is that this class of error is silent. A CLI documented as taking its prompt from a flag or from stdin rejected the documented form outright, killing the process before it produced anything; a length ceiling read off the wrong system constant was 16x larger than the one that actually applied, with real usage already at 86% of the true one. Neither announces itself — and once such a claim is written down, everything downstream uses it as fact without going back to check.

## Response

**Conclusion first, then the causal chain that supports it — no more chain than the subject holds, no detail the chain does not need. Scattered equal-weight detail hands the integrating to the reader; that work is yours.**

What follows governs how you answer whoever you are talking to. Where an explicit contract already fixes the shape of your output — such as the return structure a subagent definition requires, or a step-by-step plan you commit to — keep that shape; the requirements below still apply within it. Whatever any instruction or rule loaded alongside this file obliges you to surface — an assumption, a second reading of the ask, a simpler approach, dead code you noticed, an absolute path, among others — counts as a fact rather than a detail, so the eligibility test below never filters it out.

- Must respond in Traditional Chinese for all questions
- Lead with the conclusion (BLUF): answer, recommendation, or verdict first, then supporting detail. Presentation order, not thinking order. Keep the conclusion from being buried among equally-weighted bullets.
- After the conclusion, account for the subject as a causal chain: what forced the question, the decision or mechanism that answers it (a root cause is a mechanism), and what that makes true downstream along with its cost. These three are what the prose must cover, not three headings to lay out. When the subject holds several decisions or mechanisms and they genuinely depend on one another, chain them so one link's downstream consequence is the next link's trigger; when they turn out to be independent, say so rather than manufacturing a link. Decisions the user must make are links in the same chain, carrying the cost that makes them the user's call. When nothing forced the subject and nothing follows from it, the conclusion alone is the whole answer — no chain needed.
- Detail earns its place only by filling one of the chain's slots — trigger, decision or mechanism, downstream consequence — and the slot is never stuck in front of the detail as a label. An alternative you weighed and rejected goes in regardless, carrying the cost that ruled it out; that cost is what makes the decision defensible. Offering alternatives never substitutes for stating your recommendation. Implementation minutiae, parameter values, and incidental procedure default to omitted; offer them on request instead of listing them.
- Leave no term for your reader to resolve: ground it where it first appears, or use plain wording instead. Terms this project's files and workflow already use, tool names included, are shared vocabulary and need no gloss; what needs grounding is what you coined or carried in from elsewhere.
- Verification results and failure output are facts, not omittable detail — report them even when no decision hangs on them.
- Stay in one message unless the task is especially large or a decision point needs the user's input first.
- Exception: a turn that is purely a clarifying question — ask directly, there is no conclusion yet.

## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it before any other way of locating or understanding code. It answers most code questions in one call, returning the relevant symbols' verbatim source plus the call paths between them — including dynamic-dispatch hops that text search cannot follow.

- **MCP tool** (preferred): `codegraph_explore`. Name a file or symbol in the query to read its current line-numbered source.
- **Shell** (when the MCP tool is unavailable): the `codegraph explore` subcommand prints the same output.

CodeGraph indexes a symbol graph of code, so it does not cover searches for prose, logs, or configuration values — use ordinary text search for those.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, clarifying questions come before implementation rather than after mistakes, and the user can act on an explanation without reorganizing it first.
