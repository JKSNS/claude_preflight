package agent.shell_test

import data.agent.shell
import rego.v1

mk(cmd) := {
	"tool": {"name": "shell"},
	"request": {"command": cmd, "cwd": "/work"},
}

test_dangerous_rm if {
	d := shell.decision with input as mk("rm -rf /")
	d.allow == false
	d.require_approval == false
}

test_dangerous_drop_database if {
	d := shell.decision with input as mk("psql -c 'DROP DATABASE prod'")
	d.allow == false
}

test_privilege_sudo if {
	d := shell.decision with input as mk("sudo apt update")
	d.allow == false
	d.require_approval == true
}

test_pip_install_requires_approval if {
	d := shell.decision with input as mk("pip install requests")
	d.require_approval == true
}

test_npm_install_requires_approval if {
	d := shell.decision with input as mk("npm install left-pad")
	d.require_approval == true
}

test_kubectl_apply_requires_approval if {
	d := shell.decision with input as mk("kubectl apply -f deploy.yaml")
	d.require_approval == true
}

test_aws_cli_requires_approval if {
	d := shell.decision with input as mk("aws s3 ls")
	d.require_approval == true
}

test_curl_requires_approval if {
	d := shell.decision with input as mk("curl https://example.com")
	d.require_approval == true
}

test_ls_allowed if {
	d := shell.decision with input as mk("ls -la")
	d.allow == true
}

test_pytest_allowed if {
	d := shell.decision with input as mk("python -m pytest")
	d.allow == true
}

test_rm_rf_dot_denied if {
	d := shell.decision with input as mk("rm -rf .")
	d.allow == false
	d.require_approval == false
}

test_rm_rf_star_denied if {
	d := shell.decision with input as mk("rm -rf *")
	d.allow == false
	d.require_approval == false
}

test_rm_rf_no_preserve_root_denied if {
	d := shell.decision with input as mk("rm -rf --no-preserve-root /tmp/foo")
	d.allow == false
}

test_rm_fr_dot_denied if {
	d := shell.decision with input as mk("rm -fr .")
	d.allow == false
}

test_mkfs_ext4_denied if {
	d := shell.decision with input as mk("mkfs.ext4 /dev/sdb1")
	d.allow == false
}

test_dd_to_sdx_denied if {
	d := shell.decision with input as mk("dd if=/dev/zero of=/dev/sda bs=1M")
	d.allow == false
}

test_printenv_secret_denied if {
	d := shell.decision with input as mk("printenv AWS_SECRET_ACCESS_KEY")
	d.allow == false
}

test_echo_secret_var_denied if {
	d := shell.decision with input as mk("echo $GITHUB_TOKEN")
	d.allow == false
}

test_env_dump_denied if {
	d := shell.decision with input as mk("env | grep TOKEN")
	d.allow == false
}

test_export_p_denied if {
	d := shell.decision with input as mk("export -p")
	d.allow == false
}

test_remove_normal_file_allowed if {
	# Removing a single named file is fine; only the recursive/wildcard
	# / cwd / home variants are blocked.
	d := shell.decision with input as mk("rm /tmp/build/output.log")
	d.allow == true
}
