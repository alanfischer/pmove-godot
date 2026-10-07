# Networking: server authority and client prediction

Server-authoritative movement with client-side prediction, Quake/Half-Life style.

## Why manual physics?

The player character uses `CharacterBody3D` (kinematic), not `RigidBody3D`. For kinematic bodies, Godot's physics engine only provides collision resolution (`move_and_slide`) and floor detection (`is_on_floor()`). Gravity, friction, and acceleration have no engine equivalent — they must always be applied manually in script regardless of approach.

The deeper reason: client-side prediction requires the client and server to run **identical deterministic physics**. Godot's rigid body solver is not deterministic across machines — two computers simulating the same `RigidBody3D` will diverge due to floating point ordering and solver iteration differences. That makes rigid bodies incompatible with prediction/reconciliation.

pmove therefore owns every source of motion the player has, including the ride on a moving
brush entity: `GodotBody` switches the body's `platform_floor_layers`/`platform_wall_layers` off so
`move_and_slide` can never apply Godot's own platform carry on top of `state.carry_motion`.

This is the standard pattern for networked first-person shooters. All other entities in the game world (projectiles, physics objects, ragdolls) use `RigidBody3D` and engine-driven physics — they don't need prediction, so non-determinism is fine. The player is the special case because input latency makes snapshot interpolation unacceptable for your own character.

## Layers

The movement simulation itself lives in `addons/pmove/` — named for GoldSrc's own `pmove`, the
shared move code both sides run. It is pure math with no networking in it, and a player need not
be its only caller: in the game this came from, walking monsters run the same kernel, which is why
doorframes and step lips stop them no more than they stop a player.

`addons/pmove/net/` is the layer on top: prediction, reconciliation and the input queue, which only a player
needs.

## Files

- **ServerMovement** (`server_movement.gd`) — Server-side: owns a `MovementState`, manages an input queue, processes all queued commands each physics frame.
- **ClientMovement** (`client_movement.gd`) — Client-side: owns a `MovementState`, records predictions, reconciles with server state and replays on mismatch. Also defines `ServerState`.

In `addons/pmove/`:

- **Movement** (`movement.gd`) — Pure math simulation kernel. GoldSrc-derived physics constants (stored in Godot metres), `MovementState` data class, `simulate_tick()`. Gravity is forward Euler applied once per tick before collision. No Godot node dependencies.
- **input_command.gd** — Serializable input snapshot (movement, look, jump, crouch, etc). Packs booleans into a bitmask for network transmission. No `class_name` due to headless script-load ordering issues — use `const InputCommand = preload("res://addons/pmove/input_command.gd")`.
- **GodotBody** (`godot_body.gd`) — Adapter wrapping `CharacterBody3D` into the body interface that `simulate_tick` expects.
- **movement_config.gd** — Per-instance physics constants. One per simulation, so a monster keeps its own speed and hull while sharing the kernel.

## Naming conventions

- **Boolean state fields** use a descriptive prefix: `is_crouched`, `is_jumping`, `is_move_locked` (`is_`), `on_floor`, `on_ladder` (`on_`), `in_water` (`in_`).
- **InputCommand fields** have no prefix — they're raw inputs, not state: `jump`, `crouch`, `walk`.
- **Private members** use `_` prefix: `_buffer`, `_input_queue`.
- **`cmd` parameters** are untyped (Variant) since InputCommand lacks `class_name`. They expect an InputCommand-shaped object with: `seq`, `move_input`, `yaw`, `pitch`, `delta`, `jump`, `jump_just_pressed`, `crouch`, `walk`, `noclip`, `custom_flags`.

## Body interface

`simulate_tick` uses duck typing. Any object with these methods/properties works:

```
var global_position: Vector3
var velocity: Vector3
var yaw: float

func move_and_slide() -> void
func move_and_collide(motion: Vector3) -> variant
func is_on_floor() -> bool
func apply_floor_snap() -> void
func set_collision_height(height: float, center_y: float) -> void
func has_headroom(rise: float, from_offset := Vector3.ZERO) -> bool
```

`force_sync_physics()` is optional — callers probe for it with `has_method` (see
`ClientMovement._reconcile`), so a body that can't push its transform to the physics server early
still works.

`GodotBody` implements this for `CharacterBody3D`. Tests use a `StubBody` with flat-ground collision.

`MovementState.position` is a **view over the bound body's `global_position`**, not a copy — reads and
writes go straight through, so the sim position and the physics body can never drift apart. Moving the
body out of band (teleport, spawn placement) is immediately visible to everything that reads
`state.position`, even while no commands are being processed. `simulate_tick` binds the body it is
given; call `bind_body(body)` on ServerMovement/ClientMovement as soon as the body exists so
out-of-band moves before the first tick are covered too.

## API

### ServerMovement

```
.state: MovementState               # authoritative movement state
.last_processed_seq: int            # seq of last command processed
.last_yaw: float                    # yaw from last processed command
.last_pitch: float                  # pitch from last processed command
.max_queue: int                     # max queued commands (default 64, anti-flood)

bind_body(body)                     # bind state.position to the body transform (idempotent)
enqueue(cmd)                        # add an InputCommand to the queue; drops duplicates/old
process_queue(body, modifier_cb)    # process ALL queued commands; modifier_cb optional
queue_size() -> int                 # number of commands currently queued
clear_queue()                       # discard queued commands, keep last_processed_seq
clear()                             # full reset — clears queue and allows all seqs again
```

### ClientMovement

```
.state: MovementState               # current predicted movement state
.last_correction: Dictionary        # debug info from the most recent reconcile() correction

bind_body(body)                     # bind state.position to the body transform (idempotent)
get_next_seq() -> int               # monotonically increasing seq for the next InputCommand
predict(body, cmd, modifier_cb)     # run one predicted tick and record it in the buffer
reconcile(body, server) -> bool     # compare server state to prediction; replay on mismatch
buffer_size() -> int                # number of unacked predictions in the buffer
clear()                             # clear prediction buffer (does NOT reset seq counter)
```

`reconcile()` takes a `ClientMovement.ServerState`:

```gdscript
class ServerState:
    var seq: int
    var position: Vector3
    var velocity: Vector3
    var is_crouched: bool
    var on_floor: bool
    var is_jumping: bool
```

### modifier_cb signature

Both `predict()` and `process_queue()` accept an optional modifier callback:

```gdscript
func my_modifier(cmd) -> Movement.MovementModifiers:
    var mods := Movement.MovementModifiers.new()
    mods.gravity_scale = 0.5  # e.g. levitating
    return mods
```

The callback receives the current `cmd` and returns a `MovementModifiers`. Netmove calls `mods.apply_to(state)` before each `simulate_tick`. During reconciliation replay, **the callback is not called** — stored modifiers from prediction time are replayed directly. This prevents live game state (expired frost, exited ladder) from diverging from the original prediction.

## Custom flags

`InputCommand.custom_flags` is a game-defined `int` bitmask that travels with the command. Netmove does not interpret it — the game assigns meaning to each bit (e.g. levitating, sprinting) and reads them in the modifier callback. Use this for client-initiated movement effects that must be in sync with the tick they were set on.

## Integration

### Client (each physics frame)

```gdscript
var cmd := InputCommand.new()
cmd.seq = client_movement.get_next_seq()
cmd.move_input = Input.get_vector(...)
cmd.yaw = rotation.y
cmd.pitch = camera.rotation.x
cmd.jump = Input.is_action_pressed("jump")
cmd.delta = delta

client_movement.predict(body, cmd, modifier_cb)

send_cmd_to_server(cmd)  # pack with cmd.pack_binary() for efficient batching
```

### Server (each physics frame, per player)

```gdscript
# On receiving an input batch:
server_movement.enqueue(InputCommand.unpack_binary(buf, offset))

# Each physics frame:
server_movement.process_queue(body, modifier_cb)

send_server_state(server_movement.last_processed_seq,
    server_movement.state.position, server_movement.state.velocity,
    server_movement.state.is_crouched, server_movement.state.on_floor,
    server_movement.state.is_jumping)
```

### Client reconciliation (on receiving server state)

```gdscript
var server := ClientMovement.ServerState.new(seq, pos, vel, crouched, on_floor, jumping)
client_movement.reconcile(body, server)
```

If the prediction matched, nothing happens. On mismatch, snaps to server state and replays all unacked commands through `Simulation.simulate_tick` using their stored modifiers.

## Tests

```
./run_tests.sh
```

The networking suites use a `StubBody` (flat ground, no walls) so they run without scene setup,
alongside the kernel's own. The harness (`tests/suite.gd`) mirrors the Gut API.
