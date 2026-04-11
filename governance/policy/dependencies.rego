package agent.dependencies

import rego.v1

# Decides dependency add/remove/upgrade requests.
# Input shape:
#   { "tool": {"name": "dependencies"},
#     "request": {"op": "add|remove|upgrade|pin",
#                 "ecosystem": "pip|npm|cargo|go|apt|brew",
#                 "package": "<str>",
#                 "version": "<str>",
#                 "human_approved": <bool>} }

default decision := {
	"allow": false,
	"require_approval": true,
	"reason": "dependency change requires approval",
}

unpinned if {
	input.request.op == "add"
	not input.request.version
}

unpinned if {
	input.request.op == "add"
	input.request.version == ""
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "unpinned dependency add; supply explicit version",
} if {
	unpinned
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "approved pinned dependency change",
} if {
	input.request.human_approved == true
	not unpinned
}
