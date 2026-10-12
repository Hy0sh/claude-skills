"""Collect the review feedback other people left on one author's pull requests, then print where it falls.

Usage: python3 fetch_feedback.py <owner/repo> <author> <out_dir> [since YYYY-MM-DD] [split YYYY-MM-DD]

Writes <out_dir>/prs.json (every PR with its feedback) and <out_dir>/chunkN.json (feedback items, about 90 per
file, ready to classify), then prints the rates by month, PR size, base branch, top-level folder and reviewer.
`split` adds a before/after comparison at equal PR size, e.g. the date a review skill changed.
"""
import collections
import json
import pathlib
import subprocess
import sys

BOTS = ("bot", "copilot", "github-actions", "coderabbit", "sonar")
SIZES = [(0, 200), (200, 500), (500, 1000), (1000, 3000), (3000, 10**9)]
FRAGMENT = """
pr%d: pullRequest(number: %d) {
  number title createdAt baseRefName additions deletions
  files(first: 100) { nodes { path } }
  reviews(first: 50) { nodes { author { login } state body submittedAt } }
  comments(first: 100) { nodes { author { login } body createdAt } }
  reviewThreads(first: 100) { nodes { isResolved path line
    comments(first: 20) { nodes { author { login } body createdAt } } } }
}"""


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def login(node):
    return (node.get("author") or {}).get("login") or ""


def main():
    repo, author, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
    since = sys.argv[4] if len(sys.argv) > 4 else ""
    split = sys.argv[5] if len(sys.argv) > 5 else ""
    owner, name = repo.split("/")
    out.mkdir(parents=True, exist_ok=True)

    def other(who):
        return who and who != author and not any(b in who.lower() for b in BOTS)

    listed = json.loads(gh("pr", "list", "-R", repo, "--author", author, "--state", "all", "--limit", "2000",
                           "--json", "number,createdAt"))
    numbers = [p["number"] for p in listed if p["createdAt"][:10] >= since]
    prs = []
    for i in range(0, len(numbers), 15):
        chunk = numbers[i:i + 15]
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{' + "".join(FRAGMENT % (n, n) for n in chunk) + "} }"
        for pr in json.loads(gh("api", "graphql", "-f", f"query={query}"))["data"]["repository"].values():
            feedback = []
            for t in pr["reviewThreads"]["nodes"]:
                cs = t["comments"]["nodes"]
                if cs and other(login(cs[0])):
                    feedback.append({"kind": "thread", "by": login(cs[0]), "at": cs[0]["createdAt"], "path": t["path"],
                                     "resolved": t["isResolved"], "body": cs[0]["body"],
                                     "replies": [{"by": login(c), "body": c["body"][:600]} for c in cs[1:5]]})
            for c in pr["comments"]["nodes"]:
                if other(login(c)) and c["body"].strip():
                    feedback.append({"kind": "comment", "by": login(c), "at": c["createdAt"], "body": c["body"]})
            for r in pr["reviews"]["nodes"]:
                if other(login(r)) and r["body"].strip():
                    feedback.append({"kind": "review", "by": login(r), "at": r["submittedAt"], "body": r["body"]})
            prs.append({"number": pr["number"], "title": pr["title"], "createdAt": pr["createdAt"],
                        "base": pr["baseRefName"], "size": pr["additions"] + pr["deletions"],
                        "files": [f["path"] for f in pr["files"]["nodes"]], "feedback": feedback})
        print(f"{min(i + 15, len(numbers))}/{len(numbers)} PR", file=sys.stderr)
    (out / "prs.json").write_text(json.dumps(prs, ensure_ascii=False, indent=1))

    items = [{"id": f"{p['number']}-{k}", "pr": p["number"], "title": p["title"], "pr_size": p["size"]}
             | {key: f.get(key) for key in ("at", "by", "kind", "path", "resolved", "replies")}
             | {"body": f["body"][:1800]}
             for p in prs for k, f in enumerate(p["feedback"])]
    n_chunks = max(1, -(-len(items) // 90))
    for j in range(n_chunks):
        (out / f"chunk{j}.json").write_text(json.dumps(items[j * len(items) // n_chunks:(j + 1) * len(items) // n_chunks],
                                                       ensure_ascii=False))

    def row(label, ps):
        n, f = len(ps), sum(len(p["feedback"]) for p in ps)
        touched = sum(1 for p in ps if p["feedback"])
        print(f"  {label:32} PR={n:4} feedback={f:4} per PR={f / n if n else 0:4.2f} touched={touched / n * 100 if n else 0:3.0f}%")

    print(f"{len(prs)} PR, {len(items)} feedback items, {n_chunks} chunk(s) in {out}")
    print("by month")
    for m in sorted({p["createdAt"][:7] for p in prs}):
        row(m, [p for p in prs if p["createdAt"][:7] == m])
    print("by size (added + deleted lines)")
    for lo, hi in SIZES:
        row(f"{lo}-{hi}", [p for p in prs if lo <= p["size"] < hi])
    print("by base branch")
    for b, _ in collections.Counter(p["base"] for p in prs).most_common(5):
        row(b, [p for p in prs if p["base"] == b])
    print("by folder (three first path segments, a PR counts in each)")
    folders = collections.defaultdict(list)
    for p in prs:
        for d in {"/".join(f.split("/")[:3]) for f in p["files"] if f.count("/") >= 3}:
            folders[d].append(p)
    for d, ps in sorted(folders.items(), key=lambda x: -sum(len(p["feedback"]) for p in x[1]))[:12]:
        row(d, ps)
    print("by reviewer", collections.Counter(f["by"] for p in prs for f in p["feedback"]).most_common())
    if split:
        print(f"before / after {split}, at equal size")
        for lo, hi in [(0, 500), (500, 1500), (1500, 10**9)]:
            for label, keep in (("before", lambda d: d < split), ("after", lambda d: d >= split)):
                row(f"{label} {lo}-{hi}", [p for p in prs if keep(p["createdAt"][:10]) and lo <= p["size"] < hi])


if __name__ == "__main__":
    main()
