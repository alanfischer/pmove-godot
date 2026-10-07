# pmove

GoldSrc player movement for Godot 4, with the client-side prediction layer that goes with it.

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

Run `demo/demo.tscn` to feel it: stairs, a ramp, a gap to bunny-hop, a doorframe, and a speed
readout.

## What it is

**A node-free kernel.** `Movement` is a `RefCounted` taking a duck-typed body, not a `Node`.
Nothing in it touches the scene tree, which is what makes it unit-testable without booting a
scene — and what makes prediction possible at all, since that only works if both sides compute
the same result from the same inputs.

**With the networking half included.** A generic rollback framework gives you prediction and
reconciliation and leaves the movement-specific decisions to you. Those are the fiddly ones, and
they're in `client_movement.gd`:

- correcting below a ~5 mm threshold amplifies its own error, because replay runs N sweeps in
  one frame where the server ran one per tick, so sub-millimetre mismatches are jitter;
- the physics broadphase has to be re-synced *between* replayed steps, or a client false-lands
  mid-jump on a ramp while the server is still ascending;
- replay must be driven from modifiers captured at prediction time, not live state, or a buff
  that has since expired changes what the replay produces;
- the client's own yaw has to survive a replay that re-applies old commands.

**Usable by things that aren't the player.** In the game it came from, the same `simulate_tick`
runs players, walking monsters, and an offline waypoint baker with no scene at all. Each caller
brings its own `MovementConfig`, so a monster keeps the speed and hull it was authored with and
only the stepping, sliding, friction and acceleration are shared.

The payoff is measurable on GoldSrc brushwork, which is full of doorframes, step lips and brush
seams: a skeleton on `move_and_slide` plus a manual step-up was pressed against geometry on 42%
of the ticks it was trying to walk, and never finished a 45–150 m crossing. On `walk_move` that
fell to 0–10%.

It runs in a shipped multiplayer game across 24 Half-Life–era BSP maps, against real clipnode
hulls.

## Install

Copy `addons/pmove/` into your project. That's all — pure GDScript, no build step, no
`.gdextension`, nothing to enable in Project Settings.

Godot **4.4+**; developed and tested on 4.7.

Single-player? Ignore `server_movement.gd`, `client_movement.gd` and `prediction_buffer.gd` —
the kernel never references them, and a script nothing preloads is never loaded.

## What's in it

| file | |
|---|---|
| `movement.gd` | The kernel: `MovementState`, `MovementModifiers`, `Simulation.simulate_tick()`. Gravity is forward Euler applied once per tick before collision. |
| `movement_config.gd` | Physics constants for one simulation. Defaults are Half-Life's cvar values (`sv_friction 4`, `sv_accelerate 10`, `sv_stepsize 18`, …) converted to metres. |
| `godot_body.gd` | `GodotBody`, adapting a `CharacterBody3D` to the duck-typed body interface. Anything exposing that interface works. |
| `input_command.gd` | The per-tick command the kernel reads. Also knows how to pack itself for the wire. |
| `server_movement.gd` | Server authority: the input queue and per-tick processing. |
| `client_movement.gd` | Prediction and reconciliation. |
| `prediction_buffer.gd` | The unacked-input history behind it. |

Networking has its own reference — the body interface, the `ServerMovement` / `ClientMovement`
APIs, the modifier callback, and the per-frame integration on both sides:
**[docs/networking.md](docs/networking.md)**.

Where a function corresponds to one of the engine's, the comments name it — `PM_Friction`,
`PM_WalkMove`, `PM_CheckStuck` — so the two can be read side by side, and they say where this
deliberately differs.

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

`PredictionBuffer` is the bundled one and is the default; pass your own to
`ClientMovement.new(cfg, harness)` if your netcode already keeps an input history and you'd
rather not run a second buffer over the same inputs.

The sequence counter is deliberately *not* in that interface. It lives on `ClientMovement`,
because the rule it obeys is a movement one: it must keep climbing across `clear()`, or the
server discards the first commands after a respawn as duplicates of the pre-death ones and the
player cannot move.

### No `class_name` on most files

Global class names resolve from a cache the editor writes during an import pass, which a bare
`--headless --path` run does not perform. So the scripts are loaded by path
(`preload("res://addons/pmove/movement.gd")`) rather than by identifier, and the suites run from
a clean checkout with no editor step.

## Determinism

Prediction only works if both sides compute the same result from the same inputs, so the kernel
stays deterministic and free of frame-rate dependence. Behaviour that would compromise that
belongs outside it — ladders, swimming and flight are supplied through `MovementModifiers`,
which both sides apply identically.

## Tests

```bash
./run_tests.sh          # or: GODOT=/path/to/Godot ./run_tests.sh
```

495 assertions across 13 suites, under a second, headless — no scene boot and no editor import.
The runner reports a suite that won't compile rather than hanging on it, and treats a
`SCRIPT ERROR` anywhere in the output as a failure: a GDScript runtime error kills only the
frame it happens in, so a test can silently drop its remaining assertions and still report green.

## License

MIT — see [LICENSE](LICENSE).
