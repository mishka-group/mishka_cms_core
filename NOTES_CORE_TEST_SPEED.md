> **Before fixing anything:** research online first. Read the current articles on making Elixir test suites fast (the sources below are the starting point), weigh every option in this file against what is true at that time, and only then fix.

# mishka_cms_core: why the test suite is slow in CI

Researched 2026-10-09 against `mishka-group/mishka_cms_core` master. Nothing was changed. Every path below is relative to this repo's root.

## Where the time goes

CI is one job (`.github/workflows/ci.yml`): one Elixir/OTP version (1.20.4 / 29.1.1), no matrix, no partitions, a single `mix test --warnings-as-errors` (line 69). The repo is private, so `ubuntu-latest` is a **2-vCPU** runner (`max_cases: 4` in the log).

Measured over 27 successful runs:

| Step | Median | Range |
|---|---|---|
| Whole job | **21.0 min** | 15.7–26.1 min |
| `mix test` | **1008 s (80%)** | 672–1069 s |
| `mix compile --warnings-as-errors` | 147 s | 4–433 s |
| `mix format --check-formatted` | 59 s | 36–62 s |
| postgres:18 pull | 25 s | 22–34 s |
| checkout, setup-beam, cache, deps.get | ~15 s | |
| `ash.codegen` | 6 s | |

- The longest run was 26.1 min, on a cold cache. "28 min" was not reproduced; it probably includes queue time or a re-run.
- CI is about **1.8× slower than local**. Local: 541 s (`Finished in 550.8 seconds (28.2s async, 522.5s sync)`, 10084 tests). Every "CI est." below is local × 1.8.
- The CI "async" phase (90–133 s) is mostly **compiling the 391 test files** (185k lines). `mix test --only nosuchtag` alone takes 22.8 s locally, 18.3 s of it for `builder_live_test.exs`.

## Root causes, biggest first

### 1. 96% of test time is serial
- 109 async modules (25%) hold 21.8 s; 328 sync modules (75%) hold **509.6 s**.
- ExUnit runs sync modules one after another, so more cores do not help this part.
- `DataCase` opens `start_owner!(shared: not tags[:async])` (`test/support/data_case.ex:48`).

Why the modules are sync (categories overlap):

| Shared state | Files | Time |
|---|---|---|
| Runtime module compile (`ModuleCompiler`, `create_component!`) | 101 | 366 s |
| Global ETS states (`SiteState`, `SettingsState`, `AssetsState`, …) | 131 | 333 s |
| `Phoenix.LiveViewTest` | 58 | 218 s |
| `Application.put_env` (163 call sites) | 60 | 217 s |
| Tailwind / esbuild binaries | 20 | 199 s |
| MishkaInstaller plugins and events (Mnesia) | 44 | 189 s |
| PubSub | 11 | 189 s |
| Filesystem writes | 29 | 151 s |

`SiteState.clear` is in 61 files and a fixed `"localhost"` host in 57. Only 63 sync files (28 s, 5%) touch none of these, so turning the easy ones async buys almost nothing.

### 2. One module is 4 minutes
`BuilderLiveTest` (`test/mishka_cms_core_web/live/builder_live_test.exs`, 23.6k lines) has **1019 tests and takes 128 s** (~4 min CI est.). Tests in one module never run concurrently, so only splitting the file lets it run in parallel. Its fastest test is 36.6 ms, so per-test setup is at most 37 ms.

### 3. The CI cache never refreshes (~2 min per run)
- The key is only `hashFiles(mix.lock, .tool-versions)` (ci.yml:52).
- GitHub caches are immutable per key (`Cache hit occurred on the primary key … not saving cache`), so `_build` is frozen at the first run of 2026-10-06.
- Every run prints `Compiling 542 files` plus 43 + 28 Gervaz files. A run close to the frozen state compiled 85 files in 4 s.
- The `../mishka_gervaz` path dep is a fresh `master` checkout each run, which is a likely trigger of the full recompile (not proven).

### 4. The rest
| Cause | Local | Where |
|---|---|---|
| `PagePropertyTest`: StreamData's default of 100 runs, no `config :stream_data` | 52.8 s | `deps/stream_data/mix.exs:48` |
| Kit installed in **every** test's `setup` (~3.4 s each) | ~55 s | `DropRenderableTest` line 118, `HookNamespaceTest`, `WizardRenderableTest`, `UiKitUpgradeTest` |
| Real Tailwind CLI per test (0.8–3.9 s per call) | ~70 s | `tailwind_compiler.ex:1723`, used by `TailwindCompilerTest`, `ClassesTest`, `SharedBaseStalenessTest` |
| Format check runs serially in the same job | 59 s CI | ci.yml |
| No `concurrency` cancel: a PR run is followed by an identical master push run | — | ci.yml |

Top modules, local seconds: `BuilderLiveTest` 127.9 · `PagePropertyTest` 52.8 · `DropRenderableTest` 31.2 · `TailwindCompilerTest` 30.1 · `ClassesTest` 29.9 · `Install.AuthContentTest` 24.4 · `EditorSectionsTest` 13.2 · `HookNamespaceTest` 12.1 · `EditorToolsTest` 10.2 · `RuntimeSectionRulesTest` 8.5.

The top 5 files are 51% of all test time, and the top 25 are 76%.

### Ruled out
- `Process.sleep`: 10 calls, under 0.5 s in total. `refute_receive`: 45 sites, under 9 s.
- Already set: bcrypt `log_rounds: 1` (test.exs:70), Oban `testing: :manual` (test.exs:52), logger `:warning` (test.exs:72), Ash `disable_async?: true` (test.exs:47).
- Fixtures are cheap: `create_site!` 0.4 ms, `create_page!` 22.8 ms, `create_user_with_permissions!` 10 ms.

## What to change

### CI only
| # | Change | Saves (CI est.) | Note |
|---|---|---|---|
| A | Cache key `…-${{ hashFiles(...) }}-${{ github.sha }}` plus `restore-keys` set to the prefix; consider adding the Gervaz SHA | ~2 min | ~112 MB per entry; within the 10 GB / 7-day limit |
| B | Partition matrix: `MIX_TEST_PARTITION=${{ matrix.p }} mix test --partitions 4`. `config/test.exs:10` already names the DB per partition | test step → ~8–9 min | Mix splits round-robin by file, not by duration. Do one trial run to catch order-dependent tests. About +30% runner minutes |
| C | `format --check-formatted` as its own parallel job; `concurrency: {group: ci-${{ github.ref }}, cancel-in-progress: true}` | ~1 min | |
| D | Postgres on tmpfs / `fsync=off` | under 2% | Skip: the sandbox never commits |
| E | Bigger runner | small | Skip for now: the serial part does not scale with cores |

Simulated partition split, using the measured per-file times:

| Split | Longest partition (local) | CI est. |
|---|---|---|
| `--partitions 4` | 287 s | ~520 s |
| `--partitions 6` | 219 s | ~400 s |
| P=4 after splitting `builder_live_test` into 4 files | 192 s | ~350 s |
| P=4 with balanced explicit file lists | 133 s | ~240 s |

Each partition job also pays ~1.5–2.5 min of fixed setup.

### Test changes
| # | Change | Saves | Note |
|---|---|---|---|
| T1 | `config :stream_data, max_runs: 25`, or more on CI only, as StreamData's own docs suggest (`if System.get_env("CI"), do: 1_000, else: 50`) | 52.8 s → **10.5 s** measured | One line. Fewer random cases per run |
| T2 | Split `builder_live_test.exs` into ~6 files by `describe`, with the shared helpers moved to a support module | enables balanced partitions | Saves nothing on its own |
| T3 | Install the kit once per module, not in each test's `setup` | ~15–25 s local | |
| T4 | Fake the Tailwind runner where only the wiring is tested; keep ~5 tests on the real binary | ~40–50 s local | Some loss of fidelity |
| T5 | Async conversion: unique hosts instead of `localhost`, per-process config instead of `Application.put_env`, no global `SiteState.clear`, `$callers` allowances instead of the shared sandbox | ≤ 2× on 2 vCPU | Do last. The `DataCase` doc says the dashboard's async loaders need shared mode |

## Plan (estimates, not yet measured on CI)
1. A + C + T1: ~21 → ~17 min.
2. B with plain `--partitions 4`: **~10 min**. One trial run for order-dependent tests.
3. T2, then P=4–6: **~6–7 min**. Balanced file lists, if needed: ~5–6 min.
4. T3 and T4, then T5 for the long term.

## Still unconfirmed
- The exact reason for the full recompile (inferred from logs).
- The tmpfs path for the postgres:18 image.
- Whether async `LiveViewTest` works with the sandbox without custom `$callers` wiring.

## Sources
- GitHub dependency caching ("You cannot change the contents of an existing cache"): https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching
- Elixir CI compile caching issues: https://elixirforum.com/t/github-actions-compilation-caching-issues/45946
- `mix test --partitions`: https://mix.hexdocs.pm/Mix.Tasks.Test.html
- 20 → 6 min with partitions: https://elixirforum.com/t/making-large-elixir-test-suites-faster-with-check/75617
- 15 → 4 min: https://ftes.de/articles/2025-02-14-elixir-ci-on-speed
- 15 → 3 min with caching and split batches: https://dev.to/cblavier/how-we-improved-our-elixir-build-speed-by-5x-3651
- Ecto SQL Sandbox (async limits, unique values "2x to 3x faster"): https://ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html
- ExUnit.Case ("Tests in the same module never run concurrently"; `:group`): https://ex-unit.hexdocs.pm/ExUnit.Case.html
- Sharding global state per test: https://multiverses.hexdocs.pm/Multiverses.html
- Ash testing (`disable_async?`): https://ash.hexdocs.pm/testing.html, https://ash-postgres.hexdocs.pm/testing.html
- Async LiveView tests with the sandbox: https://elixirforum.com/t/running-a-liveview-test-with-async-true/68765
- Postgres tmpfs in CI: https://gitlab.com/gitlab-org/gitlab-foss/-/issues/60435
