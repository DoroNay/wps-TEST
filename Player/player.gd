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
## Platforms: anything with collision (e.g. CSGBox3D with Use Collision on). The hook only
## attaches to a platform's top edge. Aim at its side or its top, tap E, and you climb on top.
##
## Poles: add any node to the group "pole" (Node dock > Groups tab), with collision
## (e.g. CSGCylinder3D with Use Collision on). Optional: a Marker3D named "Top" under the pole
## chooses exactly where the character stands.
## Keep poles and other level pieces OUTSIDE the Player node (siblings of it, not children).
##
## Controls (registered in code, only if you haven't defined them in the Input Map):
##   WASD move | Space jump (hold to bunny-hop) | Shift dash | E grapple (tap)
##   Left mouse (hold) = shoot | R = go back to where you started
##   On a pole: look around freely | Space = hop in place and stay | WASD + Space = jump off
##   Esc free mouse | Click recapture

signal health_changed(current: float, maximum: float)  ## connect a HUD to this later

enum GrappleState { NONE, TRAVEL, VAULT, PERCH, POLE_HOP, HOP, RETURN }

const ZIP_EASE := -2.0  ## negative = smooth in and out, so you settle at the end of the zip
const PERCH_FOLLOW := 14.0  ## camera responsiveness while standing on a pole
const HOP_MIN_TIME := 0.1  ## ignore "landed" right after takeoff
const HOP_MAX_TIME := 4.0  ## safety: go back to first person even if you never land
const LEDGE_MARCH_STEP := 0.15  ## how finely we walk along a platform top looking for its edge
const LEDGE_MARCH_MAX := 12.0  ## how far we look for that edge

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

@export_group("Weapon")
@export var weapon_damage := 20.0
@export var fire_rate := 6.0  ## shots per second (hold the button to keep firing)
@export var weapon_range := 100.0
@export var debug_combat := false  ## prints what each shot hits to the Output panel

@export_group("Health")
@export var max_health := 100.0
@export var restart_on_death := true  ## placeholder: reloads the scene when you die

@export_group("Grapple")
@export var grapple_range := 70.0
@export var grapple_speed := 45.0  ## zip speed, decides how long the trip lasts
@export var grapple_min_time := 0.35
@export var grapple_max_time := 1.1
@export var grapple_ledge_reach := 4.0  ## how far above the aimed point a platform top can be
@export var vault_time := 0.4  ## the climb up and over the edge
@export var vault_arc_height := 1.6  ## how high the vault arcs above the edge
@export var vault_exit_speed := 3.0  ## small push inward, so you don't stop right on the edge
@export var grapple_return_time := 0.15  ## camera blend into first person after you touch the ground (0 = hard cut)
@export var grapple_cooldown := 0.25
@export var grapple_lock_look := true  ## ignore the mouse during the zip and the vault
@export var jump_flip := true  ## character does a somersault in the air, toward where it's moving
@export var flip_duration := 0.55
@export var debug_grapple := false  ## prints what the grapple decides to the Output panel

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
var health := 100.0  ## read this from your HUD later
var is_grappling: bool:  ## true during the whole grapple sequence (including the pole perch)
	get:
		return _grapple_state != GrappleState.NONE

var _dash_timer := 0.0
var _dash_dir := Vector3.ZERO
var _dash_recharge := 0.0
var _coyote := 0.0
var _jump_buffer := 0.0
var _base_fov := 75.0

var _fire_cd := 0.0
var _captured_last_frame := false
var _hit_marker: ColorRect
var _hit_marker_time := 0.0
var _hurt_flash: ColorRect
var _hurt_alpha := 0.0

var _grapple_state := GrappleState.NONE
var _grapple_point := Vector3.ZERO  ## where the hook is attached (platform edge or pole top)
var _grapple_start := Vector3.ZERO
var _grapple_dest := Vector3.ZERO  ## where the player's feet end up after the zip
var _grapple_arc := Vector3.ZERO  ## bezier control point (poles only)
var _grapple_t := 0.0
var _grapple_travel_time := 0.5
var _grapple_cd := 0.0
var _target_is_pole := false
var _ledge_stand := Vector3.ZERO  ## where the feet end up on top of the platform
var _ledge_inward := Vector3.FORWARD  ## horizontal direction from the edge into the platform
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
var _spawn_transform := Transform3D.IDENTITY  ## where R sends you back to
var _spawn_head_pitch := 0.0


func _ready() -> void:
	add_to_group("player")  # enemies find you through this group
	health = max_health
	_spawn_transform = global_transform
	_spawn_head_pitch = head.rotation.x
	_setup_input()
	_setup_rope()
	_setup_body()
	_setup_grapple_camera()
	_setup_combat_ui()
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


func _process(delta: float) -> void:
	# Fade the hit marker and the red "you got hurt" flash.
	_hit_marker_time = maxf(_hit_marker_time - delta, 0.0)
	_hit_marker.visible = _hit_marker_time > 0.0
	_hurt_alpha = maxf(_hurt_alpha - delta * 2.5, 0.0)
	_hurt_flash.color = Color(1.0, 0.1, 0.1, _hurt_alpha)


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("reset"):
		_reset_to_spawn()
		return

	_update_weapon(delta)

	var on_floor := is_on_floor()
	_update_timers(delta, on_floor)

	if _grapple_state == GrappleState.NONE and Input.is_action_just_pressed("grapple"):
		_try_grapple()

	match _grapple_state:
		GrappleState.TRAVEL:
			_process_grapple_travel(delta)
		GrappleState.VAULT:
			_process_vault(delta)
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


func _reset_to_spawn() -> void:
	# If you're in the middle of a grapple or on a pole, end it cleanly first.
	if _grapple_state != GrappleState.NONE:
		_end_grapple()
	global_transform = _spawn_transform  # back to where you started, facing the same way
	head.rotation.x = _spawn_head_pitch
	velocity = Vector3.ZERO
	_dash_timer = 0.0
	_grapple_cd = 0.0
	dash_charges = max_dash_charges


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


# --- Weapon and health -----------------------------------------------------------

func _update_weapon(delta: float) -> void:
	_fire_cd = maxf(_fire_cd - delta, 0.0)
	# Don't shoot on the click that recaptures the mouse, or during the grapple cutscene.
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if captured and _captured_last_frame and _grapple_state == GrappleState.NONE \
			and _fire_cd <= 0.0 and Input.is_action_pressed("fire"):
		_shoot()
	_captured_last_frame = captured


func _shoot() -> void:
	_fire_cd = 1.0 / maxf(fire_rate, 0.01)
	var from := camera.global_transform.origin
	var to := from - camera.global_transform.basis.z * weapon_range
	var hit := _ray(from, to)

	var end := to
	if hit.is_empty():
		if debug_combat:
			print("[combat] the shot hit nothing")
	else:
		end = hit["position"]
		var target := hit["collider"] as Node
		var can_hurt := target != null and target.has_method("take_damage")
		if debug_combat:
			print("[combat] the shot hit ", target, " (it can take damage: ", can_hurt, ")")
		if can_hurt:
			target.call("take_damage", weapon_damage)
			_hit_marker_time = 0.08
	_spawn_tracer(camera.global_transform * Vector3(0.3, -0.25, -0.6), end)


func take_damage(amount: float) -> void:
	# Enemies call this when they hit you.
	if health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	_hurt_alpha = 0.45
	health_changed.emit(health, max_health)
	if health <= 0.0 and restart_on_death:
		get_tree().reload_current_scene.call_deferred()


func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	# A thin bright line that lasts a split second, so you can see your shots.
	var offset := to - from
	var length := offset.length()
	if length < 0.1:
		return
	var box := BoxMesh.new()
	box.size = Vector3(0.02, 0.02, 1.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.95, 0.6)
	var tracer := MeshInstance3D.new()
	tracer.mesh = box
	tracer.material_override = mat
	tracer.top_level = true  # lives in world space
	add_child(tracer)
	tracer.global_transform = Transform3D(
		_looking_basis(offset) * Basis.from_scale(Vector3(1.0, 1.0, length)),
		(from + to) * 0.5
	)
	get_tree().create_timer(0.05).timeout.connect(tracer.queue_free)


func _setup_combat_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10

	_hurt_flash = ColorRect.new()
	_hurt_flash.color = Color(1.0, 0.1, 0.1, 0.0)
	_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hurt_flash)

	_hit_marker = ColorRect.new()
	_hit_marker.color = Color.WHITE
	_hit_marker.custom_minimum_size = Vector2(14.0, 14.0)
	_hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_marker.visible = false
	layer.add_child(_hit_marker)

	add_child(layer)
	_hurt_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hit_marker.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_hit_marker.pivot_offset = Vector2(7.0, 7.0)
	_hit_marker.rotation = PI / 4.0  # a diamond


# --- Grapple: TRAVEL -> VAULT -> RETURN (platforms), TRAVEL -> PERCH ... (poles) ----

func _dbg(msg: String) -> void:
	if debug_grapple:
		print("[grapple] ", msg)


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


func _try_grapple() -> void:
	if _grapple_cd > 0.0 or _dash_timer > 0.0:
		return
	var from := camera.global_transform.origin
	var to := from - camera.global_transform.basis.z * grapple_range
	var hit := _ray(from, to)
	if hit.is_empty():
		_dbg("the aim ray hit nothing within range")
		return

	var point: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]
	_dbg("aim ray hit %s at %s, normal %s" % [hit["collider"], point, normal])
	var pole := _find_pole(hit["collider"] as Node)
	var on_pole := pole != null

	var dest: Vector3
	if on_pole:
		# Aiming anywhere on a pole sends you to the top of it.
		point = _get_pole_top(pole, point)
		dest = point + Vector3.UP * 0.02
	else:
		var ledge := _find_ledge(point, normal)
		if ledge.is_empty():
			return  # not a platform edge, so the hook doesn't attach
		point = ledge["edge"]
		dest = ledge["hang"]
		_ledge_stand = ledge["stand"]
		_ledge_inward = ledge["inward"]

	var dist := global_position.distance_to(dest)
	if dist < 2.0:
		_dbg("too close to the target (%.1f m)" % dist)
		return  # too close for a cutscene

	_grapple_point = point
	_grapple_start = global_position
	_grapple_dest = dest
	_grapple_travel_time = clampf(dist / grapple_speed, grapple_min_time, grapple_max_time)
	_grapple_t = 0.0
	_target_is_pole = on_pole
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


func _no_ledge(reason: String) -> Dictionary:
	_dbg("no ledge: " + reason)
	return {}


func _find_ledge(point: Vector3, normal: Vector3) -> Dictionary:
	# Looks for a platform edge at what you aimed at. Returns {} if there isn't one, else:
	#   edge   - the top edge of the platform (where the hook attaches)
	#   hang   - where your feet go while you grab the edge
	#   stand  - where your feet end up on top of the platform
	#   inward - horizontal direction pointing from the edge into the platform
	var face_point := point
	var face_normal := normal

	if normal.y > 0.7:
		# You aimed at the TOP of something: walk along its surface toward you until it ends.
		# (The ground never ends before it reaches you, so aiming at the ground does nothing.)
		var to_player := Vector3(global_position.x - point.x, 0.0, global_position.z - point.z)
		var remaining := to_player.length()
		if remaining < 0.5:
			return _no_ledge("aimed at a top surface right next to you")
		var toward := to_player / remaining
		var q := point
		var outside := point
		var found := false
		var steps := int(minf(remaining, LEDGE_MARCH_MAX) / LEDGE_MARCH_STEP)
		for i in steps:
			var next := q + toward * LEDGE_MARCH_STEP
			var ground := _ray(next + Vector3.UP * 0.3, next + Vector3.DOWN * 0.3)
			if ground.is_empty() or (ground["normal"] as Vector3).y < 0.7:
				outside = next
				found = true
				break
			q = ground["position"]
		if not found:
			return _no_ledge("that surface doesn't end before it reaches you (ground?)")
		# q is the last point with floor under it. Find the real side face right there.
		face_point = q
		face_normal = toward
		var probe_out := outside + Vector3.DOWN * 0.3
		var face := _ray(probe_out, probe_out - toward * 0.6)
		if not face.is_empty() and absf((face["normal"] as Vector3).y) < 0.5:
			face_point = face["position"]
			face_normal = face["normal"]

	# Only (nearly) vertical faces can be climbed.
	if absf(face_normal.y) > 0.5:
		return _no_ledge("the aimed face isn't vertical (normal %s)" % face_normal)
	var outward := Vector3(face_normal.x, 0.0, face_normal.z).normalized()
	var inward := -outward

	# Find the top of the platform: shoot down from above, just inside the face.
	# If the wall is taller than grapple_ledge_reach there is no top in range, so no hook.
	var probe := face_point + inward * 0.25
	var top := _ray(
		Vector3(probe.x, face_point.y + grapple_ledge_reach, probe.z),
		Vector3(probe.x, face_point.y - 0.05, probe.z)
	)
	if top.is_empty() or (top["normal"] as Vector3).y < 0.7:
		return _no_ledge("no platform top found within %.1f m above the aimed point" % grapple_ledge_reach)
	var top_pos: Vector3 = top["position"]
	if top_pos.y < face_point.y - 0.05:
		return _no_ledge("the top that was found is below the aimed point")
	var edge := Vector3(face_point.x, top_pos.y, face_point.z)

	# Where to stand on top: a bit in from the edge, with room for the whole body.
	var stand := Vector3.ZERO
	var has_stand := false
	for inset: float in [0.7, 0.45]:
		var candidate := edge + inward * inset + Vector3.UP * 0.02
		if _has_ground(candidate) and _has_headroom(candidate):
			stand = candidate
			has_stand = true
			break
	if not has_stand:
		return _no_ledge("no room to stand on top (not enough ground or headroom)")

	# Where to hang while gripping the edge: against the wall, chest about at the edge.
	var hang_xz := edge + outward * 0.5
	var hang := hang_xz - Vector3.UP * 1.0
	var floor_hit := _ray(hang_xz, hang_xz + Vector3.DOWN * 1.5)
	if not floor_hit.is_empty():
		# Low platform: don't hang below the ground in front of it.
		hang.y = maxf(hang.y, (floor_hit["position"] as Vector3).y)

	# The straight path from you to the hang spot has to be clear.
	var blocker := _ray(global_position + Vector3.UP, hang + Vector3.UP)
	if not blocker.is_empty():
		return _no_ledge("the path to the hang spot is blocked by %s" % blocker["collider"])

	_dbg("ledge found: edge %s, hang %s, stand %s" % [edge, hang, stand])
	return {"edge": edge, "hang": hang, "stand": stand, "inward": inward}


func _has_ground(pos: Vector3) -> bool:
	var hit := _ray(pos + Vector3.UP * 0.3, pos + Vector3.DOWN * 0.3)
	return not hit.is_empty() and (hit["normal"] as Vector3).y > 0.7


func _has_headroom(pos: Vector3) -> bool:
	return _ray(pos + Vector3.UP * 0.1, pos + Vector3.UP * 1.9).is_empty()


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
	velocity = Vector3.ZERO

	# Scripted motion, no collisions, so the character never snags on the pole or the ledge.
	if _target_is_pole:
		# Arc that arrives from above, so it never passes through the pole.
		global_position = _bezier(_grapple_start, _grapple_arc, _grapple_dest, ease(t, ZIP_EASE))
	else:
		# Straight zip to the hang spot under the edge.
		global_position = _grapple_start.lerp(_grapple_dest, ease(t, ZIP_EASE))

	if _grapple_t >= 1.0:
		if _target_is_pole:
			_begin_perch()
		else:
			_begin_vault()


func _begin_vault() -> void:
	_grapple_state = GrappleState.VAULT
	_hop_elapsed = 0.0
	velocity = Vector3.ZERO
	_start_flip(_ledge_inward)  # somersault over the edge, toward the platform


func _process_vault(delta: float) -> void:
	# Scripted climb: up and over the edge, landing on top of the platform.
	_hop_elapsed += delta
	var t := clampf(_hop_elapsed / maxf(vault_time, 0.05), 0.0, 1.0)
	var control := _grapple_point + Vector3.UP * vault_arc_height + _ledge_inward * 0.1
	global_position = _bezier(_grapple_dest, control, _ledge_stand, ease(t, ZIP_EASE))
	velocity = Vector3.ZERO
	if jump_flip:
		_set_body_flip(0.0 if t >= 1.0 else TAU * ease(t, -1.6))
	if t >= 1.0:
		# You're on top: give control back, with a small push away from the edge.
		_flip_t = 1.0
		global_position = _ledge_stand
		velocity = _ledge_inward * vault_exit_speed
		_dbg("vault finished at %s (stand point was %s)" % [global_position, _ledge_stand])
		_begin_return()


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
	# Used when jumping off a pole. You can steer in the air while you fall.
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
	_dbg("sequence ended at %s, on floor: %s" % [global_position, is_on_floor()])
	_grapple_state = GrappleState.NONE
	_grapple_cd = grapple_cooldown
	_flip_t = 1.0
	_set_body_flip(0.0)
	_body.visible = false
	if _crosshair:
		_crosshair.visible = true
	camera.make_current()


func _is_look_locked() -> bool:
	return _grapple_state == GrappleState.TRAVEL or _grapple_state == GrappleState.VAULT


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
	var hit := _ray(from, desired)
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
	_add_action("reset", [KEY_R])
	_add_mouse_action("fire", MOUSE_BUTTON_LEFT)


func _add_action(action: StringName, keys: Array) -> void:
	if InputMap.has_action(action):
		return  # Project Settings take priority over these defaults.
	InputMap.add_action(action)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k as Key
		InputMap.action_add_event(action, ev)


func _add_mouse_action(action: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)
