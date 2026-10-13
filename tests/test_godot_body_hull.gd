extends "res://tests/suite.gd"
## GodotBody resizes the hull for crouching whatever its shape — the demo's is a box, which keeps
## its height in size.y rather than `height`.


func _body_with(shape: Shape3D) -> CharacterBody3D:
	var b := CharacterBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	b.add_child(cs)
	return b


func test_box_hull_resizes() -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 1.8, 0.8)
	var b := _body_with(box)
	GodotBody.new(b).set_collision_height(0.9, 0.45)
	assert_almost_eq(box.size.y, 0.9, 0.0001, "box height")
	assert_almost_eq(box.size.x, 0.8, 0.0001, "box width untouched")
	assert_almost_eq((b.get_child(0) as CollisionShape3D).position.y, 0.45, 0.0001, "box centre")
	b.free()


func test_capsule_hull_resizes() -> void:
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	var b := _body_with(cap)
	GodotBody.new(b).set_collision_height(0.9, 0.45)
	assert_almost_eq(cap.height, 0.9, 0.0001, "capsule height")
	b.free()
