package agent.network

import rego.v1

# Decides outbound network requests.
# Input shape:
#   { "tool": {"name": "network"},
#     "request": {"url": "<str>", "host": "<str>", "method": "<str>"} }
#
# Project allowlist is supplied as data:
#   data.agent.network.allowed_hosts := ["github.com", "pypi.org", ...]

default decision := {
	"allow": false,
	"require_approval": true,
	"reason": "host not on project allowlist",
}

default allowed_hosts := [
	"github.com",
	"raw.githubusercontent.com",
	"api.github.com",
	"pypi.org",
	"files.pythonhosted.org",
	"registry.npmjs.org",
	"crates.io",
	"proxy.golang.org",
	"deb.debian.org",
	"security.debian.org",
	"host.docker.internal",
	"localhost",
	"127.0.0.1",
]

host_allowed if {
	some h in allowed_hosts
	input.request.host == h
}

host_allowed if {
	some h in allowed_hosts
	endswith(input.request.host, concat("", [".", h]))
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "host on allowlist",
} if {
	host_allowed
}
