Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.  

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

---

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- **Evaluate user proposals against current implementation and target requirements before executing. Do not follow blindly.**

---

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

---

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

Additional principles:
- **Fix bugs by identifying root causes, not applying workarounds.**
- **Explore upward (callers, architecture, data flow) to find general solutions.**
- **After fixing, clean up any obsolete or workaround code introduced during debugging.**

The test: Every changed line should trace directly to the user's request.

---

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```
Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

## 5. Architecture & Reusability

**Build features that fit the system, not just solve the task.**

When implementing new features:
- Follow the existing project structure and architecture.
- Reuse existing modules, utilities, and patterns whenever possible.
- Avoid duplicating logic that already exists elsewhere.
- Ensure new code integrates naturally into current directory and module design.

Balance principles:
- **Prefer separation of concerns, but avoid over-engineering.**
- **Avoid excessive abstraction that reduces readability.**
- **Aim for clean, cohesive modules instead of fragmented micro-components.**

The goal: code that is reusable, consistent, and easy to evolve — without unnecessary complexity.

---

**These guidelines are working if:**
- Fewer unnecessary changes in diffs
- Fewer rewrites due to overcomplication
- Bugs are fixed at root cause, not patched
- New features align naturally with existing architecture
- Clarifying questions come before implementation rather than after mistakes
