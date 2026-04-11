package agent

import rego.v1

# Top-level dispatcher. Routes the request to the subpackage that owns
# the tool/action and returns a single normalized decision object:
#   { allow, require_approval, reason, matched }

default decide := {
	"allow": false,
	"require_approval": false,
	"reason": "no policy matched; default deny",
	"matched": [],
}

decide := d if {
	input.tool.name == "shell"
	base := data.agent.shell.decision
	d := object.union(base, {"matched": ["shell"]})
}

decide := d if {
	input.tool.name == "filesystem"
	base := data.agent.filesystem.decision
	d := object.union(base, {"matched": ["filesystem"]})
}

decide := d if {
	input.tool.name == "network"
	base := data.agent.network.decision
	d := object.union(base, {"matched": ["network"]})
}

decide := d if {
	input.tool.name == "secrets"
	base := data.agent.secrets.decision
	d := object.union(base, {"matched": ["secrets"]})
}

decide := d if {
	input.tool.name == "dependencies"
	base := data.agent.dependencies.decision
	d := object.union(base, {"matched": ["dependencies"]})
}

decide := d if {
	input.tool.name == "git"
	base := data.agent.git.decision
	d := object.union(base, {"matched": ["git"]})
}

decide := d if {
	input.tool.name == "deployment"
	base := data.agent.deployment.decision
	d := object.union(base, {"matched": ["deployment"]})
}

decide := d if {
	input.tool.name == "review"
	base := data.agent.review.decision
	d := object.union(base, {"matched": ["review"]})
}
