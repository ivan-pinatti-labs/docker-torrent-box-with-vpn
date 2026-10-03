# Security Vulnerabilities

Please report through the GitHub Report Security Issues page:
<https://github.com/ivan-pinatti-labs/docker-torrent-box-with-vpn/security/advisories/new>

## What scans what

| Code | Scanned by | Where |
| --- | --- | --- |
| Shell (`*.sh`, `*.bash`) | shellcheck, shfmt, shebang checks | `.pre-commit-config.yaml`, every commit |
| Python | ruff, bandit, check-ast, debug-statements | `.pre-commit-config.yaml`, every commit |
| Dockerfiles | hadolint | `.pre-commit-config.yaml`, every commit |
| `.github/workflows/*` | actionlint | `.pre-commit-config.yaml`, every commit |
| Everything | detect-secrets, gitleaks | `.pre-commit-config.yaml`, every commit |
| Everything | checkov, trivy (misconfiguration and vulnerabilities) | `.pre-commit-config.yaml`, every push |
| Everything SonarQube Cloud has an analyzer for: shell, Python, the Dockerfiles, the homepage JavaScript, YAML, `.github/workflows/*`, secrets | SonarQube Cloud, Sonar way quality gate, plus 100% coverage from `make coverage` | `sonarqube.yml`, every pull request from a branch of this repository and every push to `main` |
| Trivy, Checkov, Gitleaks, Hadolint and zizmor findings | The Security tab, as SARIF reports | `Security Reports` in `pull-request-validation.yml`, reporting only |

Two layers, deliberately. The pre-commit hooks fail before anything is
pushed; SonarQube Cloud reads the whole repository at once on every pull
request from a branch of this repository (a fork's pull request cannot
receive its token, so a maintainer pushes the branch here first). Neither
replaces the other: SonarQube's shell rules are few and different from
shellcheck's, not a superset of them. What it leaves out (vendored patches,
third party application config, runtime mount points) and why is in
`sonar-project.properties`.

SonarQube Cloud replaced CodeQL here, both `codeql.yml` and GitHub's managed
Code Quality setup. CodeQL only ever analyzed the Python, and it cannot read
shell or a Dockerfile at all. Its old alerts in the Security tab stop
updating; they are history, not current findings. The `Security Reports`
SARIF uploads above are unaffected and keep reporting there.

The quality gate is the Free plan's built in "Sonar way", which cannot be
edited. It fails when new code is rated below A for reliability, security or
maintainability, when a new security hotspot is left unreviewed, when less
than 80% of new code is covered, or when more than 3% of it is duplicated.
On a change of fewer than 20 new lines, SonarQube Cloud skips the coverage
and duplication conditions. This repository holds its own code above that
floor: `make coverage`, run by the same job before the scan, requires 100%
of the lines and branches of the Python and the homepage JavaScript and 100%
of the lines of the unit tested shell scripts, hands SonarQube the reports,
and fails the job otherwise, small change or not. Editing a line makes it
new code, so an old finding on that line counts against the pull request.
Fix what a rule asks for, or mark the single finding false positive or
accepted in SonarQube Cloud with the reason; no `# NOSONAR` comments.
