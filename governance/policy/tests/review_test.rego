package agent.review_test

import data.agent.review
import rego.v1

mk(class, reviews, author) := {
	"tool": {"name": "review"},
	"request": {
		"change_class": class,
		"author_agent": author,
		"reviews": reviews,
	},
}

test_doc_change_allowed if {
	d := review.decision with input as mk(
		"doc",
		{"reviewer_agent": "reviewer-a"},
		"builder-b",
	)
	d.allow == true
}

test_self_review_blocked if {
	d := review.decision with input as mk(
		"code",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"reviewer_agent": "builder-b",
		},
		"builder-b",
	)
	d.allow == false
}

test_code_change_needs_codex if {
	d := review.decision with input as mk(
		"code",
		{
			"tests_passed": true,
			"codex_review_passed": false,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
}

test_code_change_passes if {
	d := review.decision with input as mk(
		"code",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == true
}

test_dependency_needs_human if {
	d := review.decision with input as mk(
		"dependency",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"dependency_risk_review_passed": true,
			"human_approved": false,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
	d.require_approval == true
}

test_dependency_needs_risk_review if {
	# review-gates.yaml requires dependency_risk_review; review.rego now enforces it.
	d := review.decision with input as mk(
		"dependency",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"dependency_risk_review_passed": false,
			"human_approved": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
}

test_dependency_full_gates_pass if {
	d := review.decision with input as mk(
		"dependency",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"dependency_risk_review_passed": true,
			"human_approved": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == true
}

test_policy_change_needs_devil_advocate if {
	d := review.decision with input as mk(
		"policy",
		{
			"policy_tests_passed": true,
			"devil_advocate_passed": false,
			"human_approved": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
}

test_security_change_needs_human_approval if {
	# Codex caught: security_gates_met previously omitted human_approved.
	d := review.decision with input as mk(
		"security",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"security_audit_passed": true,
			"devil_advocate_passed": true,
			"human_approved": false,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
	d.require_approval == true
}

test_security_change_full_battery if {
	d := review.decision with input as mk(
		"security",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"security_audit_passed": true,
			"devil_advocate_passed": true,
			"human_approved": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == true
}

test_empty_author_blocked if {
	# Codex caught: empty author_agent bypassed the self_review check.
	d := review.decision with input as mk(
		"code",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"reviewer_agent": "",
		},
		"",
	)
	d.allow == false
}

test_missing_author_blocked if {
	d := review.decision with input as {
		"tool": {"name": "review"},
		"request": {
			"change_class": "code",
			"reviews": {
				"tests_passed": true,
				"codex_review_passed": true,
				"reviewer_agent": "reviewer-a",
			},
		},
	}
	d.allow == false
}

test_deployment_blocks_without_human if {
	d := review.decision with input as mk(
		"deployment",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"security_audit_passed": true,
			"devil_advocate_passed": true,
			"regression_review_passed": true,
			"rollback_plan": true,
			"human_approved": false,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
}

test_deployment_blocks_without_rollback if {
	d := review.decision with input as mk(
		"deployment",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"security_audit_passed": true,
			"devil_advocate_passed": true,
			"regression_review_passed": true,
			"rollback_plan": false,
			"human_approved": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == false
}

test_deployment_full_gates_pass if {
	d := review.decision with input as mk(
		"deployment",
		{
			"tests_passed": true,
			"codex_review_passed": true,
			"security_audit_passed": true,
			"devil_advocate_passed": true,
			"regression_review_passed": true,
			"rollback_plan": true,
			"human_approved": true,
			"reviewer_agent": "reviewer-a",
		},
		"builder-b",
	)
	d.allow == true
}
