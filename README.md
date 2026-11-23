# pouw-deploy

[![Jenkins](https://jenkins.147-175-151-18.sslip.io/buildStatus/icon?job=PoUW-ZK%2Fpouw-deploy%2Fmain&subject=nightly)](https://jenkins.147-175-151-18.sslip.io/job/PoUW-ZK/job/pouw-deploy/job/main/)

The whole PoUW-ZK network in one place: Docker Compose for all services,
monitoring (Prometheus, Grafana), the network tests and Jenkins, which tests
`main` every evening and deploys it to the staging server.

- [What runs where](#what-runs-where)
- [First use](#first-use)
- [Everyday development](#everyday-development)
- [Tests: what goes where and who runs it](#tests-what-goes-where-and-who-runs-it)
- [Monitoring](#monitoring)
- [Backups and logs](#backups-and-logs)
- [Commands](#commands)
- [Staging](#staging)
- [Troubleshooting](#troubleshooting)

## What runs where

| Service | Repository | Locally | Profile |
| --- | --- | --- | --- |
| Postgres | - | `docker compose exec postgres psql -U pouw` | always |
| Hasura (GraphQL of the explorer) | pouw-dashboard/hasura | <http://localhost:8081/v1/graphql> | always (starts after the indexer) |
| Prometheus | - | <http://localhost:9090> | always |
| Alertmanager (alerts by e-mail) | - | <http://localhost:9093> | always |
| Grafana | - | <http://localhost:3000> | always |
| backup (nightly dump of the database) | - | `BACKUP_DIR`, default `./backups` | always |
| node-1, node-2, node-3 (the devnet, see below) | pouw-node | inside the network only | always |
| light-node (verified read API) | pouw-node | inside the network only | always |
| indexer | pouw-indexer | <http://localhost:8083> | always |
| workload | pouw-workload | inside the network only | always |
| dashboard (explorer) | pouw-dashboard/web | <http://localhost:8082> | always |
| node-exporter, cAdvisor | - | Prometheus → Targets | `host-metrics` |
| Jenkins | - | <http://localhost:8080> | `jenkins` |
| Caddy (HTTPS) | - | server only | `proxy` |

Profiles are switched on in `.env` (`COMPOSE_PROFILES=...`). `make dev` adds
`network` itself. All ports are on `127.0.0.1` only, they can be changed in
`.env` (`HASURA_PORT`, `INDEXER_PORT`, ...).

For a one-hour read-only soak, run:

```bash
docker compose --profile soak run --rm workload-soak
```

It starts the `soak` scenario and fails on early termination,
read failures, or rejected arrivals. Inspect node and generator memory and
latency in Grafana separately; a successful command alone does not establish
that memory is stable.

For the mixed transfer test, start one of:

```bash
make load SCENARIO=transfers-steady   # 2 tx/s, constant, expected to stay clean
make load SCENARIO=transfers-spike    # alternating 10 tx/s burst phases
make load SCENARIO=transfers          # 20 tx/s stress test
```

The workload reads through `light-node` and submits round-robin to
`node-1`, `node-2`, and `node-3`. The same scenarios are available in the
Jenkins **Load test** job. Grafana observes a run; switching a scenario is done
through the `make` command, Jenkins, or `POST /api/v1/start`.

Logins: Grafana `admin` / `.secrets/grafana_admin_password`, Hasura admin
secret `.secrets/hasura_admin_secret` (queries without it get the read-only
role `anonymous`, like the explorer), Jenkins `admin` /
`.secrets/jenkins_admin_password`. The files are created by the first
`make up`, random for every laptop.

### The devnet

Three nodes of pouw-node on one chain:

- **Genesis.** The service `genesis` writes the chain spec once, when the volume
  `devnet` is empty: `devnet/chainspec.json` (a copy of
  `pouw-node/chainspec/devnet.json`) with the current time as
  `genesis.timestamp`. The target schedule counts from that time, so a chain
  started days after its genesis would mine a burst of easy blocks. Every test
  copy gets a genesis of its own, staging keeps its one in the volume.
- **Nodes.** Each has its own volume (RocksDB and the node key). All three
  mine, like the miners of Bitcoin, and compete for every block. The rewards
  go to test keys of the contracts: node-1 to the key with seed 32 × `0x01`
  (`NODE_MINER_ADDRESS`, it also holds the genesis allocation), node-2 to
  `miner-a` (32 × `0x0a`), node-3 to `miner-b` (32 × `0x0b`),
  see `contracts/fixtures/chain.json` in pouw-docs. node-1 is the bootnode:
  node-2 and node-3 dial it (`NODE_BOOTNODES`) and find each other through
  it. The indexer reads node-1, the workload reads the verified light node, and
  submissions rotate across all three full nodes. Prometheus scrapes all of
  them.
- **Sync.** Gossip (pouw-node#130) carries new blocks to the other nodes, the
  initial sync (pouw-node#128) brings a node that was down up to the tip.
  When two miners find a block at the same height, the chain with more work
  wins and the other block is orphaned (a reorg); the indexer follows it.

A new chain (new genesis, empty nodes and indexer database):
`./scripts/devnet-reset.sh`, it asks first. Needed after a change of
`devnet/chainspec.json` (keep it equal to
`../pouw-node/chainspec/devnet.json`), because a node refuses its database
under another genesis and the indexer stops syncing a chain that shares no
block with its database. On staging run it once after such a deploy.
`make seed` mixes fixture blocks into the database, never use it with the devnet.

## First use

### 1. Tools

| | Linux | macOS | Windows |
| --- | --- | --- | --- |
| Docker | Docker Engine with the compose plugin | Docker Desktop | Docker Desktop with the WSL 2 backend |
| Shell, `make`, `git` | from the distribution | Xcode Command Line Tools (`xcode-select --install`) | inside WSL 2 (Ubuntu): `sudo apt install make git openssl openssh-client` |
| GitHub CLI `gh` | [cli.github.com](https://cli.github.com) | `brew install gh` | in WSL: [cli.github.com](https://cli.github.com) |

Docker Compose must be **2.24.4 or newer** (`docker compose version`). Give
Docker at least 6 GB of RAM and keep 15 GB of free disk: the Rust services
compile inside Docker. Apple Silicon and x86 both work: the images in GHCR are
published for linux/amd64 and linux/arm64, `make dev` builds for your machine.

**Windows:** everything runs inside WSL 2, never in PowerShell or Git Bash.
In Docker Desktop turn on Settings → Resources → WSL integration for your
distribution. Clone into the WSL home (`~/...`), not into `/mnt/c/...`: it is
many times faster there and file permissions work. Repositories keep LF line
endings even when cloned on the Windows side (`.gitattributes`).

On Linux add yourself to the `docker` group once:
`sudo usermod -aG docker $USER`, then log in again.

### 2. All repositories into one folder

```bash
mkdir PoUW-ZK && cd PoUW-ZK
gh auth login
gh repo clone PoUW-ZK/.github
.github/scripts/sync-repos.sh       # clones pouw-node, pouw-indexer, ... next to it
```

`make dev` expects the service repositories next to `pouw-deploy`
(`../pouw-node`, `../pouw-indexer`, ...). Run `sync-repos.sh` again any time to
pull the latest `main` everywhere; it never touches a repository with your
changes or another branch checked out.

### 3. First start

```bash
cd pouw-deploy
cp .env.example .env
make dev            # builds every service from ../pouw-*, starts the whole network
make ps             # everything Up (healthy)
```

The first `make dev` takes 5-15 minutes (images are downloaded, Rust compiles),
then a minute or two. Open Grafana, Prometheus → Status → Targets and the
explorer from the table above.

```bash
make dev-test       # the same images, all tests in a separate copy of the network
make test-down
make down           # stop everything, data is kept for the next start
```

## Everyday development

| I want to | Command |
| --- | --- |
| see my change of a service in the whole network | `make dev` (from whatever branch each `../pouw-*` is on, uncommitted changes too) |
| test my change against the other services | `make dev-test`, results in `reports/`, then `make test-down` |
| the whole network from GHCR `:main`, without building | `make up` |
| logs of one service | `make logs SERVICE=indexer`, only the last hour: `SINCE=1h` |
| what is built from where | `build/versions.txt` |
| blocks in the explorer | nothing, the three nodes mine one about every 10 s from the start |
| a new chain (new genesis, empty nodes and indexer) | `./scripts/devnet-reset.sh` |
| start from an empty database | `docker compose down -v --remove-orphans` (deletes local data), `make dev` |
| work on one service alone (fast loop) | that repository's README, section Run locally |
| try a change of Jenkins | `COMPOSE_PROFILES=jenkins` and `JENKINS_LOCAL_BRANCH=<pushed branch>` in `.env`, `make up`, <http://localhost:8080> |

`make dev` = `make images up SRC=..`. An image that cannot be built from your
working copy (no `Dockerfile` yet) is taken from GHCR `:main`; when there is
none, the service is not started and `build/versions.txt` says why.

Without `SRC` (`make up`, Jenkins, staging) the services come from GHCR,
published from `main` by `docker.yml` of each repository. A new service stays
in the `network` profile until its image is published (none is there right
now). Then delete its `profiles: [network]` line in `compose.yml`, from then on
`make up`, the nightly test and staging run it.

## Tests: what goes where and who runs it

| Kind | Tests | Where | Runs | Blocks |
| --- | --- | --- | --- | --- |
| Unit | one function or module, no network, no other service | the service repository (see below) | GitHub Actions `ci-ok` on every PR | merge of the PR |
| Integration | one service with a real dependency (database, files) | the service repository, CI starts the dependency | GitHub Actions `ci-ok` on every PR | merge of the PR |
| Image | the `Dockerfile` builds, the container starts and is healthy | `ci-ok` step "Docker image starts" | every PR of the service | merge of the PR |
| Smoke | the deployed network is up: each service runs, talks to its database, Prometheus sees it | `e2e/smoke.sh` here | Jenkins (PR of pouw-deploy, every evening), `make test`, `make dev-test` | staging deploy |
| E2E of the devnet | the whole chain: the nodes share genesis and find each other, the chain grows, the nodes keep the same tip, more than one miner finds blocks, the indexer keeps up, Hasura serves the newest block, a subscription gets new blocks, the explorer answers | `e2e/test_devnet.py` here | Jenkins with the smoke tests, `make test` | staging deploy |
| E2E | behaviour across services through their APIs (submit a task → node mines → indexer → GraphQL) | `e2e/test_*.py` in the service repository | Jenkins with the smoke tests | staging deploy |

### Unit and integration tests (GitHub Actions, `ci-ok`)

`ci-ok` is the check required for every merge into `main`. Put the tests where
the tool of the language finds them, and they run there without anything else:

| Repository | Unit tests | Integration tests | `ci-ok` runs |
| --- | --- | --- | --- |
| pouw-node | `#[cfg(test)] mod tests` next to the code, `tests.rs` of the crate | `crates/*/tests/*.rs` | `cargo test --workspace --all-features`, clippy, fmt, doc, cargo-deny |
| pouw-indexer | `#[cfg(test)]` in `src/` | `tests/*.rs`, Postgres from `DATABASE_URL` (a service container in CI, `docker compose up -d` locally) | `cargo test`, clippy, fmt |
| pouw-workload | `src/test/java/**/*Test.java` (JUnit 5) | the same, WireMock instead of the node | `./gradlew build` (compile + test) |
| pouw-dashboard | `web/src/**/*.test.*` (`npm test`) | `hasura` job: indexer migrations + metadata | lint, test, build, npm audit, Hasura consistency |

Rules: a unit test never needs Docker or another service; when it does, it is
an integration test with the dependency started in the `ci-ok` job (see
`services:` in `pouw-indexer/.github/workflows/ci.yml`), or an e2e test.
Every repository with a `Dockerfile` also builds the image in `ci-ok` and
checks that it starts (pouw-dashboard: the Hasura image in its `hasura` job).

### Smoke tests (`e2e/smoke.sh` in this repository)

One check per line: description, compose service, shell command that runs
inside that service's container (`docker exec`, so no host ports are needed
and it works in Jenkins too):

```bash
check "indexer is healthy (database reachable)" indexer \
    'curl -fsS -o /dev/null http://localhost:8000/health'
```

- The command fails (exit code ≠ 0) = the check fails. Use what the image
  has (`curl`, `wget`, `psql`, ...).
- A check of a service from an optional profile (`network`, `host-metrics`)
  that does not run is skipped; a base service that does not run is a failure.
- Each check is one test in Jenkins → Tests (suite `smoke`).
- Smoke tests only ask "is it up and wired together". Behaviour belongs to e2e.

Run them against your running network with `./e2e/smoke.sh pouw`.

### E2E tests of the devnet (`e2e/test_devnet.py` in this repository)

pytest, run by `e2e/run.sh` like the e2e tests of the services, results in
`reports/devnet.xml` (suite `devnet` in Jenkins). They wait for real blocks
(about 10 s each) with generous timeouts, and a test that fails says what it
saw last. Against your running network: `./e2e/run.sh pouw`.

### E2E tests (`e2e/` in each service repository)

```text
pouw-indexer/e2e/
  run.sh              entry point called by `make test` (do not change the contract)
  conftest.py         skips the folder when there is no network (plain pytest in ci-ok),
                      fixture `service(name, port)`
  requirements.txt    pytest, requests, ...
  test_api.py         your tests
```

```python
# pouw-indexer/e2e/test_api.py
import requests

def test_health(service):
    r = requests.get(service("indexer", 8000) + "/health", timeout=10)
    assert r.status_code == 200
```

- File name `test_*.py`, functions `test_*` (pytest). Nothing else to register.
- Services are reached by their compose name and container port, never
  `localhost`: `service("indexer", 8000)`, `service("hasura", 8080)`,
  `service("node-1", 8000)`, `service("dashboard", 8080)`. The fixture skips
  the test when that service does not run (its profile is off, e.g. in Jenkins
  before its image is in GHCR), so a test never fails just for that.
- The tests run in a `python:3.12-slim` container attached to the network of
  the test copy. `E2E_PROJECT` holds the compose project name.
- Results go to JUnit XML in `$JUNIT_DIR` (done by `run.sh`), Jenkins shows
  them under Tests as a suite named after the repository.
- Another language: replace the body of `run.sh`, keep its contract (argument
  = compose project, JUnit XML into `$JUNIT_DIR`, exit code ≠ 0 = failure).

**When Jenkins picks them up:** Jenkins builds and tests `main` of every
service. A new e2e test is run from the first build after its PR is merged
into `main` (every PR of pouw-deploy and every evening). Before the merge, run
it yourself: `make dev-test` takes the tests from your working copies.

**What happens when one fails:** the evening build is red, staging stays on the
previous version and the failure e-mail lists the failed tests.

## Monitoring

Prometheus (`monitoring/prometheus/prometheus.yml`) has a target for every
service, also for one that does not run: such a target is `down`, not an error.

| Job | Target | Status |
| --- | --- | --- |
| `pouw-node` | `node-1:9100`, `node-2:9100`, `node-3:9100` (`/metrics`), label `instance="node-1"` ... | the devnet |
| `pouw-light-node` | `light-node:8000/metrics` | the verified read service |
| `pouw-indexer` | `indexer:8000/metrics` | down until the indexer serves `/metrics` |
| `pouw-workload` | `workload:8001/metrics` | down until the workload serves `/metrics` |
| `node-exporter` | the machine (CPU, memory, disk) | profile `host-metrics` |
| `cadvisor` | every container (CPU, memory, network by name) | profile `host-metrics` |

A service that adds `/metrics` on that port shows up without any change here.
On the server `host-metrics` is on. On a laptop it is optional; on macOS and
Windows node-exporter measures Docker's Linux VM, not the laptop.

### Grafana

Dashboards are code: JSON in `monitoring/grafana/dashboards/`, loaded into the
folder **PoUW** when Grafana starts, no clicking.

| Dashboard | Shows | Data |
| --- | --- | --- |
| PoUW · Network | height, block time, transactions/s, proofs per block, miners, latest blocks; per node height, peers, mempool, verification time | indexer database; node metrics of `node-api.md` (`pouw_node_*`) |
| PoUW · Services | which targets are up, indexer lag (node vs indexer height, block-to-database delay), CPU, memory, network and restarts of every container | Prometheus, cAdvisor, indexer database |
| PoUW · Server | CPU, RAM, disks, disk I/O, network, load | node-exporter |

The stats of the last 100 blocks do not depend on the time range, so the
blocks of the devnet are visible right away. Panels of metrics that
a service does not serve yet stay empty until it does.

The datasource **Indexer (Postgres)** reads the indexer tables as the user
`grafana` (ADR-0008), which can only read: SELECT on the tables, every
transaction read-only. `grafana-db-user` creates it on every start
(`monitoring/postgres/grafana-reader.sql`), its password is the secret
`grafana_db_password`.

To change a dashboard: edit it in Grafana, then Share → Export → Save to file
(or Dashboard settings → JSON Model) and replace the file in
`monitoring/grafana/dashboards/`. Keep `uid`, the datasource uids
`prometheus` and `indexer`, and run `make up` to check it loads. A dashboard
saved only in the UI is lost when the Grafana volume is recreated.

### Panels embedded in the explorer

Visitors without a login are Viewers of a separate organization, **Public**. It
has only the dashboards in `monitoring/grafana/public-org/dashboards/` and only
Prometheus. The team dashboards and the database stay in the main organization
behind the password.

Keep it that way: a Viewer can send any query to every datasource of its
organization, not only the queries of the panels. So never add the Postgres
datasource to Public, and remember that anyone can read all metrics in
Prometheus. Datasource permissions exist only in Grafana Enterprise.

`monitoring/grafana/public-org/setup.sh` creates the organization through the
API on every start of Grafana, and the container is healthy only after it
succeeds. To add a panel, change the JSON there and run `make up`. To embed it:

```html
<iframe src="https://grafana.147-175-151-18.sslip.io/d-solo/pouw-public/x?orgId=2&panelId=1"></iframe>
```

Through the proxy only the explorer (`EXPLORER_HOST`) may embed Grafana.

### Alerts

Prometheus evaluates the rules in `monitoring/prometheus/rules/` and sends the
firing alerts to Alertmanager, which e-mails them to `ALERT_EMAIL` through the
SMTP account of Jenkins (`SMTP_*` in `.env`, username and password in `pass`).
Without `SMTP_HOST` or `ALERT_EMAIL` (a laptop, the test copies) the alerts are
only listed on <http://localhost:9093>.

| Alert | Fires when |
| --- | --- |
| `NodeDown` | Prometheus has not reached a node for 2 minutes |
| `ServiceDown` | the same for the indexer or the workload |
| `ChainStalled` | the height of no node changed for 10 minutes |
| `IndexerLagging` | the indexer is more than 10 blocks behind the node for 5 minutes |
| `DiskAlmostFull` | a disk of the server is more than 80 % full for 10 minutes |
| `ContainerRestarting` | a container restarted more than twice in 15 minutes |

One e-mail per alert name 30 s after it starts, a reminder every 12 hours while
it lasts and one when it is resolved. `make test-alert` sends a test alert
through the same path. `make check` runs the tests of the rules in
`monitoring/prometheus/tests/`: a new rule gets a case where it fires and one
where it stays quiet. Prometheus reloads the rules on every `make up`.

Silence an alert during planned work:

```bash
docker compose exec alertmanager amtool silence add alertname=NodeDown \
  --duration=2h --comment="node upgrade" --alertmanager.url=http://localhost:9093
```

## Backups and logs

The service `backup` dumps the indexer database every night at `BACKUP_AT`
(UTC, default 02:00) into `BACKUP_DIR` on the host, outside the Docker volumes,
and deletes dumps older than 7 days. It makes one right away when the newest
is older than 20 hours, e.g. after the first start. A dump that fails ends the
container, Docker restarts it over and over and `ContainerRestarting` fires.

```bash
make backup                       # a dump now
make restore-test                 # trial restore of the newest dump into a separate database
./scripts/restore.sh --replace pouw-20261116T020000Z.dump   # replace the live database
```

`make test` (and so the nightly build) makes a dump of the test copy and
restores it every time. After a real restore the indexer continues from the
last block in the dump and fetches the newer ones from the node; without any
dump it can rebuild the database from the node too, only slower.

Docker keeps at most 3 log files of 10 MB per container (`x-logging` in
`compose.yml`), so logs never fill the disk. Read them with
`make logs SERVICE=indexer`, `SINCE=1h` for the last hour.

## Commands

```text
make help         List of commands
make dev          Build the services from ../pouw-* and start the whole network locally
make dev-test     Build the services from ../pouw-* and test them in a separate copy
make secrets      Prepare secrets (random locally, from pass on the server)
make up           Start services according to COMPOSE_PROFILES
make down         Stop services of all profiles (data is kept)
make restart      Restart services, e.g. after a password change in pass
make seed         Fixture blocks of pouw-indexer into the database; never with the devnet, its sync stops
make ps           Service status
make logs         Logs of a service, e.g. make logs SERVICE=indexer [SINCE=1h] (without SERVICE all)
make check        Validate compose, Prometheus with tests of its alerts, Alertmanager and the Caddyfile
make images       Build service images from main (or SRC=..), e.g. make images test IMAGE_TAG=local
make backup       Dump the database into BACKUP_DIR now (the service backup does it every night)
make restore-test Trial restore of the newest dump into a separate database (DUMP=<file> another)
make test-alert   Send a test alert; with SMTP_HOST and ALERT_EMAIL it arrives by e-mail
make test         Smoke and e2e tests in a separate copy of the network (results in reports/)
make test-down    Remove the test copy of the network
```

## Staging

| | |
| --- | --- |
| Jenkins | <https://jenkins.147-175-151-18.sslip.io> (GitHub login) |
| Grafana | <https://grafana.147-175-151-18.sslip.io> |
| Explorer | <https://explorer.147-175-151-18.sslip.io> (GraphQL on `/v1/graphql`, the rest of Hasura is not reachable from outside) |

Changes reach the server only through `main`: every evening Jenkins builds
`main` of all services, runs the smoke and e2e tests and, if they pass, the
Deploy workflow deploys exactly those versions. After `make up` the deploy runs
the smoke tests; if they fail, the previous version is restored. Manual deploy, rollback,
restart and status: GitHub → Actions → Deploy. Server setup, passwords and
operations are in [pouw-docs → Server](https://pouw-zk.github.io/pouw-docs/server/).

Passwords never go into git or `.env`. Jenkins is configured only through
`jenkins/casc/`, changes in its UI are lost on restart.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `port is already allocated` | another program uses the port, set e.g. `GRAFANA_PORT=3001` in `.env` |
| `make dev`: `no ../pouw-xxx` | the repository is not cloned next to pouw-deploy: `.github/scripts/sync-repos.sh` |
| build fails with `no space left on device`, Docker hangs | free disk space; `docker builder prune` removes the build cache |
| a Rust build is killed (`signal: 9`) | give Docker more memory (Docker Desktop → Settings → Resources) |
| `'bash\r': No such file or directory` | the repository was cloned with CRLF before `.gitattributes`: `git rm --cached -r . && git reset --hard` |
| Windows: everything is very slow | the clone is under `/mnt/c`, clone it into the WSL home |
| `unknown tag !override` / `!reset` | Docker Compose older than 2.24.4, update Docker |
| Grafana shows no dashboards after a `git checkout` / rebase | the running container still mounts the old directory: `make restart` |
| a service is `unhealthy` | `make logs SERVICE=<service>`; `make dev` again after the fix |
| something is wrong after an update | `docker compose down -v --remove-orphans` (deletes local data), `make dev` |
