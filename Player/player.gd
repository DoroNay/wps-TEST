extends CharacterBody3D
## Frenetic FPS movement for a Doom-like arena shooter (Godot 4.x).
##
## Node setup:
##   Player (CharacterBody3D)  <- this script
##   ├─ CollisionShape3D       (CapsuleShape3D, height 1.8, radius 0.4, position y = 0.9)
##   ├─ Head (Node3D)          (position y = 1.6)
##   │  └─ Camera3D
##   └─ Body (Node3D)          (OPTIONAL: your character model. A placeholder is built if missing)
##
## Poles: add any node to the group "pole" (Node dock > Groups tab), with collision
## (e.g. CSGCylinder3D with Use Collision on). Optional: a Marker3D named "Top" under the pole
## chooses exactly where the character stands.
## Keep poles and other level pieces OUTSIDE the Player node (siblings of it, not children).
##
## Controls (registered in code, only if you haven't defined them in the Input Map):
##   WASD move | Space jump (hold to bunny-hop) | Shift dash | E grapple (tap)
##   On a pole: look around freely | Space = hop in place and stay | WASD + Space = jump off
##   Esc free mouse | Click recapture

enum GrappleState { NONE, TRAVEL, PERCH, POLE_HOP, HOP, RETURN }

const STUCK_DISTANCE := 1.5  ## if the player falls this far behind the zip path, end the zip
const TRAVEL_EASE := 2.0  ## >1 = slow start, fast arrival
const POLE_EASE := -2.0  ## negative = smooth in and out, so you settle onto the pole
const PERCH_FOLLOW := 14.0  ## camera responsiveness while standing on a pole
const HOP_MIN_TIME := 0.1  ## ignore "landed" right after takeoff
const HOP_MAX_TIME := 4.0  ## safety: go back to first person even if you never land

@export_group("Look")
@export var mouse_sensitivity := 0.0022
@export var show_crosshair := true

@export_group("Ground")
@export var max_speed := 14.0
@export var ground_accel := 100.0
@export var ground_friction := 80.0

@export_group("Air")
@export var air_accel := 40.0
@export var gravity := 32.0
@export var fall_gravity_multiplier := 1.35

@export_group("Jump")
@export var jump_velocity := 10.0
@export_range(0.0, 1.0) var jump_cut := 0.5  ## velocity kept when you release jump early
@export var coyote_time := 0.10
@export var jump_buffer_time := 0.12
@export var auto_hop := true  ## hold jump to keep hopping without losing speed

@export_group("Dash")
@export var dash_speed := 34.0
@export var dash_duration := 0.14
@export var max_dash_charges := 2
@export var dash_recharge_time := 1.5
@export var dash_exit_speed_mult := 1.3  ## x max_speed, keeps momentum after the dash

@export_group("Grapple")
@export var grapple_range := 70.0
@export var grapple_speed := 45.0  ## zip speed, decides how long the trip lasts
@export var grapple_min_time := 0.35
@export var grapple_max_time := 1.1
@export var grapple_hop_velocity := 9.0  ## the little jump when you arrive
@export var grapple_exit_speed := 10.0  ## forward momentum kept when landing on top of something
@export var grapple_return_time := 0.15  ## camera blend into first person after you touch the ground (0 = hard cut)
@export var grapple_cooldown := 0.25
@export var grapple_lock_look := true  ## ignore the mouse during the zip
@export var jump_flip := true  ## character does a somersault in the air, toward where it's moving
@export var flip_duration := 0.55

@export_group("Pole")
@export var pole_group := "pole"
@export var pole_arc_height := 2.0  ## how high the zip arcs above the pole top
@export var pole_jump_velocity := 12.0  ## upward speed when you jump off
@export var pole_jump_speed := 8.0  ## sideways speed when you jump off
@export var pole_hop_stays_on_pole := true  ## no direction + jump = hop in place and stay on the pole
@export var pole_hop_height := 1.6
@export var pole_hop_time := 0.55

@export_group("Grapple camera")
@export var tp_distance := 4.5  ## how far behind the character
@export var tp_height := 1.2
@export var tp_side := 1.1  ## over-the-shoulder offset
@export var tp_fov := 85.0
@export var tp_follow_speed := 9.0  ## lower = lazier, more cinematic camera

@export_group("Camera feel")
@export var fov_kick := 6.0  ## extra FOV at full speed
@export var fov_smoothing := 12.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var dash_charges: int  ## read this from your HUD later
var is_grappling: bool:  ## true during the whole grapple sequence (including the pole perch)
	get:
		return _grapple_state != GrappleState.NONE

var _dash_timer := 0.0
var _dash_dir := Vector3.ZERO
var _dash_recharge := 0.0
var _coyote := 0.0
var _jump_buffer := 0.0
var _base_fov := 75.0

var _grapple_state := GrappleState.NONE
var _grapple_point := Vector3.ZERO  ## where the hook is attached
var _grapple_start := Vector3.ZERO
var _grapple_dest := Vector3.ZERO  ## where the player's feet end up
var _grapple_arc := Vector3.ZERO  ## bezier control point (poles only)
var _grapple_dir := Vector3.FORWARD
var _grapple_t := 0.0
var _grapple_travel_time := 0.5
var _grapple_cd := 0.0
var _arrive_on_floor := false
var _target_is_pole := false
var _hop_elapsed := 0.0
var _return_timer := 0.0
var _return_total := 0.15
var _return_from_pos := Vector3.ZERO
var _return_from_fov := 75.0
var _flip_t := 1.0  ## 0..1 progress of the somersault, 1 = not flipping
var _flip_axis_world := Vector3.RIGHT  ## world-space axis the somersault spins around

var _rope: MeshInstance3D
var _body: Node3D
var _body_rest := Transform3D.IDENTITY
var _tp_camera: Camera3D
var _crosshair: CanvasLayer


func _ready() -> void:
	_setup_input()
	_setup_rope()
	_setup_body()
	_setup_grapple_camera()
	if show_crosshair:
		_setup_crosshair()
	dash_charges = max_dash_charges
	_base_fov = camera.fov
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if grapple_lock_look and _is_look_locked():
			return
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		head.rotation.x = clampf(
			head.rotation.x - motion.relative.y * mouse_sensitivity,
			-PI / 2.0 + 0.01,
			PI / 2.0 - 0.01
		)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()
	_update_timers(delta, on_floor)

	if _grapple_state == GrappleState.NONE and Input.is_action_just_pressed("grapple"):
		_try_grapple()

	match _grapple_state:
		GrappleState.TRAVEL:
			_process_grapple_travel(delta)
		GrappleState.PERCH:
			_process_pole_perch()
		GrappleState.POLE_HOP:
			_process_pole_hop(delta)
		GrappleState.HOP:
			_process_grapple_hop(delta)
		GrappleState.RETURN:
			# You already have control while the camera slides into your head.
			_process_normal_movement(delta, on_floor)
			_return_timer -= delta
			if _return_timer <= 0.0:
				_end_grapple()
		_:
			_process_normal_movement(delta, on_floor)

	_update_rope()
	_update_grapple_camera(delta)
	_update_fov(delta)


func _process_normal_movement(delta: float, on_floor: bool) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish_dir := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	if Input.is_action_just_pressed("dash"):
		_try_dash(wish_dir)

	if _dash_timer > 0.0:
		_dash_timer -= delta
		velocity = Vector3(_dash_dir.x * dash_speed, 0.0, _dash_dir.z * dash_speed)
		if _dash_timer <= 0.0:
			# Leave the dash with momentum instead of stopping dead.
			velocity = Vector3(_dash_dir.x, 0.0, _dash_dir.z) * max_speed * dash_exit_speed_mult
	else:
		_apply_gravity(delta)
		_handle_jump()
		_handle_horizontal(delta, wish_dir, on_floor)

	move_and_slide()


func _update_timers(delta: float, on_floor: bool) -> void:
	# Coyote time: can still jump for a moment after walking off a ledge.
	_coyote = coyote_time if on_floor else _coyote - delta

	# Jump buffer: pressing jump slightly before landing still counts.
	var wants_jump := Input.is_action_just_pressed("jump") \
		or (auto_hop and Input.is_action_pressed("jump"))
	_jump_buffer = jump_buffer_time if wants_jump else _jump_buffer - delta

	_grapple_cd = maxf(_grapple_cd - delta, 0.0)

	# Dash charges refill one at a time.
	if dash_charges < max_dash_charges:
		_dash_recharge += delta
		if _dash_recharge >= dash_recharge_time:
			dash_charges += 1
			_dash_recharge = 0.0


func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		return
	var g := gravity * (fall_gravity_multiplier if velocity.y < 0.0 else 1.0)
	velocity.y -= g * delta


func _handle_jump() -> void:
	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0
	# Variable jump height: releasing early cuts the jump short.
	if Input.is_action_just_released("jump") and velocity.y > 0.0:
		velocity.y *= jump_cut


func _handle_horizontal(delta: float, wish_dir: Vector3, on_floor: bool) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z)
	if on_floor:
		if wish_dir != Vector3.ZERO:
			h = h.move_toward(wish_dir * max_speed, ground_accel * delta)
		else:
			h = h.move_toward(Vector3.ZERO, ground_friction * delta)
	elif wish_dir != Vector3.ZERO:
		# In the air you steer, but with no input you keep your momentum.
		h = h.move_toward(wish_dir * max_speed, air_accel * delta)
	velocity.x = h.x
	velocity.z = h.z


func _try_dash(wish_dir: Vector3) -> void:
	if dash_charges < 1 or _dash_timer > 0.0:
		return
	# Dash where you're steering, or straight ahead if no input.
	_dash_dir = wish_dir if wish_dir != Vector3.ZERO else -transform.basis.z
	dash_charges -= 1
	_dash_timer = dash_duration


# --- Grapple sequence: TRAVEL -> (HOP | PERCH <-> POLE_HOP, PERCH -> HOP) -> RETURN ---

func _try_grapple() -> void:
	if _grapple_cd > 0.0 or _dash_timer > 0.0:
		return
	var from := camera.global_transform.origin
	var to := from - camera.global_transform.basis.z * grapple_range
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return

	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	var pole := _find_pole(hit["collider"] as Node)
	var on_pole := pole != null

	var dest: Vector3
	if on_pole:
		# Aiming anywhere on a pole sends you to the top of it.
		point = _get_pole_top(pole, point)
		dest = point + Vector3.UP * 0.02
	else:
		dest = _compute_destination(point, normal)

	var dist := global_position.distance_to(dest)
	if dist < 2.0:
		return  # too close for a cutscene

	_grapple_point = point
	_grapple_start = global_position
	_grapple_dest = dest
	_grapple_dir = (dest - global_position).normalized()
	_grapple_travel_time = clampf(dist / grapple_speed, grapple_min_time, grapple_max_time)
	_grapple_t = 0.0
	_target_is_pole = on_pole
	_arrive_on_floor = normal.y > 0.7 and not on_pole
	if on_pole:
		# Control point above the pole, so the path arrives from above instead of through it.
		var arc := global_position.lerp(dest, 0.5)
		arc.y = maxf(arc.y, dest.y) + pole_arc_height
		_grapple_arc = arc

	_grapple_state = GrappleState.TRAVEL
	velocity = Vector3.ZERO
	_flip_t = 1.0
	_set_body_flip(0.0)
	_body.visible = true
	if _crosshair:
		_crosshair.visible = false
	# The cutscene camera starts exactly where the first-person camera is.
	_tp_camera.global_transform = camera.global_transform
	_tp_camera.fov = camera.fov
	_tp_camera.make_current()


func _compute_destination(point: Vector3, normal: Vector3) -> Vector3:
	# Returns where the player's FEET should end up.
	if normal.y > 0.7:
		return point + normal * 0.05  # floor or ledge top: land on it
	if normal.y < -0.7:
		return point + normal * 1.85  # ceiling: hang just below it
	return point + normal * 0.6 - Vector3.UP * 0.9  # wall: chest at the hit point


func _find_pole(node: Node) -> Node3D:
	# Walks up from whatever the ray hit until it finds a node in the pole group.
	var n := node
	while n != null:
		if n.is_in_group(pole_group):
			return n as Node3D
		n = n.get_parent()
	return null


func _get_pole_top(pole: Node3D, fallback: Vector3) -> Vector3:
	# 1) A Marker3D called "Top" under the pole wins.
	var marker := pole.get_node_or_null("Top") as Node3D
	if marker:
		return marker.global_position
	# 2) Otherwise use the top-center of the pole's bounding box (assumes an upright pole).
	var visual: VisualInstance3D = null
	if pole is VisualInstance3D:
		visual = pole as VisualInstance3D
	else:
		var found := pole.find_children("*", "VisualInstance3D", true, false)
		if not found.is_empty():
			visual = found[0] as VisualInstance3D
	if visual:
		var box := visual.get_aabb()
		var top_local := Vector3(box.get_center().x, box.end.y, box.get_center().z)
		return visual.global_transform * top_local
	return fallback


func _process_grapple_travel(delta: float) -> void:
	_grapple_t += delta / _grapple_travel_time
	var t := clampf(_grapple_t, 0.0, 1.0)

	if _target_is_pole:
		# Scripted arc, no collisions, so the character never clips through the pole.
		velocity = Vector3.ZERO
		global_position = _bezier(_grapple_start, _grapple_arc, _grapple_dest, ease(t, POLE_EASE))
		if _grapple_t >= 1.0:
			_begin_perch()
		return

	var target := _grapple_start.lerp(_grapple_dest, ease(t, TRAVEL_EASE))
	# Move toward the eased position with real collisions.
	velocity = (target - global_position) / delta
	move_and_slide()
	var blocked := global_position.distance_to(target) > STUCK_DISTANCE
	if _grapple_t >= 1.0 or blocked:
		_begin_hop()


func _begin_hop() -> void:
	_grapple_state = GrappleState.HOP
	_hop_elapsed = 0.0
	var forward := Vector3(_grapple_dir.x, 0.0, _grapple_dir.z).normalized()
	var carry := forward * grapple_exit_speed if _arrive_on_floor else Vector3.ZERO
	velocity = Vector3(carry.x, grapple_hop_velocity, carry.z)
	# Somersault toward the direction the zip was heading.
	_start_flip(_grapple_dir)


func _begin_perch() -> void:
	_grapple_state = GrappleState.PERCH
	global_position = _grapple_dest
	velocity = Vector3.ZERO


func _process_pole_perch() -> void:
	# Locked on top of the pole: no gravity, no walking. Look around, then hop or jump off.
	global_position = _grapple_dest
	velocity = Vector3.ZERO
	if Input.is_action_just_pressed("jump"):
		_pole_jump()


func _pole_jump() -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()

	# No direction: hop in place and land back on the pole.
	if wish == Vector3.ZERO and pole_hop_stays_on_pole:
		_grapple_state = GrappleState.POLE_HOP
		_hop_elapsed = 0.0
		_start_flip(-transform.basis.z)  # flips forward
		return

	# With a direction you jump off that way. With no direction (and the option above turned
	# off) wish is zero, so you go straight up and come straight down.
	var flip_dir := wish if wish != Vector3.ZERO else -transform.basis.z
	_grapple_dir = flip_dir
	velocity = wish * pole_jump_speed + Vector3.UP * pole_jump_velocity
	_grapple_state = GrappleState.HOP
	_hop_elapsed = 0.0
	_start_flip(flip_dir)


func _process_pole_hop(delta: float) -> void:
	# Scripted hop straight up and back down, so you land on exactly the same spot.
	_hop_elapsed += delta
	var t := clampf(_hop_elapsed / maxf(pole_hop_time, 0.05), 0.0, 1.0)
	global_position = _grapple_dest + Vector3.UP * (4.0 * t * (1.0 - t) * pole_hop_height)
	velocity = Vector3.ZERO
	if jump_flip:
		_set_body_flip(0.0 if t >= 1.0 else TAU * ease(t, -1.6))
	if t >= 1.0:
		_flip_t = 1.0
		_grapple_state = GrappleState.PERCH


func _process_grapple_hop(delta: float) -> void:
	# You can steer in the air while you fall.
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish_dir := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	_apply_gravity(delta)
	_handle_horizontal(delta, wish_dir, false)
	move_and_slide()

	_hop_elapsed += delta
	_update_flip(delta)

	# First person returns the moment your feet touch the ground.
	var landed := _hop_elapsed > HOP_MIN_TIME and is_on_floor()
	if landed or _hop_elapsed > HOP_MAX_TIME:
		_begin_return()


func _begin_return() -> void:
	_grapple_state = GrappleState.RETURN
	_return_total = maxf(grapple_return_time, 0.001)
	_return_timer = grapple_return_time
	_return_from_pos = _tp_camera.global_transform.origin
	_return_from_fov = _tp_camera.fov


func _end_grapple() -> void:
	_grapple_state = GrappleState.NONE
	_grapple_cd = grapple_cooldown
	_flip_t = 1.0
	_set_body_flip(0.0)
	_body.visible = false
	if _crosshair:
		_crosshair.visible = true
	camera.make_current()


func _is_look_locked() -> bool:
	return _grapple_state == GrappleState.TRAVEL


# --- Flip ------------------------------------------------------------------------

func _start_flip(move_dir: Vector3) -> void:
	if not jump_flip:
		_flip_t = 1.0
		return
	# Only the sideways direction matters. If there's none (straight up), flip forward.
	var flat := Vector3(move_dir.x, 0.0, move_dir.z)
	if flat.length() < 0.1:
		flat = -global_transform.basis.z
	flat = flat.normalized()
	# Axis perpendicular to the direction: the character goes head-first toward it.
	_flip_axis_world = Vector3.UP.cross(flat)
	_flip_t = 0.0


func _update_flip(delta: float) -> void:
	if _flip_t >= 1.0:
		return
	_flip_t = minf(_flip_t + delta / maxf(flip_duration, 0.01), 1.0)
	var angle := TAU * ease(_flip_t, -1.6)
	_set_body_flip(0.0 if _flip_t >= 1.0 else angle)


func _set_body_flip(angle: float) -> void:
	# Spins the body around its center (not its feet), on top of its resting transform.
	# The axis is kept fixed in the world, even if you turn the mouse mid-flip.
	var pivot := Vector3(0.0, 0.9, 0.0)
	var axis := (global_transform.basis.inverse() * _flip_axis_world).normalized()
	var rot := Basis(axis, angle)
	_body.transform = Transform3D(rot, pivot - rot * pivot) * _body_rest


# --- Grapple camera --------------------------------------------------------------

func _update_grapple_camera(delta: float) -> void:
	if _grapple_state == GrappleState.NONE:
		return

	# The rotation ALWAYS matches the first-person aim. Only the position is animated, so
	# going back to first person can never spin the view, whichever way you were looking.
	var aim_basis := camera.global_transform.basis
	var current := _tp_camera.global_transform
	var pos: Vector3
	var fov: float

	if _grapple_state == GrappleState.RETURN:
		# Slide from where the camera was into the first-person camera.
		var p := smoothstep(0.0, 1.0, 1.0 - clampf(_return_timer / _return_total, 0.0, 1.0))
		pos = _return_from_pos.lerp(camera.global_transform.origin, p)
		fov = lerpf(_return_from_fov, camera.fov, p)
	else:
		# Over-the-shoulder: behind, above and a bit to the side of the character.
		var on_pole := _grapple_state == GrappleState.PERCH \
			or _grapple_state == GrappleState.POLE_HOP
		var follow := PERCH_FOLLOW if on_pole else tp_follow_speed
		var center := global_position + Vector3.UP
		var desired := center + aim_basis.z * tp_distance \
			+ Vector3.UP * tp_height + aim_basis.x * tp_side
		var w := 1.0 - exp(-follow * delta)
		pos = current.origin.lerp(_clip_camera(center, desired), w)
		fov = lerpf(_tp_camera.fov, tp_fov, w)

	_tp_camera.global_transform = Transform3D(aim_basis, pos)
	_tp_camera.fov = fov


func _clip_camera(from: Vector3, desired: Vector3) -> Vector3:
	# Keeps the camera from ending up inside walls or floors.
	var query := PhysicsRayQueryParameters3D.create(from, desired, 0xFFFFFFFF, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return desired
	var p: Vector3 = hit["position"]
	var n: Vector3 = hit["normal"]
	return p + n * 0.2


func _looking_basis(direction: Vector3) -> Basis:
	var d := direction.normalized()
	var up := Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT
	return Basis.looking_at(d, up)


func _bezier(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	# Quadratic bezier: a -> c, bent toward b.
	return a.lerp(b, t).lerp(b.lerp(c, t), t)


# --- Visuals (all created in code) -----------------------------------------------

func _setup_body() -> void:
	# Use your own model if you add a Node3D called "Body"; otherwise build a placeholder.
	if has_node("Body"):
		_body = get_node("Body") as Node3D
	else:
		_body = Node3D.new()
		add_child(_body)

		var skin := StandardMaterial3D.new()
		skin.albedo_color = Color(0.9, 0.35, 0.25)
		var capsule := MeshInstance3D.new()
		var capsule_mesh := CapsuleMesh.new()
		capsule_mesh.radius = 0.4
		capsule_mesh.height = 1.8
		capsule.mesh = capsule_mesh
		capsule.material_override = skin
		capsule.position.y = 0.9
		_body.add_child(capsule)

		# A dark "visor" on the front so you can see which way the character faces.
		var dark := StandardMaterial3D.new()
		dark.albedo_color = Color(0.1, 0.1, 0.12)
		var visor := MeshInstance3D.new()
		var visor_mesh := BoxMesh.new()
		visor_mesh.size = Vector3(0.5, 0.14, 0.2)
		visor.mesh = visor_mesh
		visor.material_override = dark
		visor.position = Vector3(0.0, 1.45, -0.34)
		_body.add_child(visor)
	_body_rest = _body.transform
	_body.visible = false


func _setup_grapple_camera() -> void:
	_tp_camera = Camera3D.new()
	_tp_camera.top_level = true  # lives in world space, ignores the Player's transform
	add_child(_tp_camera)


func _setup_rope() -> void:
	_rope = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.03, 0.03, 1.0)
	_rope.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.3)
	_rope.material_override = mat
	_rope.top_level = true
	_rope.visible = false
	add_child(_rope)


func _update_rope() -> void:
	if _grapple_state != GrappleState.TRAVEL:
		_rope.visible = false
		return
	# The rope leaves the character's hand and shortens as you get closer.
	var start := global_transform * Vector3(0.35, 1.25, -0.35)
	var offset := _grapple_point - start
	var length := offset.length()
	if length < 0.05:
		_rope.visible = false
		return
	var rope_basis := _looking_basis(offset) * Basis.from_scale(Vector3(1.0, 1.0, length))
	_rope.global_transform = Transform3D(rope_basis, (start + _grapple_point) * 0.5)
	_rope.visible = true


func _setup_crosshair() -> void:
	_crosshair = CanvasLayer.new()
	var dot := ColorRect.new()
	dot.color = Color(1.0, 1.0, 1.0, 0.85)
	dot.custom_minimum_size = Vector2(4.0, 4.0)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.add_child(dot)
	add_child(_crosshair)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)


# --- Camera / input --------------------------------------------------------------

func _update_fov(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	var target := _base_fov + fov_kick * clampf(speed / max_speed, 0.0, 2.0)
	camera.fov = lerpf(camera.fov, target, 1.0 - exp(-fov_smoothing * delta))


func _setup_input() -> void:
	_add_action("move_forward", [KEY_W])
	_add_action("move_back", [KEY_S])
	_add_action("move_left", [KEY_A])
	_add_action("move_right", [KEY_D])
	_add_action("jump", [KEY_SPACE])
	_add_action("dash", [KEY_SHIFT])
	_add_action("grapple", [KEY_E])


func _add_action(action: StringName, keys: Array) -> void:
	if InputMap.has_action(action):
		return  # Project Settings take priority over these defaults.
	InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k as Key
		InputMap.action_add_event(action, ev)
