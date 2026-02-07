# Testing (GdUnit4)

This project uses a vendored GdUnit4-compatible runner under `player-created-world/addons/gdUnit4/` and keeps all test assets under `res://test/`.

## Quick Start

Set `GODOT_BIN` to your Godot 4.6 executable, then run:

```bash
./scripts/run_tests.sh all
```

```powershell
.\scripts\run_tests.ps1 -Mode all
```

## Modes

- Unit tests only:
  - `./scripts/run_tests.sh unit`
  - `.\scripts\run_tests.ps1 -Mode unit`
- Integration tests only:
  - `./scripts/run_tests.sh integration`
  - `.\scripts\run_tests.ps1 -Mode integration`
- All tests:
  - `./scripts/run_tests.sh all`
  - `.\scripts\run_tests.ps1 -Mode all`

## Restart Server + Run Tests

If you need a fresh control plane before running tests:

- `./scripts/restart_server_and_tests.sh all`
- `.\scripts\restart_server_and_tests.ps1 -Mode all -Port 5000`

## Output and Logs

- JUnit XML: `artifacts/test-results/junit.xml`
- Logs: `artifacts/test-logs/`
  - `server.log`, `client1.log`, `client2.log`
  - Event traces: `*.events.jsonl`

## Adding New Unit Tests

1. Add a new `*_test.gd` file under `player-created-world/test/unit/`.
2. Extend `GdUnitTestSuite` and add methods named `test_*`.

Example:

```gdscript
extends GdUnitTestSuite

func test_example() -> void:
	assert_eq(1, 1)
```

## Adding New Integration Tests

1. Add a new `*_test.gd` file under `player-created-world/test/integration/`.
2. Use `OS.create_process()` to launch headless server/client instances and enforce timeouts.
3. Write logs under `res://artifacts/test-logs/` and emit JSONL events to validate success.

## Test Fixtures

Integration fixtures live under `res://test/fixtures/net/`:

- `TestServer.tscn` / `TestServer.gd` - headless ENet server
- `TestClient.tscn` / `TestClient.gd` - headless ENet client
- `ScenarioRunner.gd` - deterministic action/state logic
- `NetAssertions.gd` - stable state hashing
- `TestServerRunner.gd`, `TestClientRunner.gd` - CLI entrypoints

## Notes

- Tests are deterministic and headless; no graphics/audio required.
- Ports are randomized per integration run.
- The test runner uses `res://addons/gdUnit4/bin/GdUnitRunner.gd`.
