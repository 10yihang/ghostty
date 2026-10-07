# AI panel performance

The panel keeps the native terminal binding and approval flow. Completed tool
outputs mount when opened; running and failed tools remain discoverable. File
targets stay visible in narrow panels, with the complete path available in the
tooltip and expanded output. Structured request parameters use a separate
disclosure.

The native renderer builds snapshots at dispatch time and allows one WebKit
update in flight. Events received during a render replace the pending provider,
so the next update samples the latest model and draft revision. Dismantling or
a failed renderer cancels pending work and invalidates old completions.

History checkpoints run once per second while streaming. Submit, stop, settle,
reset and application termination still synchronously save the final state.
The same message projection serves rendering and persistence; saves avoid
building the unrelated workbench metadata. Reset performs one final write before
releasing the conversation lease.

## Measured fixtures

These October 8, 2026 measurements use isolated macOS fixtures. The rendering
stress test deliberately spends 80 ms per WebKit update; its counters describe
backpressure under that load. The history numbers exclude the immediate final
save and compare the same 201-message, 1.25-second streaming workload.

| Workload | Before | After |
| --- | ---: | ---: |
| 100 renderer events: snapshot builds | 100 | 6 |
| Slow WebKit: maximum in-flight updates | 8 | 1 |
| Final renderer sequence | 100 | 100 |
| 10 tool steps: total DOM nodes | 240 | 186 |
| 8 folded outputs: mounted text characters | 71,680 | 0 |
| Streaming history checkpoints | 4 | 1 |
| Streaming history bytes written | 1,412,903 | 353,373 |
| Reset final transcript writes | 2 | 1 |

The individual transcript encoder, fsync and lease checks retain their existing
behavior. The improvement reduces repeated work and total disk writes.

## Regression coverage

`macos/build.nu --action test` exercises lazy snapshots, final delivery,
cancelled-provider release, draft revisions, checkpoint recovery, immediate final
saves, lease conflicts, failed-save protection, stop followed by a new task,
terminal operations, approval and clipboard behavior.

`npm --prefix macos/AIChat test` checks lazy tool bodies, complete output copying,
manual disclosure and selection preservation, sorted request arguments and
file-diff approval. Native offscreen inspection covers right, bottom and floating
layouts, including a narrow sidebar and short bottom panel.
