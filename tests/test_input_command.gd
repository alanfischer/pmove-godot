extends "res://tests/suite.gd"

const IC = preload("res://addons/pmove/input_command.gd")


func _run_tests() -> void:
	_run_method("test_pack_unpack_roundtrip")
	_run_method("test_flags_bitmask_all_combinations")
	_run_method("test_default_values")
	_run_method("test_wire_roundtrip")
	_run_method("test_binary_roundtrip")
	_run_method("test_binary_batch_roundtrip")


func test_pack_unpack_roundtrip() -> void:
	var cmd := IC.new()
	cmd.seq = 42
	cmd.move_input = Vector2(0.7, -0.3)
	cmd.yaw = 1.5
	cmd.pitch = -0.2
	cmd.jump = true
	cmd.jump_just_pressed = true
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
	assert_true(restored.jump_just_pressed, "jump_just_pressed")
	assert_false(restored.crouch, "crouch")
	assert_true(restored.walk, "walk")
	assert_false(restored.noclip, "noclip")
	assert_almost_eq(restored.delta, 1.0 / 60.0, 0.0001, "delta")


func test_flags_bitmask_all_combinations() -> void:
	var flags_map := {
		"jump": IC.FLAG_JUMP,
		"jump_just_pressed": IC.FLAG_JUMP_JUST_PRESSED,
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
	cmd.jump_just_pressed = false
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
	assert_false(restored.jump_just_pressed, "wire jump_just_pressed")
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
	cmd.jump_just_pressed = false
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
	assert_false(restored.jump_just_pressed, "binary jump_just_pressed")
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
	assert_false(cmd.jump_just_pressed, "default jump_just_pressed")
	assert_false(cmd.crouch, "default crouch")
	assert_false(cmd.walk, "default walk")
	assert_false(cmd.noclip, "default noclip")
	assert_almost_eq(cmd.delta, 0.0, 0.001, "default delta")
