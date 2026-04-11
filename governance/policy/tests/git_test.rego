package agent.git_test

import data.agent.git
import rego.v1

mk(req) := {"tool": {"name": "git"}, "request": req}

test_force_push_protected_denied if {
	d := git.decision with input as mk({
		"op": "push", "branch": "main", "force": true,
		"skip_hooks": false, "human_approved": false,
	})
	d.allow == false
	d.require_approval == false
}

test_force_push_with_skip_hooks_no_conflict if {
	# This input historically caused two overlapping decision rules. The
	# deny-set pattern aggregates them into a single hard deny.
	d := git.decision with input as mk({
		"op": "push", "branch": "feature", "force": true,
		"skip_hooks": true, "human_approved": false,
	})
	d.allow == false
	d.require_approval == false
}

test_force_push_unprotected_needs_approval if {
	d := git.decision with input as mk({
		"op": "push", "branch": "feature", "force": true,
		"skip_hooks": false, "human_approved": false,
	})
	d.allow == false
	d.require_approval == true
}

test_force_push_unprotected_with_approval_passes if {
	d := git.decision with input as mk({
		"op": "push", "branch": "feature", "force": true,
		"skip_hooks": false, "human_approved": true,
	})
	d.allow == true
}

test_skip_hooks_unapproved_denied if {
	d := git.decision with input as mk({
		"op": "commit", "branch": "feature", "force": false,
		"skip_hooks": true, "human_approved": false,
	})
	d.allow == false
	d.require_approval == false
}

test_reset_force_needs_approval if {
	d := git.decision with input as mk({
		"op": "reset", "branch": "feature", "force": true,
		"skip_hooks": false, "human_approved": false,
	})
	d.require_approval == true
}

test_rebase_protected_needs_approval if {
	d := git.decision with input as mk({
		"op": "rebase", "branch": "main", "force": false,
		"skip_hooks": false, "human_approved": false,
	})
	d.require_approval == true
}

test_ordinary_commit_allowed if {
	d := git.decision with input as mk({
		"op": "commit", "branch": "feature", "force": false,
		"skip_hooks": false, "human_approved": false,
	})
	d.allow == true
}
