# Dependency update and security automation

This folder configures **visibility and review**, not automatic merges or
publishing. Cargo, Gradle and GitHub Actions version updates are proposed by
Dependabot. The separate `dependency-security.yml` workflow runs an isolated
RustSec advisory check daily and whenever the Rust manifests/lockfile change.

**Operational requirements**

- Enable GitHub Dependency Graph, Dependabot Alerts and Dependabot Security
  Updates in repository settings. The YAML file alone cannot activate alerts.
- Version-update PRs are bounded to 2 open PRs per ecosystem, with patch/minor
  versions grouped. Major updates remain separate. Dependabot security updates
  may have independent behavior and must be reviewed immediately.
- A RustSec run is a vulnerability/advisory signal, **not** a guarantee that
  every dependency is current, correct, legal for F-Droid or safe.
- Do not skip required Android/Rust/Apple gates for Dependabot PRs, nor add
  automatic full F-Droid, device or release builds to this security workflow.
- Before merging changes to `rustls-platform-verifier`, `jni`, `uniffi`,
  `ureq` or other major dependency versions, assess API changes, rebuild and
  validate all affected clients, and preserve Android system/user CA trust.
- GitHub scheduled workflows execute from the default branch only.
  Dependabot version updates must also be activated on the default branch.
  After migration, install the same setup in **FluxNews**, where the
  authoritative development/release workflow will reside.

Policy detail: `docs/DEPENDENCY_MAINTENANCE.md` (documentation PR #67).
