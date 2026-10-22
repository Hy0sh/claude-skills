---
name: visual-plan
description: Use when a plan, an analysis or a verdict written in markdown is about to be handed to a human for approval or reading — a plan parked for the user, a spec to validate, a design to arbitrate — and the user would rather review a page than read the markdown, or asks for a "more visual" plan.
argument-hint: [path to the plan's markdown]
---

# Render a plan as a page

Chat with the user in their language; this skill file stays in English.

The markdown stays the source: agents implement it, review against it, diff it. The page is a **view of it for the human**, generated once, never edited by hand, never read by an agent instead of the markdown.

**The agent that wrote the plan renders it**, itself, on its own model. It knows what the markdown only names: the people the change is for, the screens and the mockup, the branches around it, the project's look. A renderer handed the markdown alone lays text out in boxes; the author tells what the change does to whom. Do not delegate it to a lighter model.

**[reference.html](reference.html) is the bar, not the template**: a real plan rendered this way, names changed — an API-heavy one. Read it before the first page of a session and match its density: concrete people and numbers in the journey and the choices, every diagram drawn from the plan's own facts, prose kept short under each. Its sections fit that plan; take the level, not the layout.

## The file

- **Next to the markdown, same name, `.html`**: `plans/SHOP-12/plan.md` → `plans/SHOP-12/plan.html`. Tools that show the plan find the page this way; any other name or folder and it is never shown.
- One self-contained file: CSS inline, no JavaScript but the choice script below, nothing from the network (a Google Fonts stylesheet is the one exception). Images are embedded as `data:` URIs: a tool that keeps a copy of the page keeps that one file, and a relative image path breaks there.
- Under 8 MB in all: an image is resized to the width it is shown at (1200 px is plenty) and saved as JPEG or WebP.
- Never touch the markdown. A plan that changes gets its page regenerated.
- In the user's language, whatever the markdown's.

## What the page can show

What the reader needs to decide comes first: the header, then the choices. After them, draw what this plan is about. Ask what the reader must see to approve it, and give that a diagram; the list below is a menu, not a checklist.

1. **Header**: ticket, title, one line of goal, the source markdown's path, then four or five facts as tiles (PRs, size, migrations, estimate, risk).
2. **Choices to make**, if the plan has any: one card each, its options under **the same letters as the markdown** (the user answers against the markdown), the recommended one highlighted, and below them **what each option changes concretely** for a named user or a number. Options only: no field for another answer, the tool that shows the page collects that.
3. **Rules involved** (business rules, past decisions the plan cites): a strip of small cards, the rule's id and one line each.
4. **Journey**: what the user will see, as a row of mini-screens (a URL bar, the rows or buttons that matter), the denied cases as red cards underneath.
5. **What the change touches**: one row per layer (screens, front data, contract, procedures, use cases, repository, tables), each file a box marked created, modified or reused.
6. **Decisions in the code** (access rules, branching logic): a tree read top to bottom, each question with its answers as labelled branches under it, each outcome a box, with the query count of each branch when the plan gives it. The boxes are HTML (flex or grid, with padding), never SVG text, which does not wrap: a label longer than its box runs into the border at every width. SVG, if any, only draws the connectors between them.
7. **Merge order and stack**, when other branches are involved: a vertical line of PRs with their state.
8. **Milestones** as cards; **edge cases** as a grid of situation → behaviour; **shared files** as a matrix across the branches that touch them.
9. **Open questions** for someone outside (a PO, a client), as one callout at the end.

Other plans call for other diagrams, in the same style:

- a front-end plan: the mockup itself when the plan cites one (a Figma node, a design URL): take its screenshot with the design tool the session has (the Figma MCP's screenshot of that node), else the image the plan links, and lay numbered hotspots over it for each gap or decision, as the reference does; then the screens in each state (empty, loading, error, full), the components and which is new or reused, what changes at each breakpoint, the interaction step by step;
- a data migration: the schema before and after, the rows each step touches, the order of deploys and what a rollback undoes;
- a performance plan: the budget before and after, per route or query;
- a refactor: what moves where, what stays the same for callers;
- a release or infrastructure plan: the sequence over time, who acts at each step, what production would need on top;
- a verdict on a bug: the reproduction (steps, observed against expected), the chain from symptom to root cause with its file:line, since when (the commit, the release), the blast radius (callers, records, users, with counts), then the options and the recommendation;
- a measurement report: the numbers as bars (queries, milliseconds, per volume), before and after, with what was measured and where the raw files are;
- a coverage report: a matrix of requirements against status, coloured, with the gaps listed under it;
- a plan made of framing questions: one card per question, the answer and the file:line that settles it.

Scale the page to the document. A ten-line fix gets a header, its choice and one before/after; a two-PR feature gets the full menu. A document with nothing to decide or picture (queries to run, a text to paste) gets no page.

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

Open the page in a headless browser and look at a full-page screenshot: dark and light, phone width. A diagram that overlaps or overflows is fixed before anyone sees it, and so is a label touching or crossing its box's border, or a connector that reaches the wrong box.

Then say where the page is, next to the markdown's path. Publishing it elsewhere (a hosted artifact, a shared drive) is a separate step, only when the user asks: it uploads this same file, it never renders a second one.
