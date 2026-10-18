extends "res://tests/suite.gd"

const IC = preload("res://addons/pmove/input_command.gd")


func _run_tests() -> void:
	_run_method("test_pack_unpack_roundtrip")
	_run_method("test_flags_bitmask_all_combinations")
	_run_method("test_default_values")
	_run_method("test_wire_roundtrip")
	_run_method("test_binary_roundtrip")
	_run_method("test_binary_batch_roundtrip")
	_run_method("test_quantize_is_idempotent")
	_run_method("test_batch_roundtrip_is_exact_once_quantized")
	_run_method("test_batch_size")
	_run_method("test_batch_seq_gaps")
	_run_method("test_batch_rejects_truncation")
	_run_method("test_batch_survives_garbage")


func test_pack_unpack_roundtrip() -> void:
	var cmd := IC.new()
	cmd.seq = 42
	cmd.move_input = Vector2(0.7, -0.3)
	cmd.yaw = 1.5
	cmd.pitch = -0.2
	cmd.jump = true
	cmd.crouch = false
	cmd.walk = true
	cmd.noclip = false
	cmd.delta = 1.0 / 60.0

	var flags := cmd.pack_flags()
	var restored := IC.create(cmd.seq, cmd.move_input.x, cmd.move_input.y,
		cmd.yaw, cmd.pitch, flags, cmd.delta)

	assert_eq(restored.seq, 42, "seq")
	assert_almost_eq(restored.move_input.x, 0.7, 0.001, "move_x")
	assert_almost_eq(restored.move_input.y, -0.3, 0.001, "move_y")
	assert_almost_eq(restored.yaw, 1.5, 0.001, "yaw")
	assert_almost_eq(restored.pitch, -0.2, 0.001, "pitch")
	assert_true(restored.jump, "jump")
	assert_false(restored.crouch, "crouch")
	assert_true(restored.walk, "walk")
	assert_false(restored.noclip, "noclip")
	assert_almost_eq(restored.delta, 1.0 / 60.0, 0.0001, "delta")


func test_flags_bitmask_all_combinations() -> void:
	var flags_map := {
		"jump": IC.FLAG_JUMP,
		"crouch": IC.FLAG_CROUCH,
		"walk": IC.FLAG_WALK,
		"noclip": IC.FLAG_NOCLIP,
	}
	for field_name: String in flags_map:
		var cmd := IC.new()
		cmd.set(field_name, true)
		var packed := cmd.pack_flags()
		assert_eq(packed, flags_map[field_name], "flag %s" % field_name)

		var restored := IC.new()
		restored.unpack_flags(packed)
		assert_true(restored.get(field_name), "restored %s should be true" % field_name)

		for other_name: String in flags_map:
			if other_name != field_name:
				assert_false(restored.get(other_name),
					"%s should be false when only %s is set" % [other_name, field_name])


func test_wire_roundtrip() -> void:
	var cmd := IC.new()
	cmd.seq = 99
	cmd.move_input = Vector2(0.5, -0.8)
	cmd.yaw = 2.1
	cmd.pitch = -0.5
	cmd.jump = true
	cmd.crouch = true
	cmd.walk = false
	cmd.noclip = true
	cmd.delta = 1.0 / 60.0
	cmd.custom_flags = 7
	cmd.head_delta = Vector2(0.12, -0.34)

	var wire := cmd.pack_wire()
	var restored := IC.unpack_wire(wire)

	assert_almost_eq(restored.head_delta.x, 0.12, 0.001, "wire head_x")
	assert_almost_eq(restored.head_delta.y, -0.34, 0.001, "wire head_y")
	assert_eq(restored.seq, 99, "wire seq")
	assert_almost_eq(restored.move_input.x, 0.5, 0.001, "wire move_x")
	assert_almost_eq(restored.move_input.y, -0.8, 0.001, "wire move_y")
	assert_almost_eq(restored.yaw, 2.1, 0.001, "wire yaw")
	assert_almost_eq(restored.pitch, -0.5, 0.001, "wire pitch")
	assert_true(restored.jump, "wire jump")
	assert_true(restored.crouch, "wire crouch")
	assert_false(restored.walk, "wire walk")
	assert_true(restored.noclip, "wire noclip")
	assert_almost_eq(restored.delta, 1.0 / 60.0, 0.0001, "wire delta")
	assert_eq(restored.custom_flags, 7, "wire custom_flags")


func test_binary_roundtrip() -> void:
	var cmd := IC.new()
	cmd.seq = 123
	cmd.move_input = Vector2(0.5, -0.8)
	cmd.yaw = 2.1
	cmd.pitch = -0.5
	cmd.jump = true
	cmd.crouch = true
	cmd.walk = false
	cmd.noclip = true
	cmd.delta = 1.0 / 60.0
	cmd.custom_flags = 3
	cmd.head_delta = Vector2(-0.05, 0.21)

	var buf := PackedByteArray()
	buf.resize(IC.WIRE_STRIDE)
	cmd.pack_binary(buf, 0)
	var restored := IC.unpack_binary(buf, 0)

	assert_almost_eq(restored.head_delta.x, -0.05, 0.001, "binary head_x")
	assert_almost_eq(restored.head_delta.y, 0.21, 0.001, "binary head_y")
	assert_eq(restored.seq, 123, "binary seq")
	assert_almost_eq(restored.move_input.x, 0.5, 0.001, "binary move_x")
	assert_almost_eq(restored.move_input.y, -0.8, 0.001, "binary move_y")
	assert_almost_eq(restored.yaw, 2.1, 0.001, "binary yaw")
	assert_almost_eq(restored.pitch, -0.5, 0.001, "binary pitch")
	assert_true(restored.jump, "binary jump")
	assert_true(restored.crouch, "binary crouch")
	assert_false(restored.walk, "binary walk")
	assert_true(restored.noclip, "binary noclip")
	assert_almost_eq(restored.delta, 1.0 / 60.0, 0.0001, "binary delta")
	assert_eq(restored.custom_flags, 3, "binary custom_flags")


func test_binary_batch_roundtrip() -> void:
	var cmds: Array = []
	for i in 32:
		var cmd := IC.new()
		cmd.seq = i
		cmd.move_input = Vector2(i * 0.03, -i * 0.02)
		cmd.yaw = i * 0.1
		cmd.pitch = -i * 0.05
		cmd.jump = (i % 3 == 0)
		cmd.delta = 1.0 / 60.0
		cmd.custom_flags = i % 4
		cmds.append(cmd)

	var buf := PackedByteArray()
	buf.resize(cmds.size() * IC.WIRE_STRIDE)
	for i in cmds.size():
		cmds[i].pack_binary(buf, i * IC.WIRE_STRIDE)

	assert_eq(buf.size(), 32 * IC.WIRE_STRIDE, "batch size 1120 bytes")
	assert_true(buf.size() <= 1392, "batch fits in MTU")

	for i in cmds.size():
		var r := IC.unpack_binary(buf, i * IC.WIRE_STRIDE)
		assert_eq(r.seq, i, "batch seq[%d]" % i)
		assert_almost_eq(r.delta, 1.0 / 60.0, 0.0001, "batch delta[%d]" % i)
		assert_eq(r.custom_flags, i % 4, "batch custom_flags[%d]" % i)


func test_default_values() -> void:
	var cmd := IC.new()
	assert_eq(cmd.seq, 0, "default seq")
	assert_eq(cmd.move_input, Vector2.ZERO, "default move_input")
	assert_eq(cmd.head_delta, Vector2.ZERO, "default head_delta")
	assert_almost_eq(cmd.yaw, 0.0, 0.001, "default yaw")
	assert_almost_eq(cmd.pitch, 0.0, 0.001, "default pitch")
	assert_false(cmd.jump, "default jump")
	assert_false(cmd.crouch, "default crouch")
	assert_false(cmd.walk, "default walk")
	assert_false(cmd.noclip, "default noclip")
	assert_almost_eq(cmd.delta, 0.0, 0.001, "default delta")


# --- compact batch format ---

func _cmd(seq: int, move: Vector2, yaw: float, pitch: float, flags: int = 0) -> RefCounted:
	var cmd := IC.new()
	cmd.seq = seq
	cmd.move_input = move
	cmd.yaw = yaw
	cmd.pitch = pitch
	cmd.unpack_flags(flags)
	cmd.delta = 1.0 / 60.0
	return cmd


func _same(a, b) -> bool:
	return (a.seq == b.seq and a.move_input == b.move_input and a.yaw == b.yaw and a.pitch == b.pitch
			and a.pack_flags() == b.pack_flags() and a.delta == b.delta
			and a.custom_flags == b.custom_flags and a.head_delta == b.head_delta)


func test_quantize_is_idempotent() -> void:
	var cmd := _cmd(1, Vector2(0.70710678, -0.3), 7.5, -1.2)
	cmd.head_delta = Vector2(0.0123456789, -0.5)
	cmd.quantize()
	var once := [cmd.move_input, cmd.yaw, cmd.pitch, cmd.delta, cmd.head_delta]
	cmd.quantize()
	assert_eq([cmd.move_input, cmd.yaw, cmd.pitch, cmd.delta, cmd.head_delta], once, "a second quantize changes nothing")
	assert_true(absf(cmd.yaw - wrapf(7.5, -PI, PI)) < 0.0002, "yaw wraps into [-PI, PI] and stays close")
	assert_true(absf(cmd.move_input.x - 0.70710678) < 0.005, "move keeps 8-bit precision")


## The property prediction depends on: what the server decodes is exactly what the client predicted.
func test_batch_roundtrip_is_exact_once_quantized() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var cmds: Array = []
	for i in 40:
		var cmd := _cmd(1000 + i, Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)),
				rng.randf_range(-10, 10), rng.randf_range(-1.6, 1.6), rng.randi_range(0, 15))
		cmd.custom_flags = rng.randi_range(0, 0xFFFF)
		if i % 5 == 0:
			cmd.head_delta = Vector2(rng.randf_range(-0.1, 0.1), rng.randf_range(-0.1, 0.1))
		if i % 7 == 0:
			cmd.delta = rng.randf_range(0.01, 0.05)
		cmd.quantize()
		cmds.append(cmd)
	var out := IC.decode_batch(IC.encode_batch(cmds))
	assert_eq(out.size(), cmds.size(), "every command decoded")
	for i in mini(out.size(), cmds.size()):
		assert_true(_same(out[i], cmds[i]), "command %d decodes to exactly what was predicted" % i)


func test_batch_size() -> void:
	# The steady case: a player running and turning, new command plus two backups.
	var cmds: Array = []
	for i in 3:
		cmds.append(_cmd(100000 + i, Vector2(0, -1), 1.0 + i * 0.01, -0.1))
	var buf := IC.encode_batch(cmds)
	assert_true(buf.size() <= 24, "3 running commands in %d bytes (was 105)" % buf.size())
	# Standing still: backups that repeat their neighbour cost one byte each.
	var idle: Array = []
	for i in 3:
		idle.append(_cmd(100000 + i, Vector2.ZERO, 1.0, -0.1))
	var idle_buf := IC.encode_batch(idle)
	assert_eq(idle_buf.size(), IC.encode_batch([idle[0]]).size() + 2, "an unchanged backup costs one byte")


func test_batch_seq_gaps() -> void:
	var cmds := [_cmd(10, Vector2.ZERO, 0, 0), _cmd(11, Vector2.ZERO, 0, 0),
			_cmd(25, Vector2.ZERO, 0, 0), _cmd(300, Vector2.ZERO, 0, 0)]
	var out := IC.decode_batch(IC.encode_batch(cmds))
	assert_eq(out.map(func(c): return c.seq), [10, 11, 25, 300], "seqs with gaps survive")


func test_batch_rejects_truncation() -> void:
	var cmds: Array = []
	for i in 5:
		var cmd := _cmd(500 + i, Vector2(0.5, -1), i * 0.3, 0.2, 1)
		cmd.head_delta = Vector2(0.01, 0.02)
		cmd.custom_flags = i
		cmds.append(cmd)
	var buf := IC.encode_batch(cmds)
	for n in buf.size():
		assert_eq(IC.decode_batch(buf.slice(0, n)).size(), 0, "a batch cut to %d bytes decodes to nothing" % n)
	assert_eq(IC.decode_batch(PackedByteArray()).size(), 0, "empty buffer")


func test_batch_survives_garbage() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for trial in 500:
		var buf := PackedByteArray()
		buf.resize(rng.randi_range(0, 64))
		for i in buf.size():
			buf[i] = rng.randi_range(0, 255)
		var out := IC.decode_batch(buf)
		assert_true(out.size() <= IC.BATCH_MAX, "garbage decodes to at most a batch")
