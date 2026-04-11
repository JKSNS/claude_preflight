package agent.secrets

import rego.v1

# Decides any access to material classified as a secret.
# Input shape:
#   { "tool": {"name": "secrets"},
#     "request": {"op": "read|write|list", "path": "<str>", "kind": "<str>"} }

default decision := {
	"allow": false,
	"require_approval": false,
	"reason": "agents may not access secrets",
}

# A small allowance: agents may *list* the existence of secret references
# (e.g., env-var names) when explicitly tagged as a non-disclosing list op.
decision := {
	"allow": true,
	"require_approval": false,
	"reason": "non-disclosing reference listing",
} if {
	input.request.op == "list"
	input.request.kind == "reference-only"
}
