"""Join the classified feedback (outN.jsonl) to its items (chunkN.json) and print what review missed.

Usage: python3 aggregate.py <out_dir> [since YYYY-MM-DD]

`since` limits the list of misses to feedback given from that date, e.g. the last change to the review skills.
"""
import collections
import json
import pathlib
import sys


def main():
    out = pathlib.Path(sys.argv[1])
    since = sys.argv[2] if len(sys.argv) > 2 else ""
    items = {i["id"]: i for f in sorted(out.glob("chunk*.json")) for i in json.loads(f.read_text())}
    rows = [json.loads(line) for f in sorted(out.glob("out*.jsonl")) for line in f.read_text().splitlines() if line.strip()]
    missing = set(items) - {r["id"] for r in rows}
    if missing:
        print(f"WARNING: {len(missing)} item(s) not classified, e.g. {sorted(missing)[:5]}")
    for r in rows:
        r["_"] = items[r["id"]]
    real = [r for r in rows if r["nature"] != "noise"]
    defects = [r for r in real if r["nature"] in ("defect", "risk")]
    print(f"{len(rows)} classified, {len(rows) - len(real)} noise, {len(defects)} defects or risks, "
          f"{sum(r['catchable'] == 'self_review' for r in defects)} of them catchable by self-review")
    print("nature", collections.Counter(r["nature"] for r in real).most_common())
    print("catchable", collections.Counter(r["catchable"] for r in real).most_common())
    print(f"{'category':20} total defect+risk self_review business tacit runtime written_down")
    by_cat = collections.defaultdict(list)
    for r in real:
        by_cat[r["category"]].append(r)
    for cat, rs in sorted(by_cat.items(), key=lambda x: -len(x[1])):
        count = lambda pred: sum(1 for r in rs if pred(r))
        print(f"{cat:20} {len(rs):5} {count(lambda r: r['nature'] in ('defect', 'risk')):11} "
              f"{count(lambda r: r['catchable'] == 'self_review'):11} {count(lambda r: r['catchable'] == 'needs_business'):8} "
              f"{count(lambda r: r['catchable'] == 'tacit_convention'):5} {count(lambda r: r['catchable'] == 'needs_runtime'):7} "
              f"{count(lambda r: r.get('written_down')):12}")
    print("patterns", collections.Counter(r["pattern"] for r in real if r.get("pattern")).most_common(20))
    print(f"\n## Misses: defects and risks a self-review could have caught{' since ' + since if since else ''}")
    for r in defects:
        if r["catchable"] == "self_review" and r["_"]["at"][:10] >= since:
            print(f"#{r['_']['pr']} {r['category']:18} {r['missed_check']}")
    print("\n## Conventions: tacit, or written down and not applied")
    for r in real:
        if r["catchable"] == "tacit_convention" or r.get("written_down"):
            print(f"#{r['_']['pr']} {'written' if r.get('written_down') else 'tacit':7} {r['missed_check']}")
    print("\n## Business questions left to the reviewer")
    for r in real:
        if r["catchable"] == "needs_business":
            print(f"#{r['_']['pr']} {r['missed_check']}")


if __name__ == "__main__":
    main()
