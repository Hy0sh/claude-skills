---
name: visual-plan
description: Use when a plan, an analysis or a verdict written in markdown is about to be handed to a human for approval or reading — a plan parked for the user, a spec to validate, a design to arbitrate — and the user would rather review a page than read the markdown, or asks for a "more visual" plan.
argument-hint: [path to the plan's markdown]
---

# Render a plan as a page

Chat with the user in their language; this skill file stays in English.

The markdown stays the source: agents implement it, review against it, diff it. The page is a **view of it for the human**, generated once, never edited by hand, never read by an agent instead of the markdown.

## The file

- **Next to the markdown, same name, `.html`**: `plans/SHOP-12/plan.md` → `plans/SHOP-12/plan.html`. Tools that show the plan find the page this way; any other name or folder and it is never shown.
- One self-contained file: CSS inline, no JavaScript but the choice script below, no image or script from the network (a Google Fonts stylesheet is the one exception). Images the plan links to are referenced by the same relative path.
- Never touch the markdown. A plan that changes gets its page regenerated.
- In the user's language, whatever the markdown's.

## What the page is, in this order

1. **Header**: ticket, title, one line of goal, the source markdown's path, then four or five facts as tiles (PRs, size, migrations, estimate, risk).
2. **Choices to make**, if the plan has any: one card each, its options under **the same letters as the markdown** (the user answers against the markdown), the recommended one highlighted, and below them **what each option changes concretely** for a named user or a number. Options only: no field for another answer, the tool that shows the page collects that.
3. **Rules involved** (business rules, past decisions the plan cites): a strip of small cards, the rule's id and one line each.
4. **Journey**: what the user will see, as a row of mini-screens (a URL bar, the rows or buttons that matter), the denied cases as red cards underneath.
5. **What the change touches**: one row per layer (screens, front data, contract, procedures, use cases, repository, tables), each file a box marked created, modified or reused.
6. **Decisions in the code** (access rules, branching logic): an inline SVG tree, with the query count of each branch when the plan gives it.
7. **Merge order and stack**, when other branches are involved: a vertical line of PRs with their state.
8. **Milestones** as cards; **edge cases** as a grid of situation → behaviour; **shared files** as a matrix across the branches that touch them.
9. **Open questions** for someone outside (a PO, a client), as one callout at the end.

Leave a section out when the plan has nothing for it. Every fact on the page comes from the markdown: nothing invented, nothing summarised away.

## Choices are clickable

A tool that shows the page next to its own answer form (acw's board does) takes a click on an option as the answer. Each option carries the choice's number, in the markdown's order from 1, and its letter:

```html
<div class="opt" data-choice="1" data-option="a">…</div>
```

and the page ends with this script, as is:

```html
<script>
document.addEventListener("click", e => {
  const o = e.target.closest("[data-choice][data-option]");
  if (!o) return;
  document.querySelectorAll(`[data-choice="${o.dataset.choice}"]`).forEach(x => x.classList.toggle("picked", x === o));
  parent.postMessage({ type: "plan-choice", choice: Number(o.dataset.choice), option: o.dataset.option }, "*");
});
</script>
```

Style `.picked` so the click shows, and `cursor: pointer` on the options. Opened on its own, the page reads the same: the click only marks the option.

## Look

Colours as tokens on `:root`, redefined for `prefers-color-scheme: dark`; a 960 px reading column; readable at phone width without horizontal scroll (wide diagrams scroll inside their own box). When the project has a design system or a palette, use it.

## Before handing it over

Open the page in a headless browser and look at a full-page screenshot: dark and light, phone width. A diagram that overlaps or overflows is fixed before anyone sees it.

Then say where the page is, next to the markdown's path. Publishing it elsewhere (a hosted artifact, a shared drive) is a separate step, only when the user asks.

## Cost

The page is a rendering, not an analysis: when a cheaper model can be delegated to (a subagent on a lighter model), give it the markdown and this skill.
