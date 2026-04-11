package agent.shell

import rego.v1

# Decides shell-command execution requests.
# Input shape:
#   { "tool": {"name": "shell"}, "request": {"command": "<str>", "cwd": "<str>"} }

default decision := {
	"allow": false,
	"require_approval": false,
	"reason": "default deny",
}

# Substring patterns that are unconditionally destructive.
dangerous_substrings := [
	"mkfs.",
	"mkfs ",
	"dd if=",
	"chmod -R 777 /",
	"chown -R root /",
	"curl | sh",
	"wget | sh",
	"curl | bash",
	"wget | bash",
	":(){ :|:& };:",
	"DROP DATABASE",
	"TRUNCATE TABLE",
	"shutdown ",
	"shutdown -",
	"reboot ",
	"reboot\n",
	"halt ",
	"init 0",
	"init 6",
	"> /dev/sd",
	"of=/dev/sd",
]

# Regex patterns for cases where word boundaries / variants matter.
# Catches: rm -rf /, rm -rf ~, rm -rf ., rm -rf *, rm -Rf X, rm -fr X, etc.
dangerous_regexes := [
	`(^|[\s;&|])rm\s+-[rRf]+\s+(/|~|\.|\*|\$HOME|/\*)(\s|$|;|&|\|)`,
	`(^|[\s;&|])rm\s+-[rRf]+\s+--no-preserve-root`,
]

privilege_escalation := [
	"sudo ",
	"sudo\t",
	"su -",
	"su root",
	"doas ",
	"pkexec ",
]

network_commands := [
	"curl ",
	"wget ",
	"nc ",
	"ssh ",
	"scp ",
	"rsync ",
	"ftp ",
	"sftp ",
]

package_install := [
	"pip install",
	"pip3 install",
	"uv pip install",
	"uv add",
	"poetry add",
	"npm install",
	"npm i ",
	"yarn add",
	"pnpm add",
	"cargo install",
	"cargo add",
	"go install",
	"go get",
	"apt install",
	"apt-get install",
	"apk add",
	"brew install",
	"gem install",
]

container_control := [
	"docker run",
	"docker rm",
	"docker rmi",
	"docker stop",
	"docker kill",
	"docker exec",
	"docker-compose down",
	"kubectl apply",
	"kubectl delete",
	"kubectl exec",
	"helm install",
	"helm upgrade",
	"helm uninstall",
]

cloud_cli := [
	"aws ",
	"gcloud ",
	"az ",
	"terraform apply",
	"terraform destroy",
	"pulumi up",
	"pulumi destroy",
]

# Commands that read process environment in ways that commonly disclose
# secret values (rather than just listing variable names). Substring match.
env_disclosure := [
	"env\n",
	"env;",
	"env|",
	"env |",
	"env >",
	"env $",
	"printenv",
	"export -p",
	"set | grep",
]

# Substrings that name a value commonly held in a secret env var.
secret_var_names := [
	"AWS_SECRET",
	"AWS_SESSION",
	"AWS_ACCESS_KEY",
	"GITHUB_TOKEN",
	"GH_TOKEN",
	"OPENAI_API_KEY",
	"ANTHROPIC_API_KEY",
	"GCP_SERVICE_ACCOUNT",
	"GOOGLE_APPLICATION_CREDENTIALS",
	"DATABASE_URL",
	"DB_PASSWORD",
	"PRIVATE_KEY",
	"SECRET_KEY",
	"API_KEY",
	"_PASSWORD",
	"_SECRET",
	"_TOKEN",
]

uses_dangerous if {
	some pattern in dangerous_substrings
	contains(input.request.command, pattern)
}

uses_dangerous if {
	some pattern in dangerous_regexes
	regex.match(pattern, input.request.command)
}

uses_privilege if {
	some pattern in privilege_escalation
	contains(input.request.command, pattern)
}

uses_network if {
	some cmd in network_commands
	contains(input.request.command, cmd)
}

uses_package_install if {
	some cmd in package_install
	contains(input.request.command, cmd)
}

uses_container_control if {
	some cmd in container_control
	contains(input.request.command, cmd)
}

uses_cloud_cli if {
	some cmd in cloud_cli
	contains(input.request.command, cmd)
}

# A command discloses secrets if it dumps environment OR explicitly references
# a known secret-shaped variable name.
uses_env_disclosure if {
	some pattern in env_disclosure
	contains(input.request.command, pattern)
}

uses_env_disclosure if {
	some name in secret_var_names
	contains(input.request.command, name)
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "destructive command on denylist",
} if {
	uses_dangerous
}

decision := {
	"allow": false,
	"require_approval": false,
	"reason": "command would disclose secret-shaped environment values",
} if {
	uses_env_disclosure
	not uses_dangerous
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "privilege escalation requires approval",
} if {
	uses_privilege
	not uses_dangerous
	not uses_env_disclosure
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "package installation requires approval",
} if {
	uses_package_install
	not uses_dangerous
	not uses_env_disclosure
	not uses_privilege
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "container/orchestration control requires approval",
} if {
	uses_container_control
	not uses_dangerous
	not uses_env_disclosure
	not uses_privilege
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "cloud CLI use requires approval",
} if {
	uses_cloud_cli
	not uses_dangerous
	not uses_env_disclosure
	not uses_privilege
}

decision := {
	"allow": false,
	"require_approval": true,
	"reason": "network egress requires approval",
} if {
	uses_network
	not uses_dangerous
	not uses_env_disclosure
	not uses_privilege
	not uses_package_install
	not uses_container_control
	not uses_cloud_cli
}

decision := {
	"allow": true,
	"require_approval": false,
	"reason": "local command, no flagged patterns",
} if {
	not uses_dangerous
	not uses_env_disclosure
	not uses_privilege
	not uses_network
	not uses_package_install
	not uses_container_control
	not uses_cloud_cli
}
