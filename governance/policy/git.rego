package agent.git

import rego.v1

# Decides git operations: commit, push, branch, reset, rebase, etc.
# Input shape:
#   { "tool": {"name": "git"},
#     "request": {"op": "commit|push|reset|rebase|branch|tag",
#                 "branch": "<str>",
#                 "remote": "<str>",
#                 "force": <bool>,
#                 "skip_hooks": <bool>,
#                 "human_approved": <bool>} }

protected_branches := ["main", "master", "release", "production", "prod"]

is_protected if {
	some b in protected_branches
	input.request.branch == b
}

# A finding contributes to the deny set (hard no) or the approval set (no
# without human approval). The final decision aggregates by priority.

deny contains "force push to protected branch is not permitted" if {
	input.request.op == "push"
	input.request.force == true
	is_protected
}

deny contains "skipping git hooks is not permitted" if {
	input.request.skip_hooks == true
	not input.request.human_approved
}

approval contains "force push requires human approval" if {
	input.request.op == "push"
	input.request.force == true
	not is_protected
	not input.request.human_approved
}

approval contains "destructive history rewrite (reset --force) requires approval" if {
	input.request.op == "reset"
	input.request.force == true
	not input.request.human_approved
}

approval contains "rebase of protected branch requires approval" if {
	input.request.op == "rebase"
	is_protected
	not input.request.human_approved
}

# Decision aggregates findings with priority: deny > approval > allow.
decision := {
	"allow": false,
	"require_approval": false,
	"reason": concat("; ", sort(deny)),
} if {
	count(deny) > 0
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": concat("; ", sort(approval)),
} if {
	count(deny) == 0
	count(approval) > 0
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "ordinary git operation",
} if {
	count(deny) == 0
	count(approval) == 0
}
