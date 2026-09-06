# IDSS Energy Community

IDSS Energy Community is a decentralized data storage and query prototype for local energy communities. Each peer owns an embedded EliasDB graph, participates in a libp2p and Kademlia DHT overlay, and executes EQL queries locally or across the overlay. Protocol Buffers carry query and result messages over libp2p streams.

Peers are honest-but-curious. The project provides query-time, per-peer policy enforcement but does not implement market clearing, pricing, blockchain or ledger integration, encryption at rest, or Byzantine fault tolerance.

## Energy Community Model

Sample data is generated at peer startup by `server/generate_data.py`. Node keys act as CIM `mRID` values.

| Node kind | Purpose |
|---|---|
| `Customer` | Community participant, including a manager |
| `UsagePoint`, `EndDevice` | Connection and metering assets |
| `GeneratingUnit`, `BatteryUnit` | PV generation and storage assets |
| `MeterReading` | Quarter-hourly active/reactive power, generation, and state-of-charge readings |
| `Offer`, `Bid`, `Trade` | Local flexibility orders and concluded trades |

The graph defines `owns`, `records`, `memberOf`, `places`, and `matches` edges. The data contract is in `server/energy_community_schema.json`. The generator supports `--num-customers`, `--days`, `--interval-minutes`, and `--seed`; startup derives the seed from the peer ID so a distributed query returns a real union of peer data.

## Requirements

- Go 1.23.6 or compatible Go 1.23 toolchain
- Python 3
- Git
- Docker Engine with the Docker Compose plugin, for containerized execution

`go.mod` and `go.sum` are Go dependency set. The repository vendors its Go modules, so builds use:

```sh
go test -mod=vendor ./...
```


## Run Peers

Build and start peers locally:

```sh
cd server
./start_peers.sh 3
```

`start_peers.sh` is the single supported local launcher. The retired `launch_peers.sh` is no longer used.

An optional second argument makes one peer the community manager:

```sh
./start_peers.sh 3 1
```

Pass generator options through the launcher to simulate larger communities or datasets. These settings apply independently to every peer:

```sh
# 100 peers, each with 1,000 customers and 30 days of 15-minute readings
./start_peers.sh 100 --customers 1000 --days 30 --interval-minutes 15

# 100 peers with peer 1 as manager and a smaller one-day dataset
./start_peers.sh 100 1 --customers 100 --days 1 --interval-minutes 15
```

Large runs require sufficient CPU, memory, disk space, and open-file limits. Start with a smaller dataset to establish a baseline, then increase peer and customer counts separately.

The manager peer loads `policy.manager.yaml` when it exists, otherwise `policy.default.yaml`. It keeps membership registration copies and settlement summaries locally; it is not a central raw-data store. Peer logs include the first peer multiaddress for the client.

Run one peer directly:

```sh
cd server
go run . -manager
```

### Community Topologies

The optional `manager_peer_index` selects one manager only. For example, this starts ten peers with peer 1 as the manager and nine customer peers:

```sh
./start_peers.sh 10 1
```

To run ten managers with additional customer peers, start the binaries separately after building them. Each manager keeps its own membership registry and settlement summaries; customer data remains on the customer peers.

```sh
cd server
go build -o idss_server .
for manager in $(seq 1 10); do
  ./idss_server -manager > "logs/manager-${manager}.log" 2>&1 &
done
for customer in $(seq 1 50); do
  ./idss_server > "logs/customer-${customer}.log" 2>&1 &
done
```

The current protocol does not assign a customer to one particular manager. A customer peer shares its mandatory `Customer` registration with managers it reaches through the overlay; each manager remains a peer rather than a central store.

For a manager-only community, start a single manager peer. Its self-registered `Customer` node is the community's only member:

```sh
cd server
go run . -manager
```

To start several manager-only peers, use the first loop above and omit the customer loop. Those manager peers discover one another, and each has only its own self-registration unless other registration messages arrive.

## Docker

Build and run a three-peer overlay on Linux or WSL with Docker Desktop WSL integration:

```sh
docker compose up --build --scale peer=3
```

The Compose configuration uses host networking to preserve existing ephemeral-port and mDNS discovery behavior. Stop peers with:

```sh
docker compose down
```

Use `docker compose down -v` to remove generated peer data. Run the client container with a peer multiaddress from the logs:

```sh
docker compose run --rm client -s <server_multiaddress>
```

Client XML results are saved to `client/results` on the host.

## Access Policies

Each peer loads `server/policy.default.yaml` by default. Use `-policy <path>` to choose a peer-specific policy:

```sh
go run . -policy policy.default.yaml
```

Rules grant raw records (`allow`), aggregate/count-only results (`aggregate`), or no local contribution (`deny`). Exact-kind rules override wildcard rules; equally specific matching rules choose the most restrictive decision.

```yaml
default: deny
rules:
  - kind: Customer
    roles: [member, manager, observer]
    decision: allow
  - kind: MeterReading
    roles: [manager, observer]
    decision: aggregate
  - kind: "*"
    roles: [observer]
    decision: aggregate
```

`Customer` registration, settlement aggregates, and concluded trades are mandatory sharing classes. Fine-grained readings, asset details, and open orders are discretionary. A peer querying data from itself bypasses its own policy.

## Submit Queries

Run the client from `client/`, supplying a peer multiaddress and requester role. The role defaults to `member`.

```sh
cd client
go run . -role <member|manager|observer> -s <server_multiaddress>
```

Every query is followed by a TTL in seconds. Local queries include `-l`; `add`, `update`, and `delete` always execute locally and do not enter the broadcast path.

```sh
# Member: registration and community orders
get Customer, 3
get Offer where status = "open", 7

# Observer: aggregate-only telemetry
get MeterReading where readingType = "activePower" show @sum(value), 7

# Manager: settlement records and compilation
get Trade, 7
settle 2026-09-06T00:00:00Z 2026-09-07T00:00:00Z, 10

# Local graph query
get Customer traverse owner:owns:asset:UsagePoint -l, 3
```

Traversal syntax is `<source role>:<relationship kind>:<destination role>:<destination kind>`. For example:

```sh
get Customer traverse owner:owns:asset:UsagePoint traverse point:records:reading:MeterReading, 7
```

Distributed aggregate functions `@sum`, `@avg`, `@min`, and `@max` are implemented. Query results are written as XML files under `client/results`.

## Metrics and Experiments

Prometheus metrics are exposed at `http://127.0.0.1:2112/metrics`. Metrics include query totals and duration, responding peers, returned rows, and policy decisions. With the local multi-peer launcher, only one peer can bind this host port at a time.

Run peer-count and TTL experiments:

```sh
./experiments/run_scaling.sh <max_peers> <repeats>
```

The script runs fixed EC queries from two through `max_peers` peers at multiple TTLs and writes `experiments/results/scaling.csv`. Each row contains peer count, query label, TTL, elapsed time, responding peers, and returned rows.
