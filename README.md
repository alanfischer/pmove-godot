# pmove

[![tests](https://github.com/alanfischer/pmove-godot/actions/workflows/tests.yml/badge.svg)](https://github.com/alanfischer/pmove-godot/actions/workflows/tests.yml)

GoldSrc player movement for Godot 4, with the client-side prediction layer that goes with it.

Named for the original's own `pmove`: the move code Quake and Half-Life share between the
client's prediction and the server's authority, so that both arrive at the same answer.

Add a **`PmoveCharacter3D`** where you would put a `CharacterBody3D`, give it a
`CollisionShape3D`, and press play. It reads the same `ui_*` actions as Godot's Basic Movement
template until you point it at your own, and the inspector takes a `PmoveConfig` resource for
the tuning.

```gdscript
@onready var player: PmoveCharacter3D = $Player

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion:
        player.rotation.y -= event.relative.x * 0.002   # turning the node turns the walk
        player.pitch = clampf(player.pitch - event.relative.y * 0.002, -PI / 2, PI / 2)

func _process(_delta: float) -> void:
    $Camera3D.position = player.position + Vector3.UP * player.eye_height
```

Run `demo/demo.tscn` to feel it: stairs, a ramp, a gap to bunny-hop, a doorframe, a ladder, a
pool to climb out of, a lift, a turntable, and a speed readout.

## What it is

**A node over a node-free kernel.** `PmoveCharacter3D` is the front door; underneath it,
`Movement` is a `RefCounted` taking a duck-typed body, not a `Node`.
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

## The node

`PmoveCharacter3D` extends `CharacterBody3D` and moves itself every physics tick.

- **Origin at the feet.** Crouching resizes the first `CollisionShape3D` and keeps its bottom on
  the origin. The node takes its own copy of that shape, so characters sharing one in a scene
  don't crouch together.
- **Steering:** its `rotation.y` is the move direction; `pitch` aims ladders and swimming.
- **Input:** `read_input` on reads the `action_*` names; off, set `move_input`, `jump`, `crouch`
  and `walk` yourself, which is how an AI drives it.
- **`velocity` is the movement's own,** so writing it is a knockback or a launch pad.
- **Read `on_floor`, not `is_on_floor()`:** the step-up leaves Godot's flag unreliable.
  `is_crouched`, `on_ladder`, `in_water` and `eye_height` are there too.
- **Ladders and water** are `Area3D`s on `ladder_layers` / `water_layers`, found at the waist.
  A ladder is climbed out of along its +Z, or a `ladder_normal` meta if it has one.
- **Moving platforms** are `AnimatableBody3D`s. It rides them, turns with them, and is pushed
  ahead of one that runs into it; a door can ask `contacts.mover_obstruction(self)` whether it is
  crushing someone.
- **Signals:** `jumped`, and `landed(impact_speed)` for fall damage.
- **It sets** `floor_snap_length = 0`, `floor_max_angle` to GoldSrc's ~45° and the platform
  layers to 0: Godot's step-snap and platform carry would fight the kernel's own.

Everything below it, `Simulation`, `MovementState` and the rest, is for what the node can't be:
a client predicting and replaying, a server running queued commands, a monster or a baker
driving a body that isn't a node.

## Install

Copy `addons/pmove/` into your project. That's all — pure GDScript, no build step, no
`.gdextension`, nothing to enable in Project Settings.

Godot **4.4+**; developed and tested on 4.7.

Single-player? Ignore `server_movement.gd`, `client_movement.gd` and `prediction_buffer.gd` —
the kernel never references them, and a script nothing preloads is never loaded.

## What's in it

| file | |
|---|---|
| `pmove_character_3d.gd` | `PmoveCharacter3D`, the node: the kernel, the ladder/water driver and input in one `CharacterBody3D`. |
| `movement.gd` | The kernel: `MovementState`, `MovementModifiers`, `Simulation.simulate_tick()`. Gravity is forward Euler applied once per tick before collision. |
| `movement_config.gd` | `PmoveConfig`, the physics constants for one simulation, as a `Resource`. Defaults are Half-Life's cvar values (`sv_friction 4`, `sv_accelerate 10`, `sv_stepsize 18`, …) converted to metres. |
| `ladder_water.gd` | Ladders and water: `PM_LadderMove`, swimming and `PM_CheckWaterJump`'s climb-out. A `Driver` picks between them each tick from what the game reports. |
| `hull_contacts.gd` | Movers and unsticking: riding, being pushed, depenetration and `PM_CheckStuck`, as per-tick modifiers. |
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

The hull can be a box, as GoldSrc's are, or a capsule: both climb stairs and stop at slopes too
steep to stand on.

### Movers

`HullContacts` is GoldSrc's pusher for a body you drive yourself. One per body; each tick, before
`simulate_tick`, it probes the hull once and writes the ride, the push, a capped depenetration
and any unstick into the tick's modifiers, so a client records and replays them like everything
else:

```gdscript
var contacts := HullContacts.new(character)    # the CharacterBody3D
contacts.mover_velocity = func(m): return []   # optional: [vel, angvel] for interpolated movers

contacts.apply(mods, state, cmd, body)         # first call in a physics frame only
rotation.y += contacts.carry_yaw_delta         # after the tick: turn with the mover
```

### Ladders and water

`PmoveCharacter3D` does all of this from its layers. Driving the kernel yourself, the game says
where they are and pmove does the moving. Each tick, before `simulate_tick`, report
whether the body is on a ladder (with the ladder's outward normal) and whether it is in water
deep enough to swim. GoldSrc's waterlevel 2 is about waist-deep. The `Driver` then writes the
tick's `MovementModifiers`:

```gdscript
var driver := LadderWater.Driver.new()   # one per body; it owns the climb-out clock

var mods := Movement.MovementModifiers.new()
driver.apply(mods, cfg, state, cmd, on_ladder, ladder_normal, in_water, space)
mods.apply_to(state)
sim.simulate_tick(body, state, cmd)
```

The node finds both with a point query at the waist against `Area3D` volumes. A body that makes
its own choices, like a monster swimming where it walks, can call the moves directly:
`ladder_velocity`, `water_velocity`, `swim` and `water_jump`. `drag_accelerate` is the swim with
the drag left open, for a game's own free 3D move such as flight.

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
a clean checkout with no editor step. `PmoveCharacter3D` and `PmoveConfig` do have names, for
the Add Node dialog and the inspector, but nothing in the library or its tests relies on them.

## Determinism

Prediction only works if both sides compute the same result from the same inputs, so the kernel
stays deterministic and free of frame-rate dependence. Behaviour that would compromise that
belongs outside it. Ladders, swimming and anything else a game adds are supplied through
`MovementModifiers`, which both sides apply identically.

## Tests

```bash
./run_tests.sh          # or: GODOT=/path/to/Godot ./run_tests.sh
```

550 assertions across 19 suites, under a second, headless — no scene boot and no editor import.
The runner reports a suite that won't compile rather than hanging on it, and treats a
`SCRIPT ERROR` anywhere in the output as a failure: a GDScript runtime error kills only the
frame it happens in, so a test can silently drop its remaining assertions and still report green.

CI runs the same script on every push and pull request, against Godot 4.4 (the floor
`project.godot` declares) and 4.7 — a consumer picks the engine, so both ends of the range are
tested.

## License

MIT — see [LICENSE](LICENSE).
