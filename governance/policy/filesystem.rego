package agent.filesystem

import rego.v1

# Decides filesystem read/write/delete requests.
# Input shape:
#   { "tool": {"name": "filesystem"},
#     "request": {"op": "read|write|delete", "path": "<str>"} }

default decision := {
	"allow": false,
	"require_approval": false,
	"reason": "default deny",
}

sensitive_paths := [
	"/etc/",
	"/root/",
	"/var/run/docker.sock",
	"/.ssh/",
	"/.aws/",
	"/.gcp/",
	"/.azure/",
	"/.kube/",
	"/.gnupg/",
]

secret_patterns := [
	".env",
	".env.local",
	".env.production",
	"credentials.json",
	"secrets.yaml",
	"secrets.yml",
	"id_rsa",
	"id_ed25519",
	".pem",
	".key",
	".pfx",
	".p12",
]

approval_paths := [
	".github/workflows/",
	"Dockerfile",
	"docker-compose",
	"package-lock.json",
	"yarn.lock",
	"pnpm-lock.yaml",
	"Cargo.lock",
	"poetry.lock",
	"uv.lock",
	"requirements.txt",
	"package.json",
	"pyproject.toml",
	"Cargo.toml",
	"terraform",
	"helm",
	"kustomization",
	".git/hooks/",
	"policy/",
	"governance/",
	"CONSTITUTION",
]

deny_write_paths := [
	".git/objects",
	".git/refs",
	".git/HEAD",
]

is_sensitive if {
	some p in sensitive_paths
	contains(input.request.path, p)
}

is_secret if {
	some p in secret_patterns
	endswith(input.request.path, p)
}

is_secret if {
	some p in secret_patterns
	contains(input.request.path, concat("", ["/", p]))
}

needs_approval if {
	some p in approval_paths
	contains(input.request.path, p)
}

is_protected_write if {
	some p in deny_write_paths
	contains(input.request.path, p)
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "secret file; access denied",
} if {
	is_secret
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "sensitive system path; access denied",
} if {
	is_sensitive
	not input.request.op == "read"
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "protected git internals",
} if {
	is_protected_write
	input.request.op != "read"
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "change to high-impact file requires approval",
} if {
	input.request.op != "read"
	needs_approval
	not is_secret
	not is_sensitive
	not is_protected_write
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "read-only access to non-secret path",
} if {
	input.request.op == "read"
	not is_secret
	not is_sensitive
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "write to non-protected path",
} if {
	input.request.op != "read"
	not is_secret
	not is_sensitive
	not is_protected_write
	not needs_approval
}
