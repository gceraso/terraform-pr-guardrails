#!/usr/bin/env python3
"""Read `terraform show -json` plans, decide whether a PR is safe, and render the PR comment.

    plan_guard.py --plan merge.json [--head-plan head.json] [--allow-destroy] [--out comment.md]

--plan       the plan of the PR merged into the current base branch (what would land)
--head-plan  the plan of the PR branch exactly as pushed; compared against --plan to find
             changes that exist only because the branch is behind its base
Exit 0 = pass, 1 = blocked, 2 = bad input. Standard library only, so CI needs no pip install.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

MARKER = "<!-- terraform-pr-guardrails -->"
DEFAULT_POLICY = Path(__file__).with_name("policy.json")

SYMBOL = {
    "create": "+", "update": "~", "replace": "-/+", "delete": "-",
    "move": ">", "forget": "x", "read": "<=",
}


@dataclass
class Change:
    address: str
    type: str
    kind: str                      # create | update | replace | delete | move | forget | read | no-op
    previous_address: str | None = None
    replace_paths: list[str] = field(default_factory=list)
    after: object = None

    @property
    def destroys(self) -> bool:
        return self.kind in ("replace", "delete")


def classify(actions: list[str], previous_address: str | None) -> str:
    match sorted(actions):
        case ["create", "delete"]:
            return "replace"
        case ["no-op"]:
            return "move" if previous_address else "no-op"
        case [single]:
            return single
    return "+".join(actions)


def load_plan(path: Path) -> dict[str, Change]:
    try:
        plan = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f"plan_guard: cannot read plan {path}: {e}")
    if "resource_changes" not in plan and "format_version" not in plan:
        sys.exit(f"plan_guard: {path} is not `terraform show -json` plan output")

    changes = {}
    for rc in plan.get("resource_changes", []):
        if rc.get("mode") == "data":
            continue
        ch = rc["change"]
        prev = rc.get("previous_address")
        changes[rc["address"]] = Change(
            address=rc["address"],
            type=rc["type"],
            kind=classify(ch["actions"], prev),
            previous_address=prev,
            replace_paths=[".".join(str(p) for p in path) for path in ch.get("replace_paths") or []],
            after=ch.get("after"),
        )
    return changes


@dataclass
class Verdict:
    blocking: list[str] = field(default_factory=list)
    stale: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def blocked(self) -> bool:
        return bool(self.blocking or self.stale)


def evaluate(changes: dict[str, Change], policy: dict, allow_destroy: bool) -> Verdict:
    v = Verdict()
    protected = set(policy["protected_types"])
    label = policy.get("override_label", "allow-destroy")
    for c in changes.values():
        if not c.destroys:
            continue
        why = f" -- forced by `{'`, `'.join(c.replace_paths)}`" if c.replace_paths else ""
        line = f"`{c.address}` will be **{c.kind}d**{why}"
        if c.type in protected and not allow_destroy:
            v.blocking.append(f"{line}. `{c.type}` holds data; add the `{label}` label if this is intended.")
        elif c.type in protected:
            v.warnings.append(f"{line} (allowed by the `{label}` label).")
        else:
            v.warnings.append(f"{line}.")
    return v


def stale_drift(head: dict[str, Change], merged: dict[str, Change]) -> list[str]:
    """Changes the branch would make on its own that the merge result would not.

    A branch's diff is computed against its merge-base, so a branch that is behind shows a small
    clean diff while its *plan* reverts everything merged since. Applying from the branch
    (Atlantis-style, or a reviewer trusting the branch plan) does that revert.
    """
    out = []
    for addr in sorted(set(head) | set(merged)):
        h, m = head.get(addr), merged.get(addr)
        h_sig = (h.kind, h.after) if h and h.kind != "no-op" else None
        m_sig = (m.kind, m.after) if m and m.kind != "no-op" else None
        if h_sig == m_sig:
            continue
        if h_sig and not m_sig:
            out.append(f"`{addr}`: branch would **{h.kind}** it; merged with the base it is unchanged.")
        elif m_sig and not h_sig:
            out.append(f"`{addr}`: merged result would **{m.kind}** it; the branch plan does not show this.")
        elif h.kind != m.kind:
            out.append(f"`{addr}`: branch would **{h.kind}**, merged result would **{m.kind}**.")
        else:
            out.append(f"`{addr}`: branch and merged result would {h.kind} it to different values.")
    return out


def counts_line(changes: dict[str, Change]) -> str:
    order = ["create", "update", "replace", "delete", "move", "forget"]
    tally = {k: sum(1 for c in changes.values() if c.kind == k) for k in order}
    return "  ".join(f"`{SYMBOL[k]}{tally[k]}` {k}" for k in order if tally[k]) or "No changes."


def render(changes: dict[str, Change], v: Verdict, allow_destroy: bool, workdir: str) -> str:
    status = "BLOCKED" if v.blocked else "PASS"
    lines = [MARKER, f"### Terraform plan: `{workdir}` -- **{status}**", "", counts_line(changes), ""]

    if v.blocking:
        lines += ["#### Blocking: destroys stateful resources", *[f"- {b}" for b in v.blocking], ""]
    if v.stale:
        lines += [
            "#### Blocking: branch is behind its base",
            "The branch's own plan differs from the plan of the branch merged into the base. "
            "Applying from the branch would undo work already merged. Update the branch.",
            *[f"- {s}" for s in v.stale], "",
        ]
    if v.warnings:
        lines += ["#### Warnings", *[f"- {w}" for w in v.warnings], ""]

    moves = [c for c in changes.values() if c.kind == "move"]
    if moves:
        lines += ["#### Moved (state only, nothing recreated)",
                  *[f"- `{c.previous_address}` -> `{c.address}`" for c in moves], ""]

    rows = [c for c in changes.values() if c.kind not in ("no-op", "move")]
    if rows:
        lines += ["<details><summary>All changes</summary>", "",
                  "| | Address | Type |", "|---|---|---|",
                  *[f"| `{SYMBOL.get(c.kind, c.kind)}` | `{c.address}` | `{c.type}` |" for c in rows],
                  "", "</details>", ""]
    if allow_destroy:
        lines.append("_`allow-destroy` label present: stateful destroys are warnings, not blockers._")
    return "\n".join(lines).rstrip() + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", required=True, type=Path)
    ap.add_argument("--head-plan", type=Path)
    ap.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    ap.add_argument("--allow-destroy", action="store_true")
    ap.add_argument("--workdir", default="infra")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args(argv)

    policy = json.loads(args.policy.read_text())
    merged = load_plan(args.plan)
    verdict = evaluate(merged, policy, args.allow_destroy)
    if args.head_plan:
        verdict.stale = stale_drift(load_plan(args.head_plan), merged)

    comment = render(merged, verdict, args.allow_destroy, args.workdir)
    if args.out:
        args.out.write_text(comment)
    print(comment)
    return 1 if verdict.blocked else 0


if __name__ == "__main__":
    sys.exit(main())
