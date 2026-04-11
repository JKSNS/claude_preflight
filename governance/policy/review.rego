package agent.review

import rego.v1

# Meta-policy: enforces required review gates before a change can land.
# Input shape:
#   { "tool": {"name": "review"},
#     "request": {"change_class": "doc|code|dependency|policy|deployment|security",
#                 "author_agent": "<str>",
#                 "reviews": {
#                   "tests_passed": <bool>,
#                   "codex_review_passed": <bool>,
#                   "devil_advocate_passed": <bool>,
#                   "security_audit_passed": <bool>,
#                   "regression_review_passed": <bool>,
#                   "policy_tests_passed": <bool>,
#                   "reviewer_agent": "<str>",
#                   "human_approved": <bool>}} }

default decision := {
	"allow": false,
	"require_approval": false,
	"reason": "default deny",
}

# Non-doc changes must have a named author and reviewer. Empty strings are not
# acceptable — they were a self-review bypass in an earlier revision.
missing_attribution if {
	input.request.change_class != "doc"
	input.request.author_agent == ""
}

missing_attribution if {
	input.request.change_class != "doc"
	not input.request.author_agent
}

missing_attribution if {
	input.request.change_class != "doc"
	input.request.reviews.reviewer_agent == ""
}

missing_attribution if {
	input.request.change_class != "doc"
	not input.request.reviews.reviewer_agent
}

self_review if {
	input.request.change_class != "doc"
	input.request.author_agent == input.request.reviews.reviewer_agent
	not missing_attribution
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "non-doc change requires named author and reviewer agents",
} if {
	missing_attribution
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "non-doc change cannot be reviewed by its author agent",
} if {
	self_review
}

# Doc-only changes need only basic checks.
decision := {
	"allow": true,
	"require_approval": false,
	"reason": "doc change accepted",
} if {
	input.request.change_class == "doc"
	not self_review
}

# Code changes require tests + Codex review.
decision := {
	"allow": false,
	"require_approval": false,
	"reason": "code change requires passing tests and Codex review",
} if {
	input.request.change_class == "code"
	not code_gates_met
	not self_review
	not missing_attribution
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "code change gates met",
} if {
	input.request.change_class == "code"
	code_gates_met
	not self_review
	not missing_attribution
}

# Dependency changes require tests + Codex + human approval.
decision := {
	"allow": false,
	"require_approval": true,
	"reason": "dependency change requires tests, Codex review, and human approval",
} if {
	input.request.change_class == "dependency"
	not dependency_gates_met
	not self_review
	not missing_attribution
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "dependency change gates met",
} if {
	input.request.change_class == "dependency"
	dependency_gates_met
	not self_review
	not missing_attribution
}

# Policy changes require devil's advocate + policy tests + human approval.
decision := {
	"allow": false,
	"require_approval": true,
	"reason": "policy change requires devil's advocate review, passing policy tests, and human approval",
} if {
	input.request.change_class == "policy"
	not policy_gates_met
	not self_review
	not missing_attribution
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "policy change gates met",
} if {
	input.request.change_class == "policy"
	policy_gates_met
	not self_review
	not missing_attribution
}

# Security-sensitive changes require the full review battery, including a human.
decision := {
	"allow": false,
	"require_approval": true,
	"reason": "security-sensitive change requires full review battery and human approval",
} if {
	input.request.change_class == "security"
	not security_gates_met
	not self_review
	not missing_attribution
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "security review gates met",
} if {
	input.request.change_class == "security"
	security_gates_met
	not self_review
	not missing_attribution
}

# Deployment changes require all of the above plus a rollback plan.
decision := {
	"allow": false,
	"require_approval": true,
	"reason": "deployment change requires full review battery, rollback plan, and human approval",
} if {
	input.request.change_class == "deployment"
	not deployment_gates_met
	not self_review
	not missing_attribution
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "deployment review gates met",
} if {
	input.request.change_class == "deployment"
	deployment_gates_met
	not self_review
	not missing_attribution
}

code_gates_met if {
	input.request.reviews.tests_passed == true
	input.request.reviews.codex_review_passed == true
}

dependency_gates_met if {
	code_gates_met
	input.request.reviews.dependency_risk_review_passed == true
	input.request.reviews.human_approved == true
}

policy_gates_met if {
	input.request.reviews.policy_tests_passed == true
	input.request.reviews.devil_advocate_passed == true
	input.request.reviews.human_approved == true
}

security_gates_met if {
	code_gates_met
	input.request.reviews.security_audit_passed == true
	input.request.reviews.devil_advocate_passed == true
	input.request.reviews.human_approved == true
}

deployment_gates_met if {
	security_gates_met
	input.request.reviews.regression_review_passed == true
	input.request.reviews.rollback_plan == true
}
