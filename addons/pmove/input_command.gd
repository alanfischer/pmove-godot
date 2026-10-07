extends RefCounted
## Input command for server-authoritative movement.
## No class_name — see the README (create() loads this script by path). Use preload:
##   const InputCommand = preload("res://addons/pmove/input_command.gd")

## Sequence number — monotonically increasing per client.
var seq: int = 0

## Raw movement input: x=right, y=forward (matches Input.get_vector layout).
var move_input: Vector2 = Vector2.ZERO

## Roomscale VR head displacement for THIS tick, in body-local space
## (x=right, y=forward), metres. This is the change in the player's physical
## head position within the play space since the previous tick — fed through
## the collider in simulate_tick so the capsule tracks the headset. Zero on
## desktop and when advanced head tracking is off.
var head_delta: Vector2 = Vector2.ZERO

## Player body yaw (rotation.y) at time of input.
var yaw: float = 0.0

## Camera pitch (rotation.x) — needed for water/ladder look-direction movement.
var pitch: float = 0.0

var jump: bool = false

## Jump button just pressed (edge-triggered, single frame).
var jump_just_pressed: bool = false

var crouch: bool = false
var walk: bool = false
var noclip: bool = false

## Physics delta for this tick (normally 1/60).
var delta: float = 0.0

## Game-defined flags bitmask. pmove does not interpret these — the game
## assigns meaning to each bit (e.g. levitating, sprinting) and reads them
## in the modifier callback. Travels with the command for per-tick sync.
var custom_flags: int = 0


# --- Wire format: pack booleans into a flags bitmask ---

const FLAG_JUMP := 1
const FLAG_JUMP_JUST_PRESSED := 2
const FLAG_CROUCH := 4
const FLAG_WALK := 8
const FLAG_NOCLIP := 16


func pack_flags() -> int:
	var flags := 0
	if jump:
		flags |= FLAG_JUMP
	if jump_just_pressed:
		flags |= FLAG_JUMP_JUST_PRESSED
	if crouch:
		flags |= FLAG_CROUCH
	if walk:
		flags |= FLAG_WALK
	if noclip:
		flags |= FLAG_NOCLIP
	return flags


func unpack_flags(flags: int) -> void:
	jump = (flags & FLAG_JUMP) != 0
	jump_just_pressed = (flags & FLAG_JUMP_JUST_PRESSED) != 0
	crouch = (flags & FLAG_CROUCH) != 0
	walk = (flags & FLAG_WALK) != 0
	noclip = (flags & FLAG_NOCLIP) != 0


## Serialize to an array for network transmission.
## Format: [seq, move_x, move_y, yaw, pitch, flags, delta, custom_flags, head_x, head_y]
func pack_wire() -> Array:
	return [seq, move_input.x, move_input.y, yaw, pitch, pack_flags(), delta,
		custom_flags, head_delta.x, head_delta.y]


## Deserialize from a wire-format array produced by pack_wire().
static func unpack_wire(entry: Array) -> RefCounted:
	var script := _script()
	var cmd = script.new()
	cmd.seq = entry[0]
	cmd.move_input = Vector2(entry[1], entry[2])
	cmd.yaw = entry[3]
	cmd.pitch = entry[4]
	cmd.unpack_flags(entry[5])
	cmd.delta = entry[6]
	cmd.custom_flags = entry[7] if entry.size() > 7 else 0
	cmd.head_delta = Vector2(entry[8], entry[9]) if entry.size() > 9 else Vector2.ZERO
	return cmd


## Bytes per command in the binary wire format.
## Layout: seq(s32,4) move_x(f32,4) move_y(f32,4) yaw(f32,4) pitch(f32,4)
##         flags(u8,1) delta(f32,4) custom_flags(u16,2)
##         head_x(f32,4) head_y(f32,4) = 35 bytes total.
## 32 redundant commands × 35 bytes = 1120 bytes, comfortably below MTU (1392).
const WIRE_STRIDE := 35


## Serialize into a PackedByteArray at the given byte offset.
## The caller is responsible for pre-allocating buf to the required size.
func pack_binary(buf: PackedByteArray, offset: int) -> void:
	buf.encode_s32(offset,      seq)
	buf.encode_float(offset + 4,  move_input.x)
	buf.encode_float(offset + 8,  move_input.y)
	buf.encode_float(offset + 12, yaw)
	buf.encode_float(offset + 16, pitch)
	buf.encode_u8(offset + 20,    pack_flags())
	buf.encode_float(offset + 21, delta)
	buf.encode_u16(offset + 25,   custom_flags)
	buf.encode_float(offset + 27, head_delta.x)
	buf.encode_float(offset + 31, head_delta.y)


## Cached self-script. Can't be a preload const (the file self-references and
## headless load-ordering chokes on that — see header note), but caching the first
## load() result in a static keeps the hot server receive path (unpack_binary runs
## for every redundant command in every input packet) off the resource cache lookup.
static var _self_script: GDScript = null

static func _script() -> GDScript:
	if _self_script == null:
		_self_script = load("res://addons/pmove/input_command.gd") as GDScript
	return _self_script


## Deserialize from a PackedByteArray at the given byte offset.
static func unpack_binary(buf: PackedByteArray, offset: int) -> RefCounted:
	var script := _script()
	var cmd = script.new()
	cmd.seq        = buf.decode_s32(offset)
	cmd.move_input = Vector2(buf.decode_float(offset + 4), buf.decode_float(offset + 8))
	cmd.yaw        = buf.decode_float(offset + 12)
	cmd.pitch      = buf.decode_float(offset + 16)
	cmd.unpack_flags(buf.decode_u8(offset + 20))
	cmd.delta        = buf.decode_float(offset + 21)
	cmd.custom_flags = buf.decode_u16(offset + 25)
	cmd.head_delta   = Vector2(buf.decode_float(offset + 27), buf.decode_float(offset + 31))
	return cmd


static func create(p_seq: int, move_x: float, move_y: float, p_yaw: float,
		p_pitch: float, flags: int, p_delta: float,
		p_custom_flags: int = 0) -> RefCounted:
	var script := _script()
	var cmd = script.new()
	cmd.seq = p_seq
	cmd.move_input = Vector2(move_x, move_y)
	cmd.yaw = p_yaw
	cmd.pitch = p_pitch
	cmd.unpack_flags(flags)
	cmd.delta = p_delta
	cmd.custom_flags = p_custom_flags
	return cmd
