package agent.deployment

import rego.v1

# Decides deployment requests.
# Input shape:
#   { "tool": {"name": "deployment"},
#     "request": {"environment": "dev|staging|production",
#                 "branch": "<str>",
#                 "tests_passed": <bool>,
#                 "security_findings_open": <int>,
#                 "rollback_plan": <bool>,
#                 "human_approved": <bool>} }

default decision := {
	"allow": false,
	"require_approval": false,
	"reason": "default deny",
}

is_production if {
	input.request.environment == "production"
}

is_production if {
	input.request.environment == "prod"
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "tests have not passed",
} if {
	not input.request.tests_passed
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "open security findings block deployment",
} if {
	input.request.security_findings_open > 0
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "production deploy requires human approval and rollback plan",
} if {
	is_production
	input.request.tests_passed
	input.request.security_findings_open == 0
	not all_production_gates
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "production deploy gates satisfied",
} if {
	is_production
	all_production_gates
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "non-production deploy",
} if {
	not is_production
	input.request.tests_passed
	input.request.security_findings_open == 0
}

all_production_gates if {
	input.request.tests_passed
	input.request.security_findings_open == 0
	input.request.rollback_plan == true
	input.request.human_approved == true
}
