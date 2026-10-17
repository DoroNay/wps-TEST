extends CharacterBody3D
## Movement, grapple, poles and shooting for a first-person arena shooter (Godot 4).
## Needs Head/Camera3D under this node. Poles are nodes in the group "pole" (optional child
## Marker3D "Top" sets the aim/stand point); keep poles OUTSIDE this node.
## Keys: WASD, Space jump, Shift dash, E grapple, left mouse shoot, R back to start, Esc free mouse.

signal health_changed(current: float, maximum: float)

enum GrappleState { NONE, TRAVEL, VAULT, PERCH, POLE_HOP, HOP, RETURN }
enum Target { LEDGE, POLE, FREE }

const ZIP_EASE := -2.0  ## negative = smooth in and out
const PERCH_FOLLOW := 14.0
const HOP_MIN_TIME := 0.1  ## ignore "landed" right after takeoff
const HOP_MAX_TIME := 4.0
const LEDGE_STEP := 0.15
const LEDGE_MAX := 12.0

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
@export_range(0.0, 1.0) var jump_cut := 0.5
@export var coyote_time := 0.10
@export var jump_buffer_time := 0.12
@export var auto_hop := true
@export_group("Dash")
@export var dash_speed := 34.0
@export var dash_duration := 0.14
@export var max_dash_charges := 2
@export var dash_recharge_time := 1.5
@export var dash_exit_speed_mult := 1.3
@export_group("Weapon")
@export var weapon_damage := 20.0
@export var fire_rate := 6.0
@export var weapon_range := 100.0
@export var debug_combat := false
@export_group("Health")
@export var max_health := 100.0
@export var restart_on_death := true  ## placeholder: reloads the scene
@export_group("Grapple")
@export var grapple_range := 70.0
@export var grapple_speed := 45.0
@export var grapple_min_time := 0.35
@export var grapple_max_time := 1.1
@export var grapple_hop_velocity := 9.0
@export var grapple_exit_speed := 8.0
@export var wall_kick_speed := 6.0
@export var grapple_ledge_reach := 4.0  ## how far above the aimed point a platform top can be
@export var vault_time := 0.4
@export var vault_arc_height := 1.6
@export var vault_exit_speed := 3.0
@export var grapple_return_time := 0.15  ## 0 = hard cut back to first person
@export var grapple_cooldown := 0.25
@export var grapple_lock_look := true
@export var jump_flip := true
@export var flip_duration := 0.55
@export var debug_grapple := false  ## prints grapple decisions to the Output panel
@export_group("Pole")
@export var pole_group := "pole"
@export var pole_arc_height := 2.0
@export var pole_jump_velocity := 12.0
@export var pole_jump_speed := 8.0
@export var pole_hop_stays_on_pole := true
@export var pole_hop_height := 1.6
@export var pole_hop_time := 0.55
@export_group("Pole aim zone")
@export var pole_zone_radius := 2.5  ## easy-to-hit area around a pole top, in meters
@export var pole_zone_min_angle := 3.0  ## degrees: far poles keep at least this much area
@export_group("Grapple prompt")
@export var prompt_sheet: Texture2D  ## "E to grapple" spritesheet, frames side by side
@export var prompt_hframes := 4
@export var prompt_vframes := 1
@export var prompt_fps := 8.0
@export var prompt_frames: SpriteFrames  ## OR a SpriteFrames resource (wins over the sheet)
@export var prompt_world_offset := Vector3(0.0, 1.2, 0.0)
@export var prompt_world_width := 2.0
@export var prompt_readable_distance := 12.0  ## farther than this it grows (0 = off)
@export var prompt_pixel_art := false
@export_group("Grapple camera")
@export var tp_distance := 4.5
@export var tp_height := 1.2
@export var tp_side := 1.1
@export var tp_fov := 85.0
@export var tp_follow_speed := 9.0
@export_group("Camera feel")
@export var fov_kick := 6.0
@export var fov_smoothing := 12.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var dash_charges: int
var health := 100.0
var is_grappling: bool:
	get:
		return _state != GrappleState.NONE

var _dash_timer := 0.0
var _dash_dir := Vector3.ZERO
var _dash_recharge := 0.0
var _coyote := 0.0
var _jump_buffer := 0.0
var _base_fov := 75.0
var _fire_cd := 0.0
var _was_captured := false
var _hit_marker: ColorRect
var _hit_marker_time := 0.0
var _hurt_flash: ColorRect
var _hurt_alpha := 0.0
var _crosshair: CanvasLayer
var _rope: MeshInstance3D
var _body: Node3D
var _body_rest := Transform3D.IDENTITY
var _tp_camera: Camera3D
var _spawn_transform := Transform3D.IDENTITY
var _spawn_pitch := 0.0

var _aimed_pole: Node3D = null
var _aimed_top := Vector3.ZERO
var _zone_debug_last: Node3D = null
var _prompt_node: Node3D
var _prompt_sheet: Sprite3D
var _prompt_anim: AnimatedSprite3D
var _prompt_time := 0.0
var _prompt_frames_n := 1
var _prompt_was_visible := false

var _state := GrappleState.NONE
var _target := Target.FREE
var _hook_point := Vector3.ZERO
var _zip_start := Vector3.ZERO
var _zip_dest := Vector3.ZERO  ## where the feet end up after the zip
var _zip_arc := Vector3.ZERO  ## bezier control point (poles)
var _zip_dir := Vector3.FORWARD
var _zip_t := 0.0
var _zip_time := 0.5
var _grapple_cd := 0.0
var _surface_normal := Vector3.UP
var _ledge_stand := Vector3.ZERO
var _ledge_inward := Vector3.FORWARD
var _elapsed := 0.0
var _return_timer := 0.0
var _return_total := 0.15
var _return_from_pos := Vector3.ZERO
var _return_from_fov := 75.0
var _flip_t := 1.0
var _flip_axis := Vector3.RIGHT


func _ready() -> void:
	add_to_group("player")  # enemies find you through this group
	health = max_health
	_spawn_transform = global_transform
	_spawn_pitch = head.rotation.x
	dash_charges = max_dash_charges
	_base_fov = camera.fov
	_setup_input()
	_setup_body()
	_setup_hud()
	_setup_prompt()
	_rope = _make_line(Color(1.0, 0.85, 0.3))
	_rope.visible = false
	_tp_camera = Camera3D.new()
	_tp_camera.top_level = true
	add_child(_tp_camera)
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if grapple_lock_look and (_state == GrappleState.TRAVEL or _state == GrappleState.VAULT):
			return
		var motion := event as InputEventMouseMotion
		rotate_y(-motion.relative.x * mouse_sensitivity)
		head.rotation.x = clampf(head.rotation.x - motion.relative.y * mouse_sensitivity,
			-PI / 2.0 + 0.01, PI / 2.0 - 0.01)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	_hit_marker_time = maxf(_hit_marker_time - delta, 0.0)
	_hit_marker.visible = _hit_marker_time > 0.0
	_hurt_alpha = maxf(_hurt_alpha - delta * 2.5, 0.0)
	_hurt_flash.color = Color(1.0, 0.1, 0.1, _hurt_alpha)
	if _crosshair:
		_crosshair.visible = _can_shoot()
	_update_prompt(delta)


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("reset"):
		_reset_to_spawn()
		return
	_update_weapon(delta)
	var on_floor := is_on_floor()
	_update_timers(delta, on_floor)
	_update_pole_zone()
	if _state == GrappleState.NONE and Input.is_action_just_pressed("grapple"):
		_try_grapple()

	match _state:
		GrappleState.TRAVEL: _process_travel(delta)
		GrappleState.VAULT: _process_vault(delta)
		GrappleState.PERCH: _process_perch()
		GrappleState.POLE_HOP: _process_pole_hop(delta)
		GrappleState.HOP: _process_hop(delta)
		GrappleState.RETURN:
			_move_normal(delta, on_floor)  # you already have control while the camera slides back
			_return_timer -= delta
			if _return_timer <= 0.0:
				_end_grapple()
		_: _move_normal(delta, on_floor)

	_rope.visible = _state == GrappleState.TRAVEL \
		and _place_line(_rope, global_transform * Vector3(0.35, 1.25, -0.35), _hook_point)
	_update_grapple_camera(delta)
	var speed := Vector2(velocity.x, velocity.z).length()
	var target_fov := _base_fov + fov_kick * clampf(speed / max_speed, 0.0, 2.0)
	camera.fov = lerpf(camera.fov, target_fov, 1.0 - exp(-fov_smoothing * delta))


func _reset_to_spawn() -> void:
	if _state != GrappleState.NONE:
		_end_grapple()
	global_transform = _spawn_transform
	head.rotation.x = _spawn_pitch
	velocity = Vector3.ZERO
	_dash_timer = 0.0
	_grapple_cd = 0.0
	dash_charges = max_dash_charges


# --- Basic movement ----------------------------------------------------------------

func _wish_dir() -> Vector3:
	var v := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	return (transform.basis * Vector3(v.x, 0.0, v.y)).normalized()


func _move_normal(delta: float, on_floor: bool) -> void:
	var wish := _wish_dir()
	if Input.is_action_just_pressed("dash") and dash_charges > 0 and _dash_timer <= 0.0:
		_dash_dir = wish if wish != Vector3.ZERO else -transform.basis.z
		dash_charges -= 1
		_dash_timer = dash_duration

	if _dash_timer > 0.0:
		_dash_timer -= delta
		var flat := Vector3(_dash_dir.x, 0.0, _dash_dir.z)
		velocity = flat * (dash_speed if _dash_timer > 0.0 else max_speed * dash_exit_speed_mult)
	else:
		_apply_gravity(delta)
		if _jump_buffer > 0.0 and _coyote > 0.0:
			velocity.y = jump_velocity
			_jump_buffer = 0.0
			_coyote = 0.0
		if Input.is_action_just_released("jump") and velocity.y > 0.0:
			velocity.y *= jump_cut  # releasing early cuts the jump short
		_handle_horizontal(delta, wish, on_floor)
	move_and_slide()


func _update_timers(delta: float, on_floor: bool) -> void:
	_coyote = coyote_time if on_floor else _coyote - delta
	var wants_jump := Input.is_action_just_pressed("jump") \
		or (auto_hop and Input.is_action_pressed("jump"))
	_jump_buffer = jump_buffer_time if wants_jump else _jump_buffer - delta
	_grapple_cd = maxf(_grapple_cd - delta, 0.0)
	if dash_charges < max_dash_charges:
		_dash_recharge += delta
		if _dash_recharge >= dash_recharge_time:
			dash_charges += 1
			_dash_recharge = 0.0


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * (fall_gravity_multiplier if velocity.y < 0.0 else 1.0) * delta


func _handle_horizontal(delta: float, wish: Vector3, on_floor: bool) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z)
	if on_floor:
		h = h.move_toward(wish * max_speed, ground_accel * delta) if wish != Vector3.ZERO \
			else h.move_toward(Vector3.ZERO, ground_friction * delta)
	elif wish != Vector3.ZERO:
		h = h.move_toward(wish * max_speed, air_accel * delta)  # air: steer, keep momentum otherwise
	velocity.x = h.x
	velocity.z = h.z


# --- Weapon and health -------------------------------------------------------------

func _can_shoot() -> bool:
	return _state != GrappleState.TRAVEL and _state != GrappleState.VAULT


func _update_weapon(delta: float) -> void:
	_fire_cd = maxf(_fire_cd - delta, 0.0)
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	# Not on the click that recaptures the mouse, and not during the zip.
	if captured and _was_captured and _can_shoot() and _fire_cd <= 0.0 \
			and Input.is_action_pressed("fire"):
		_shoot()
	_was_captured = captured


func _shoot() -> void:
	_fire_cd = 1.0 / maxf(fire_rate, 0.01)
	var from := camera.global_transform.origin
	var dir := -camera.global_transform.basis.z
	var muzzle := camera.global_transform * Vector3(0.3, -0.25, -0.6)
	if _state in [GrappleState.PERCH, GrappleState.POLE_HOP, GrappleState.HOP]:
		# Over-the-shoulder view: find what's under the crosshair, then shoot from the hand.
		var cam := _tp_camera.global_transform
		var cam_dir := -cam.basis.z
		var aim_point := cam.origin + cam_dir * weapon_range
		var aim_hit := _ray(cam.origin, aim_point)
		if not aim_hit.is_empty():
			aim_point = aim_hit["position"]
		muzzle = global_transform * Vector3(0.35, 1.25, -0.35)
		from = muzzle
		dir = (aim_point - muzzle).normalized()
		if dir.dot(cam_dir) <= 0.0:
			dir = cam_dir

	var end := from + dir * weapon_range
	var hit := _ray(from, end)
	if hit.is_empty():
		if debug_combat:
			print("[combat] hit nothing")
	else:
		end = hit["position"]
		var target := hit["collider"] as Node
		var can_hurt := target != null and target.has_method("take_damage")
		if debug_combat:
			print("[combat] hit ", target, " (damageable: ", can_hurt, ")")
		if can_hurt:
			target.call("take_damage", weapon_damage)
			_hit_marker_time = 0.08
	var tracer := _make_line(Color(1.0, 0.95, 0.6))
	_place_line(tracer, muzzle, end, 0.67)
	get_tree().create_timer(0.05).timeout.connect(tracer.queue_free)


func take_damage(amount: float) -> void:
	if health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	_hurt_alpha = 0.45
	health_changed.emit(health, max_health)
	if health <= 0.0 and restart_on_death:
		get_tree().reload_current_scene.call_deferred()


# --- Pole aim zone and the "E to grapple" sprite -----------------------------------

func _update_pole_zone() -> void:
	# The pole whose top you're aiming at. Your aim line doesn't have to touch the pole,
	# passing within pole_zone_radius of its top is enough.
	_aimed_pole = null
	if _state == GrappleState.NONE and _grapple_cd <= 0.0 and _dash_timer <= 0.0:
		var cam := camera.global_transform
		var aim := -cam.basis.z
		var hit := _ray(cam.origin, cam.origin + aim * grapple_range)
		var hit_dist := INF
		var hit_pole: Node3D = null
		if not hit.is_empty():
			hit_dist = cam.origin.distance_to(hit["position"])
			hit_pole = _find_pole(hit["collider"] as Node)

		var best := INF
		for node in get_tree().get_nodes_in_group(pole_group):
			var pole := node as Node3D
			if pole == null:
				continue
			var top := _pole_top(pole, pole.global_position)
			var to_top := top - cam.origin
			var along := to_top.dot(aim)
			if along < 0.5 or along > grapple_range:
				continue
			# Something else closer than the pole top means you're aiming at that, not at the pole.
			if hit_dist < along - 1.0 and hit_pole != pole:
				continue
			var off_axis := (to_top - aim * along).length()
			if off_axis >= best or off_axis > maxf(pole_zone_radius, along * tan(deg_to_rad(pole_zone_min_angle))):
				continue
			# The top has to be visible: only the pole itself may be in the way.
			var blocker := _ray(cam.origin, top + (cam.origin - top).normalized() * 0.1)
			if not blocker.is_empty() and _find_pole(blocker["collider"] as Node) != pole:
				continue
			best = off_axis
			_aimed_pole = pole
			_aimed_top = top

	if debug_grapple and _aimed_pole != _zone_debug_last:
		_zone_debug_last = _aimed_pole
		print("[grapple] pole zone: ", _aimed_pole.name if _aimed_pole else "none")


func _setup_prompt() -> void:
	var sprite: SpriteBase3D = null
	var frame_w := 256.0
	if prompt_frames and not prompt_frames.get_animation_names().is_empty():
		var anim := &"default" if prompt_frames.has_animation(&"default") \
			else StringName(prompt_frames.get_animation_names()[0])
		_prompt_anim = AnimatedSprite3D.new()
		_prompt_anim.sprite_frames = prompt_frames
		_prompt_anim.animation = anim
		var first := prompt_frames.get_frame_texture(anim, 0)
		frame_w = float(first.get_width()) if first else frame_w
		sprite = _prompt_anim
	elif prompt_sheet:
		_prompt_sheet = Sprite3D.new()
		_prompt_sheet.texture = prompt_sheet
		_prompt_sheet.hframes = maxi(prompt_hframes, 1)
		_prompt_sheet.vframes = maxi(prompt_vframes, 1)
		_prompt_frames_n = _prompt_sheet.hframes * _prompt_sheet.vframes
		frame_w = float(prompt_sheet.get_width()) / _prompt_sheet.hframes
		sprite = _prompt_sheet

	if sprite:
		sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sprite.shaded = false
		sprite.no_depth_test = true
		sprite.pixel_size = prompt_world_width / maxf(frame_w, 1.0)
		sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST if prompt_pixel_art \
			else BaseMaterial3D.TEXTURE_FILTER_LINEAR
		_prompt_node = sprite
	else:
		var label := Label3D.new()  # nothing assigned yet: plain text so you can test the zone
		label.text = "E to grapple"
		label.font_size = 64
		label.outline_size = 12
		label.pixel_size = 0.005
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.shaded = false
		label.no_depth_test = true
		_prompt_node = label
	_prompt_node.top_level = true
	_prompt_node.visible = false
	add_child(_prompt_node)


func _update_prompt(delta: float) -> void:
	var show := is_instance_valid(_aimed_pole)
	_prompt_node.visible = show
	if show and not _prompt_was_visible:
		_prompt_time = 0.0
		if _prompt_anim:
			_prompt_anim.stop()
			_prompt_anim.play()
	_prompt_was_visible = show
	if not show:
		return

	var pos := _aimed_top + prompt_world_offset
	_prompt_node.global_position = pos
	var grow := 1.0
	if prompt_readable_distance > 0.0:
		grow = maxf(1.0, camera.global_position.distance_to(pos) / prompt_readable_distance)
	var pulse := 1.0 + 0.08 * sin(Time.get_ticks_msec() * 0.008) if _prompt_node is Label3D else 1.0
	_prompt_node.scale = Vector3.ONE * grow * pulse
	if _prompt_sheet:
		_prompt_time += delta
		_prompt_sheet.frame = int(_prompt_time * prompt_fps) % _prompt_frames_n


# --- Grapple -----------------------------------------------------------------------
# Platform edge: TRAVEL -> VAULT -> RETURN. Pole: TRAVEL -> PERCH (-> POLE_HOP / HOP -> RETURN).
# Any other surface: TRAVEL -> HOP -> RETURN.

func _try_grapple() -> void:
	if _grapple_cd > 0.0 or _dash_timer > 0.0:
		return
	var point: Vector3
	var dest: Vector3
	var target := Target.FREE

	if is_instance_valid(_aimed_pole):
		target = Target.POLE
		point = _aimed_top
		dest = point + Vector3.UP * 0.02
	else:
		var from := camera.global_transform.origin
		var hit := _ray(from, from - camera.global_transform.basis.z * grapple_range)
		if hit.is_empty():
			_dbg("nothing in range to hook")
			return
		point = hit["position"]
		var normal: Vector3 = hit["normal"]
		var collider := hit["collider"] as Node
		if collider and collider.is_in_group("enemies"):
			return
		if _find_pole(collider) != null:
			_dbg("poles can only be hooked by aiming at the area around their top")
			return
		var ledge := _find_ledge(point, normal)
		if ledge.is_empty():
			dest = _surface_destination(point, normal)
			_surface_normal = normal
		else:
			target = Target.LEDGE
			point = ledge["edge"]
			dest = ledge["hang"]
			_ledge_stand = ledge["stand"]
			_ledge_inward = ledge["inward"]

	var dist := global_position.distance_to(dest)
	if dist < 2.0:
		_dbg("too close to the target")
		return

	_target = target
	_hook_point = point
	_zip_start = global_position
	_zip_dest = dest
	_zip_dir = (dest - global_position).normalized()
	_zip_time = clampf(dist / grapple_speed, grapple_min_time, grapple_max_time)
	_zip_t = 0.0
	if target == Target.POLE:
		var arc := global_position.lerp(dest, 0.5)  # arrives from above, never through the pole
		arc.y = maxf(arc.y, dest.y) + pole_arc_height
		_zip_arc = arc

	_state = GrappleState.TRAVEL
	velocity = Vector3.ZERO
	_flip_t = 1.0
	_set_flip(0.0)
	_body.visible = true
	_tp_camera.global_transform = camera.global_transform
	_tp_camera.fov = camera.fov
	_tp_camera.make_current()


func _surface_destination(point: Vector3, normal: Vector3) -> Vector3:
	# Where the FEET end up when hooking a plain floor, ceiling or wall.
	if normal.y > 0.7:
		return point + normal * 0.05
	if normal.y < -0.7:
		return point + normal * 1.85
	var dest := point + normal * 0.6 - Vector3.UP * 0.9  # wall: chest at the hit point
	var ground := _ray(dest + Vector3.UP, dest + Vector3.DOWN * 2.0)
	if not ground.is_empty():
		dest.y = maxf(dest.y, (ground["position"] as Vector3).y)
	return dest


func _no_ledge(reason: String) -> Dictionary:
	_dbg("no ledge: " + reason)
	return {}


func _has_room(pos: Vector3) -> bool:
	# Solid ground under pos and room for a standing body above it.
	var ground := _ray(pos + Vector3.UP * 0.3, pos + Vector3.DOWN * 0.3)
	return not ground.is_empty() and (ground["normal"] as Vector3).y > 0.7 \
		and _ray(pos + Vector3.UP * 0.1, pos + Vector3.UP * 1.9).is_empty()


func _find_ledge(point: Vector3, normal: Vector3) -> Dictionary:
	# Returns {edge, hang, stand, inward} for a platform edge at the aimed spot, or {}.
	var face_point := point
	var face_normal := normal

	if normal.y > 0.7:
		# Aimed at a top surface: walk toward the player along it until it ends (ground never does).
		var to_player := Vector3(global_position.x - point.x, 0.0, global_position.z - point.z)
		var remaining := to_player.length()
		if remaining < 0.5:
			return _no_ledge("aimed at a top surface right next to you")
		var toward := to_player / remaining
		var q := point
		var outside := point
		var found := false
		for i in int(minf(remaining, LEDGE_MAX) / LEDGE_STEP):
			var next := q + toward * LEDGE_STEP
			var ground := _ray(next + Vector3.UP * 0.3, next + Vector3.DOWN * 0.3)
			if ground.is_empty() or (ground["normal"] as Vector3).y < 0.7:
				outside = next
				found = true
				break
			q = ground["position"]
		if not found:
			return _no_ledge("that surface doesn't end before it reaches you")
		face_point = q
		face_normal = toward
		var probe_out := outside + Vector3.DOWN * 0.3
		var face := _ray(probe_out, probe_out - toward * 0.6)
		if not face.is_empty() and absf((face["normal"] as Vector3).y) < 0.5:
			face_point = face["position"]
			face_normal = face["normal"]

	if absf(face_normal.y) > 0.5:
		return _no_ledge("the aimed face isn't vertical")
	var outward := Vector3(face_normal.x, 0.0, face_normal.z).normalized()
	var inward := -outward

	# The platform top: shoot down from above, just inside the face.
	var probe := face_point + inward * 0.25
	var top := _ray(Vector3(probe.x, face_point.y + grapple_ledge_reach, probe.z),
		Vector3(probe.x, face_point.y - 0.05, probe.z))
	if top.is_empty() or (top["normal"] as Vector3).y < 0.7 \
			or (top["position"] as Vector3).y < face_point.y - 0.05:
		return _no_ledge("no platform top within reach above the aimed point")
	var edge := Vector3(face_point.x, (top["position"] as Vector3).y, face_point.z)

	var stand := Vector3.ZERO
	var has_stand := false
	for inset: float in [0.7, 0.45]:
		var candidate := edge + inward * inset + Vector3.UP * 0.02
		if _has_room(candidate):
			stand = candidate
			has_stand = true
			break
	if not has_stand:
		return _no_ledge("no room to stand on top")

	# Hang spot: against the wall, chest about at the edge (but not below the ground).
	var hang_xz := edge + outward * 0.5
	var hang := hang_xz - Vector3.UP
	var floor_hit := _ray(hang_xz, hang_xz + Vector3.DOWN * 1.5)
	if not floor_hit.is_empty():
		hang.y = maxf(hang.y, (floor_hit["position"] as Vector3).y)
	if not _ray(global_position + Vector3.UP, hang + Vector3.UP).is_empty():
		return _no_ledge("the path to the hang spot is blocked")
	return {"edge": edge, "hang": hang, "stand": stand, "inward": inward}


func _find_pole(node: Node) -> Node3D:
	var n := node
	while n != null:
		if n.is_in_group(pole_group):
			return n as Node3D
		n = n.get_parent()
	return null


func _pole_top(pole: Node3D, fallback: Vector3) -> Vector3:
	var marker := pole.get_node_or_null("Top") as Node3D
	if marker:
		return marker.global_position
	# Otherwise the top-center of the pole's bounding box (assumes an upright pole).
	var visual := pole as VisualInstance3D
	if visual == null:
		var found := pole.find_children("*", "VisualInstance3D", true, false)
		visual = found[0] as VisualInstance3D if not found.is_empty() else null
	if visual:
		var box := visual.get_aabb()
		return visual.global_transform * Vector3(box.get_center().x, box.end.y, box.get_center().z)
	return fallback


func _process_travel(delta: float) -> void:
	_zip_t += delta / _zip_time
	var t := ease(clampf(_zip_t, 0.0, 1.0), ZIP_EASE)
	velocity = Vector3.ZERO
	global_position = _bezier(_zip_start, _zip_arc, _zip_dest, t) if _target == Target.POLE \
		else _zip_start.lerp(_zip_dest, t)
	if _zip_t >= 1.0:
		match _target:
			Target.POLE: _begin_perch()
			Target.LEDGE: _begin_vault()
			_: _begin_free_arrival()


func _begin_free_arrival() -> void:
	# Hooked a wall, the ground or a ceiling: a little hop, then you're free (steer and shoot).
	_state = GrappleState.HOP
	_elapsed = 0.0
	var n := _surface_normal
	var vel := Vector3.ZERO  # ceiling: you just drop
	if n.y > 0.7:
		vel = Vector3(_zip_dir.x, 0.0, _zip_dir.z).normalized() * grapple_exit_speed \
			+ Vector3.UP * grapple_hop_velocity
	elif n.y >= -0.7:
		vel = Vector3(n.x, 0.0, n.z).normalized() * wall_kick_speed + Vector3.UP * grapple_hop_velocity
	velocity = vel
	_start_flip(vel)


func _begin_vault() -> void:
	_state = GrappleState.VAULT
	_elapsed = 0.0
	velocity = Vector3.ZERO
	_start_flip(_ledge_inward)


func _process_vault(delta: float) -> void:
	_elapsed += delta
	var t := clampf(_elapsed / maxf(vault_time, 0.05), 0.0, 1.0)
	var control := _hook_point + Vector3.UP * vault_arc_height + _ledge_inward * 0.1
	global_position = _bezier(_zip_dest, control, _ledge_stand, ease(t, ZIP_EASE))
	velocity = Vector3.ZERO
	if jump_flip:
		_set_flip(0.0 if t >= 1.0 else TAU * ease(t, -1.6))
	if t >= 1.0:
		_flip_t = 1.0
		global_position = _ledge_stand
		velocity = _ledge_inward * vault_exit_speed
		_begin_return()


func _begin_perch() -> void:
	_state = GrappleState.PERCH
	global_position = _zip_dest
	velocity = Vector3.ZERO


func _process_perch() -> void:
	# Locked on top of the pole: look around, shoot, then hop or jump off.
	global_position = _zip_dest
	velocity = Vector3.ZERO
	if Input.is_action_just_pressed("jump"):
		_pole_jump()


func _pole_jump() -> void:
	var wish := _wish_dir()
	_elapsed = 0.0
	if wish == Vector3.ZERO and pole_hop_stays_on_pole:
		_state = GrappleState.POLE_HOP  # hop in place, land back on the pole
		_start_flip(-transform.basis.z)
		return
	velocity = wish * pole_jump_speed + Vector3.UP * pole_jump_velocity
	_state = GrappleState.HOP
	_start_flip(wish if wish != Vector3.ZERO else -transform.basis.z)


func _process_pole_hop(delta: float) -> void:
	_elapsed += delta
	var t := clampf(_elapsed / maxf(pole_hop_time, 0.05), 0.0, 1.0)
	global_position = _zip_dest + Vector3.UP * (4.0 * t * (1.0 - t) * pole_hop_height)
	velocity = Vector3.ZERO
	if jump_flip:
		_set_flip(0.0 if t >= 1.0 else TAU * ease(t, -1.6))
	if t >= 1.0:
		_flip_t = 1.0
		_state = GrappleState.PERCH


func _process_hop(delta: float) -> void:
	# After hooking a plain surface or jumping off a pole. First person returns when you land.
	_apply_gravity(delta)
	_handle_horizontal(delta, _wish_dir(), false)
	move_and_slide()
	_elapsed += delta
	_update_flip(delta)
	if (_elapsed > HOP_MIN_TIME and is_on_floor()) or _elapsed > HOP_MAX_TIME:
		_begin_return()


func _begin_return() -> void:
	_state = GrappleState.RETURN
	_return_total = maxf(grapple_return_time, 0.001)
	_return_timer = grapple_return_time
	_return_from_pos = _tp_camera.global_transform.origin
	_return_from_fov = _tp_camera.fov


func _end_grapple() -> void:
	_state = GrappleState.NONE
	_grapple_cd = grapple_cooldown
	_flip_t = 1.0
	_set_flip(0.0)
	_body.visible = false
	camera.make_current()


# --- Flip (somersault of the body while airborne in the third-person view) ------------

func _start_flip(move_dir: Vector3) -> void:
	if not jump_flip:
		_flip_t = 1.0
		return
	var flat := Vector3(move_dir.x, 0.0, move_dir.z)
	if flat.length() < 0.1:
		flat = -global_transform.basis.z
	_flip_axis = Vector3.UP.cross(flat.normalized())  # head-first toward the movement direction
	_flip_t = 0.0


func _update_flip(delta: float) -> void:
	if _flip_t >= 1.0:
		return
	_flip_t = minf(_flip_t + delta / maxf(flip_duration, 0.01), 1.0)
	_set_flip(0.0 if _flip_t >= 1.0 else TAU * ease(_flip_t, -1.6))


func _set_flip(angle: float) -> void:
	# Spins the body around its center; the axis stays fixed in the world.
	var pivot := Vector3(0.0, 0.9, 0.0)
	var rot := Basis((global_transform.basis.inverse() * _flip_axis).normalized(), angle)
	_body.transform = Transform3D(rot, pivot - rot * pivot) * _body_rest


# --- Third-person camera during the grapple ----------------------------------------

func _update_grapple_camera(delta: float) -> void:
	if _state == GrappleState.NONE:
		return
	# Rotation always matches the first-person aim; only the position moves, so going back
	# to first person never spins the view.
	var aim_basis := camera.global_transform.basis
	var pos: Vector3
	var fov: float
	if _state == GrappleState.RETURN:
		var p := smoothstep(0.0, 1.0, 1.0 - clampf(_return_timer / _return_total, 0.0, 1.0))
		pos = _return_from_pos.lerp(camera.global_transform.origin, p)
		fov = lerpf(_return_from_fov, camera.fov, p)
	else:
		var on_pole := _state == GrappleState.PERCH or _state == GrappleState.POLE_HOP
		var center := global_position + Vector3.UP
		var desired := center + aim_basis.z * tp_distance + Vector3.UP * tp_height \
			+ aim_basis.x * tp_side
		var hit := _ray(center, desired)  # keep the camera out of walls
		if not hit.is_empty():
			desired = (hit["position"] as Vector3) + (hit["normal"] as Vector3) * 0.2
		var w := 1.0 - exp(-(PERCH_FOLLOW if on_pole else tp_follow_speed) * delta)
		pos = _tp_camera.global_transform.origin.lerp(desired, w)
		fov = lerpf(_tp_camera.fov, tp_fov, w)
	_tp_camera.global_transform = Transform3D(aim_basis, pos)
	_tp_camera.fov = fov


# --- Helpers and one-time setup ------------------------------------------------------

func _dbg(msg: String) -> void:
	if debug_grapple:
		print("[grapple] ", msg)


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


func _bezier(a: Vector3, b: Vector3, c: Vector3, t: float) -> Vector3:
	return a.lerp(b, t).lerp(b.lerp(c, t), t)


func _looking_basis(direction: Vector3) -> Basis:
	var d := direction.normalized()
	return Basis.looking_at(d, Vector3.UP if absf(d.y) < 0.99 else Vector3.RIGHT)


func _make_line(color: Color) -> MeshInstance3D:
	# A thin unlit box, stretched between two points by _place_line (rope, bullet tracers).
	var box := BoxMesh.new()
	box.size = Vector3(0.03, 0.03, 1.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	var line := MeshInstance3D.new()
	line.mesh = box
	line.material_override = mat
	line.top_level = true
	add_child(line)
	return line


func _place_line(line: MeshInstance3D, from: Vector3, to: Vector3, width := 1.0) -> bool:
	var offset := to - from
	var length := offset.length()
	if length < 0.05:
		return false
	line.global_transform = Transform3D(
		_looking_basis(offset) * Basis.from_scale(Vector3(width, width, length)), (from + to) * 0.5)
	return true


func _add_body_part(mesh: Mesh, color: Color, pos: Vector3) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = mat
	part.position = pos
	_body.add_child(part)


func _setup_body() -> void:
	# Your own model: add a Node3D called "Body". Otherwise a placeholder capsule is built.
	if has_node("Body"):
		_body = get_node("Body") as Node3D
	else:
		_body = Node3D.new()
		add_child(_body)
		var capsule := CapsuleMesh.new()
		capsule.radius = 0.4
		capsule.height = 1.8
		_add_body_part(capsule, Color(0.9, 0.35, 0.25), Vector3(0.0, 0.9, 0.0))
		var visor := BoxMesh.new()  # shows which way it faces
		visor.size = Vector3(0.5, 0.14, 0.2)
		_add_body_part(visor, Color(0.1, 0.1, 0.12), Vector3(0.0, 1.45, -0.34))
	_body_rest = _body.transform
	_body.visible = false


func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	_hurt_flash = ColorRect.new()
	_hurt_flash.color = Color(1.0, 0.1, 0.1, 0.0)
	_hurt_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hurt_flash)
	_hit_marker = ColorRect.new()
	_hit_marker.custom_minimum_size = Vector2(14.0, 14.0)
	_hit_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_marker.visible = false
	layer.add_child(_hit_marker)
	add_child(layer)
	_hurt_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hit_marker.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_hit_marker.pivot_offset = Vector2(7.0, 7.0)
	_hit_marker.rotation = PI / 4.0  # a diamond

	if show_crosshair:
		_crosshair = CanvasLayer.new()
		var dot := ColorRect.new()
		dot.color = Color(1.0, 1.0, 1.0, 0.85)
		dot.custom_minimum_size = Vector2(4.0, 4.0)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_crosshair.add_child(dot)
		add_child(_crosshair)
		dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)


func _setup_input() -> void:
	# Only registered if you haven't defined the action in the Input Map yourself.
	var keys := {"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D,
		"jump": KEY_SPACE, "dash": KEY_SHIFT, "grapple": KEY_E, "reset": KEY_R}
	for action: String in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var key := InputEventKey.new()
			key.physical_keycode = keys[action] as Key
			InputMap.action_add_event(action, key)
	if not InputMap.has_action("fire"):
		InputMap.add_action("fire")
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("fire", click)
