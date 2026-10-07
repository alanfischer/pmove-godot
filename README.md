# pmove

GoldSrc player movement for Godot 4 — **and the client-side prediction layer that makes it
correct over the wire.**

Named for the original's own `pmove`: the move code Quake and Half-Life share between the
client's prediction and the server's authority, so that both arrive at the same answer.

```gdscript
const Movement = preload("res://addons/pmove/movement.gd")
const MovementConfig = preload("res://addons/pmove/movement_config.gd")

var _sim := Movement.Simulation.new(MovementConfig.new())
var _state := Movement.MovementState.new()
var _body := GodotBody.new(self)          # self is a CharacterBody3D

func _physics_process(delta: float) -> void:
    var cmd := InputCommand.new()
    cmd.move_input = Input.get_vector("left", "right", "forward", "back")
    cmd.jump = Input.is_action_pressed("jump")
    cmd.yaw = _yaw
    cmd.delta = delta
    _sim.simulate_tick(_body, _state, cmd)
```

## Why this one

Godot has several Quake-flavoured character controllers. They are scene components: a
`Player.tscn` with a parameters resource, built for a single-player game, with no test suite.
This is a different shape of thing.

**The kernel is node-free and deterministic.** `Movement` is a `RefCounted` that takes a
duck-typed body, not a `Node`. Nothing in it touches the scene tree, which is what makes it
unit-testable without booting a scene — and what makes client prediction possible at all, since
prediction only works if both sides compute the same result from the same inputs.

**It ships the networking half.** A generic rollback framework hands you prediction and
reconciliation and leaves every movement-specific decision to you. Those decisions are where
this gets painful, and they are all in `net/client_movement.gd`:

- correcting below a ~5 mm threshold amplifies its own error, because replay runs N sweeps in
  one frame where the server ran one per tick, so sub-millimetre mismatches are jitter and
  "fixing" them triggers another replay;
- the physics broadphase must be re-synced *between* replayed steps, or a client false-lands
  mid-jump on a ramp while the server is still ascending;
- replay has to be driven from modifiers captured at prediction time, never from live state, or
  a buff that has since expired makes the replay diverge from what was originally predicted;
- the client's own yaw must survive a replay that re-applies old commands.

**It is a kernel, not a player controller.** In the game it came from, the same `simulate_tick`
runs players, walking monsters, and an *offline* waypoint baker with no scene at all. The
payoff is measured: a skeleton on `move_and_slide` plus a manual step-up was pressed against
geometry on 42% of the ticks it was trying to walk, and never finished a 45–150 m crossing.
On `walk_move` that fell to 0–10%.

**It is validated against real GoldSrc geometry.** It runs in a shipped multiplayer game across
24 Half-Life–era BSP maps — real clipnode hulls, doorframes, step lips and brush seams, which
is the geometry the algorithm was designed for and the only honest test of fidelity.

## Install

Copy `addons/pmove/` into your project. That's all — it's pure GDScript, no build step, no
`.gdextension`, and nothing to enable in Project Settings.

Godot **4.4+** (that's where `.uid` sidecars arrive). Developed and tested on 4.7.

Single-player? Delete `addons/pmove/net/`. The kernel doesn't reference it.

## What's in it

| file | |
|---|---|
| `movement.gd` | The kernel: `MovementState`, `MovementModifiers`, `Simulation.simulate_tick()`. Gravity is forward Euler applied once per tick before collision. |
| `movement_config.gd` | Physics constants for one simulation. Defaults are Half-Life's cvars, converted to metres. |
| `godot_body.gd` | `GodotBody`, adapting a `CharacterBody3D` to the duck-typed body interface. Anything exposing that interface works. |
| `input_command.gd` | The per-tick command the kernel reads. Also knows how to pack itself for the wire. |
| `net/server_movement.gd` | Server authority: the input queue and per-tick processing. |
| `net/client_movement.gd` | Prediction and reconciliation. |
| `net/prediction_buffer.gd` | The unacked-input history behind it. |

Networking has its own reference — the body interface, the `ServerMovement` /
`ClientMovement` APIs, the modifier callback, and the per-frame integration on both sides:
**[docs/networking.md](docs/networking.md)**.

### Two duck-typed seams

The kernel takes a **body** — anything with `global_position`, `velocity`, `yaw`,
`move_and_slide()`, `move_and_collide()`, `is_on_floor()`, `set_collision_height()`,
`has_headroom()` and `can_move()`. `GodotBody` is the bundled adapter for `CharacterBody3D`;
`simulate_tick` never sees a `Node`.

`ClientMovement` takes a **prediction harness** — anything with four members:

```gdscript
record(seq, input, snapshot, context) -> void
reconcile(acked_seq, diverged: Callable) -> Variant   # null, or { predicted, replay }
unacked_count() -> int                                # diagnostics only
clear() -> void
```

`PredictionBuffer` is the bundled one and is used by default; pass your own to
`ClientMovement.new(cfg, harness)` if your netcode already keeps an input history and you'd
rather not run a second buffer over the same inputs.

The sequence counter is deliberately *not* part of that interface. It lives on
`ClientMovement`, because the rule it obeys is a movement one: it must keep climbing across
`clear()`, or the server discards the first commands after a respawn as duplicates of the
pre-death ones and the player cannot move.

### No `class_name` on most files

Global class names resolve from a cache the editor writes during an import pass, which a bare
`--headless --path` run does not perform. So the scripts are loaded by path
(`preload("res://addons/pmove/movement.gd")`) rather than by identifier, and the suites run from
a clean checkout with no editor step.

## Determinism

Client prediction only works if both sides compute the same result from the same inputs, so the
kernel stays deterministic and free of frame-rate dependence. Game-specific behaviour that would
compromise that belongs outside it — ladders, swimming and flight are supplied through
`MovementModifiers`, which both sides apply identically.

## Tests

```bash
./run_tests.sh          # or: GODOT=/path/to/Godot ./run_tests.sh
```

Runs headless in about a second, no scene boot and no editor import. The runner fails any suite
that won't compile rather than hanging, and treats a `SCRIPT ERROR` anywhere in the output as a
failure — a GDScript runtime error kills only the frame it happens in, so a test can silently
drop its remaining assertions and still report green.

## Provenance and license

MIT — see [LICENSE](LICENSE).

This is an **independent reimplementation** of GoldSrc/Quake player-movement *semantics* in
GDScript. It is not derived from id Software's or Valve's source code, and it carries no code
from either. Where a function parallels one of the engine's, the comments name it so the
behaviour can be checked against the original — `PM_Friction`, `PM_WalkMove`, `PM_CheckStuck`
and so on — but the implementation is its own, and the search orders and tables it needs are
generated from the rules that describe them rather than transcribed.

The default constants in `movement_config.gd` are Half-Life's published cvar values
(`sv_friction 4`, `sv_accelerate 10`, `sv_stepsize 18`, …) converted to metres. Those are facts
about how a game behaves, not expression.

Worth knowing if you are comparing options: some Godot movement controllers descend from
GPL-licensed ports of the Quake source while being offered under permissive licenses. If the
license matters to your project, check the provenance of whatever you adopt — including this.
