package agent.secrets_test

import data.agent.secrets
import rego.v1

test_default_deny_read if {
	d := secrets.decision with input as {
		"tool": {"name": "secrets"},
		"request": {"op": "read", "path": "/etc/passwd", "kind": "value"},
	}
	d.allow == false
}

test_default_deny_write if {
	d := secrets.decision with input as {
		"tool": {"name": "secrets"},
		"request": {"op": "write", "path": ".env", "kind": "value"},
	}
	d.allow == false
}

test_reference_listing_allowed if {
	d := secrets.decision with input as {
		"tool": {"name": "secrets"},
		"request": {"op": "list", "kind": "reference-only"},
	}
	d.allow == true
}

test_value_listing_denied if {
	d := secrets.decision with input as {
		"tool": {"name": "secrets"},
		"request": {"op": "list", "kind": "value"},
	}
	d.allow == false
}
