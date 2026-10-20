extends RefCounted
## Input command for server-authoritative movement.
## No class_name — see the README (create() loads this script by path). Use preload:
##   const InputCommand = preload("res://addons/pmove/input_command.gd")

## Sequence number — monotonically increasing per client.
## Carried in the command so it works over any transport. One that numbers commands itself could
## supply it instead, but only if its numbering survives dropped commands: a plain count of
## arrivals on the server drifts for good after the first loss.
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

## Jump button held. The sim makes it edge-triggered itself (MovementState.jump_held),
## so callers just report the button.
var jump: bool = false

var crouch: bool = false
var walk: bool = false
var noclip: bool = false

## Physics delta for this tick (normally 1/60). quantize() rounds it to whole milliseconds, as
## GoldSrc's usercmd carried msec; ClientMovement.command_delta() keeps the rounding from drifting.
var delta: float = 0.0

## Game-defined flags bitmask. pmove does not interpret these — the game
## assigns meaning to each bit (e.g. levitating, sprinting) and reads them
## in the modifier callback. Travels with the command for per-tick sync.
var custom_flags: int = 0


# --- Wire format: pack booleans into a flags bitmask ---

const FLAG_JUMP := 1
const FLAG_CROUCH := 2
const FLAG_WALK := 4
const FLAG_NOCLIP := 8


func pack_flags() -> int:
	var flags := 0
	if jump:
		flags |= FLAG_JUMP
	if crouch:
		flags |= FLAG_CROUCH
	if walk:
		flags |= FLAG_WALK
	if noclip:
		flags |= FLAG_NOCLIP
	return flags


func unpack_flags(flags: int) -> void:
	jump = (flags & FLAG_JUMP) != 0
	crouch = (flags & FLAG_CROUCH) != 0
	walk = (flags & FLAG_WALK) != 0
	noclip = (flags & FLAG_NOCLIP) != 0


## Serialize to an array for network transmission. (encode_batch() is the compact form.)
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


# --- Batch wire format: quantized and delta-coded (GoldSrc usercmd style) ---
#
# A packet carries a run of consecutive commands (the new one plus backups). Each is coded against
# the one before it in the packet — the first against an all-zero command — as a field mask and only
# the fields that changed, so a backup that repeats its neighbour costs a byte or two. Angles travel
# as 16 bits and move axes as 8, the precision GoldSrc's usercmd uses.
#
#   u8 count, uvarint first seq, then per command:
#   u8 mask, [uvarint seq gap - 1], [s8 move_x, s8 move_y], [s16 yaw], [s16 pitch], [u8 flags],
#   [f32 delta], [u16 custom_flags], [f32 head_x, f32 head_y]
#
# The lossy fields only round-trip exactly if the client predicts with the rounded values too, so
# a client calls quantize() on each command before predicting it. Then server and client simulate
# identical numbers.

const ANGLE_SCALE := 32767.0 / PI  ## radians -> s16 over [-PI, PI]
const MOVE_SCALE := 127.0          ## move axis -> s8 over [-1, 1]
## Most commands one batch may carry (the count is a byte).
const BATCH_MAX := 255

const _B_MOVE := 1
const _B_YAW := 2
const _B_PITCH := 4
const _B_FLAGS := 8
const _B_DELTA := 16
const _B_CUSTOM := 32
const _B_HEAD := 64
const _B_SEQ_GAP := 128


## Round every field to what decode_batch() will reproduce, so a client predicts with exactly the
## values the server will simulate. Idempotent. Angles are wrapped to [-PI, PI].
func quantize() -> void:
	move_input = Vector2(_move_from(_move_to(move_input.x)), _move_from(_move_to(move_input.y)))
	yaw = _angle_from(_angle_to(yaw))
	pitch = _angle_from(_angle_to(pitch))
	delta = _ms_from(_ms_to(delta))
	head_delta = Vector2(_f32(head_delta.x), _f32(head_delta.y))


static func _move_to(v: float) -> int:
	return clampi(roundi(v * MOVE_SCALE), -127, 127)


static func _move_from(i: int) -> float:
	return i / MOVE_SCALE


static func _angle_to(a: float) -> int:
	return clampi(roundi(wrapf(a, -PI, PI) * ANGLE_SCALE), -32767, 32767)


static func _angle_from(i: int) -> float:
	return i / ANGLE_SCALE


static func _ms_to(d: float) -> int:
	return maxi(roundi(d * 1000.0), 0)


static func _ms_from(ms: int) -> float:
	return _f32(ms / 1000.0)


# --- Fields: the command as plain named values, for a transport that codes them itself ---

## The command's fields and their types, as a table in goldnet SyncSpec's shape: angles, move axes
## and msec are ints quantized as quantize() rounds them, the head's displacement floats (f32). The
## ones that change most come first, so a transport that masks changed fields in this order
## (goldnet's command streams) fits the usual mask in a byte.
const FIELDS := {
	"seq": {"type": TYPE_INT},
	"yaw": {"type": TYPE_INT},
	"move_x": {"type": TYPE_INT},
	"move_y": {"type": TYPE_INT},
	"pitch": {"type": TYPE_INT},
	"flags": {"type": TYPE_INT},
	"msec": {"type": TYPE_INT},
	"custom_flags": {"type": TYPE_INT},
	"head_x": {"type": TYPE_FLOAT},
	"head_y": {"type": TYPE_FLOAT},
}


## The command's fields, keyed as FIELDS names them.
func to_fields() -> Dictionary:
	return {
		"seq": seq,
		"yaw": _angle_to(yaw),
		"move_x": _move_to(move_input.x),
		"move_y": _move_to(move_input.y),
		"pitch": _angle_to(pitch),
		"flags": pack_flags(),
		"msec": _ms_to(delta),
		"custom_flags": custom_flags & 0xFFFF,
		"head_x": _f32(head_delta.x),
		"head_y": _f32(head_delta.y),
	}


## A command rebuilt from to_fields()'s values: exactly the quantized command they came from. Null
## if a field is missing.
static func from_fields(f: Dictionary) -> RefCounted:
	for field: String in FIELDS:
		if not f.has(field):
			return null
	var cmd = _script().new()
	cmd.seq = int(f["seq"])
	cmd.yaw = _angle_from(clampi(int(f["yaw"]), -32767, 32767))
	cmd.move_input = Vector2(_move_from(clampi(int(f["move_x"]), -127, 127)),
			_move_from(clampi(int(f["move_y"]), -127, 127)))
	cmd.pitch = _angle_from(clampi(int(f["pitch"]), -32767, 32767))
	cmd.unpack_flags(int(f["flags"]))
	cmd.delta = _ms_from(maxi(int(f["msec"]), 0))
	cmd.custom_flags = int(f["custom_flags"]) & 0xFFFF
	cmd.head_delta = Vector2(_f32(float(f["head_x"])), _f32(float(f["head_y"])))
	return cmd


static var _f32_buf := PackedByteArray([0, 0, 0, 0])

static func _f32(v: float) -> float:
	_f32_buf.encode_float(0, v)
	return _f32_buf.decode_float(0)


## Encode a run of commands, oldest first, seqs ascending. Quantizes as it goes, so a command that
## wasn't quantize()d still encodes — but the client should have predicted with quantized values.
static func encode_batch(cmds: Array) -> PackedByteArray:
	var n := mini(cmds.size(), BATCH_MAX)
	var buf := PackedByteArray()
	if n == 0:
		return buf
	var first := cmds.size() - n
	buf.resize(6 + n * 27)
	var o := 0
	buf.encode_u8(o, n)
	o += 1
	o = _put_uvarint(buf, o, cmds[first].seq)
	var p_seq: int = cmds[first].seq - 1
	var p_mx := 0
	var p_my := 0
	var p_yaw := 0
	var p_pitch := 0
	var p_flags := 0
	var p_delta := 0.0
	var p_custom := 0
	var p_head := Vector2.ZERO
	for i in range(first, cmds.size()):
		var cmd = cmds[i]
		var mx := _move_to(cmd.move_input.x)
		var my := _move_to(cmd.move_input.y)
		var qy := _angle_to(cmd.yaw)
		var qp := _angle_to(cmd.pitch)
		var flags: int = cmd.pack_flags()
		var d := _f32(cmd.delta)
		var custom: int = cmd.custom_flags & 0xFFFF
		var head := Vector2(_f32(cmd.head_delta.x), _f32(cmd.head_delta.y))
		var mask := 0
		if cmd.seq != p_seq + 1:
			mask |= _B_SEQ_GAP
		if mx != p_mx or my != p_my:
			mask |= _B_MOVE
		if qy != p_yaw:
			mask |= _B_YAW
		if qp != p_pitch:
			mask |= _B_PITCH
		if flags != p_flags:
			mask |= _B_FLAGS
		if d != p_delta:
			mask |= _B_DELTA
		if custom != p_custom:
			mask |= _B_CUSTOM
		if head != p_head:
			mask |= _B_HEAD
		buf.encode_u8(o, mask)
		o += 1
		if mask & _B_SEQ_GAP:
			o = _put_uvarint(buf, o, cmd.seq - p_seq - 1)
		if mask & _B_MOVE:
			buf.encode_s8(o, mx)
			buf.encode_s8(o + 1, my)
			o += 2
		if mask & _B_YAW:
			buf.encode_s16(o, qy)
			o += 2
		if mask & _B_PITCH:
			buf.encode_s16(o, qp)
			o += 2
		if mask & _B_FLAGS:
			buf.encode_u8(o, flags)
			o += 1
		if mask & _B_DELTA:
			buf.encode_float(o, d)
			o += 4
		if mask & _B_CUSTOM:
			buf.encode_u16(o, custom)
			o += 2
		if mask & _B_HEAD:
			buf.encode_float(o, head.x)
			buf.encode_float(o + 4, head.y)
			o += 8
		p_seq = cmd.seq
		p_mx = mx
		p_my = my
		p_yaw = qy
		p_pitch = qp
		p_flags = flags
		p_delta = d
		p_custom = custom
		p_head = head
	buf.resize(o)
	return buf


## Decode a batch from encode_batch(). Network input, so it's bounds-checked throughout: a
## truncated or malformed buffer yields an empty array, never a partial one or an engine error.
static func decode_batch(buf: PackedByteArray) -> Array:
	var r := _Reader.new(buf)
	var n := r.u8()
	var seq := r.uvarint() - 1
	var out: Array = []
	if r.failed or n == 0:
		return []
	var script := _script()
	var mx := 0
	var my := 0
	var qy := 0
	var qp := 0
	var flags := 0
	var d := 0.0
	var custom := 0
	var head := Vector2.ZERO
	for i in n:
		var mask := r.u8()
		seq += 1 + (r.uvarint() if mask & _B_SEQ_GAP else 0)
		if mask & _B_MOVE:
			mx = r.s8()
			my = r.s8()
		if mask & _B_YAW:
			qy = r.s16()
		if mask & _B_PITCH:
			qp = r.s16()
		if mask & _B_FLAGS:
			flags = r.u8()
		if mask & _B_DELTA:
			d = r.f32()
		if mask & _B_CUSTOM:
			custom = r.u16()
		if mask & _B_HEAD:
			head = Vector2(r.f32(), r.f32())
		if r.failed:
			return []
		var cmd = script.new()
		cmd.seq = seq
		cmd.move_input = Vector2(_move_from(mx), _move_from(my))
		cmd.yaw = _angle_from(qy)
		cmd.pitch = _angle_from(qp)
		cmd.unpack_flags(flags)
		cmd.delta = d
		cmd.custom_flags = custom
		cmd.head_delta = head
		out.append(cmd)
	return out


static func _put_uvarint(buf: PackedByteArray, o: int, v: int) -> int:
	while v >= 0x80:
		buf.encode_u8(o, (v & 0x7F) | 0x80)
		o += 1
		v >>= 7
	buf.encode_u8(o, v)
	return o + 1


## Bounds-checked reads: past the end, failed is set and every read yields 0.
class _Reader:
	var buf: PackedByteArray
	var pos := 0
	var failed := false

	func _init(p_buf: PackedByteArray) -> void:
		buf = p_buf

	func _take(size: int) -> bool:
		if failed or pos + size > buf.size():
			failed = true
			return false
		pos += size
		return true

	func u8() -> int:
		return buf.decode_u8(pos - 1) if _take(1) else 0

	func s8() -> int:
		return buf.decode_s8(pos - 1) if _take(1) else 0

	func u16() -> int:
		return buf.decode_u16(pos - 2) if _take(2) else 0

	func s16() -> int:
		return buf.decode_s16(pos - 2) if _take(2) else 0

	func f32() -> float:
		return buf.decode_float(pos - 4) if _take(4) else 0.0

	## Stops consuming payload once 63 bits are in, so an over-long run can't overflow.
	func uvarint() -> int:
		var v := 0
		var shift := 0
		while true:
			var b := u8()
			if shift < 63:
				v |= (b & 0x7F) << shift
				shift += 7
			if failed or (b & 0x80) == 0:
				break
		return v


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
