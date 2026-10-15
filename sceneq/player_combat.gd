extends Node
## Player combat: hitscan weapon + health. Add it as a child Node of the Player:
##   Player > right-click > Add Child Node > Node (call it "Combat") > attach this script.
##
##   Left mouse button (hold) = shoot
##   Anything with a take_damage(amount) method can be shot (enemies have one).

signal health_changed(current: float, maximum: float)  ## connect a HUD to this later

@export_group("Weapon")
@export var damage := 20.0
@export var fire_rate := 6.0  ## shots per second (hold the button to keep firing)
@export var weapon_range := 100.0

@export_group("Health")
@export var max_health := 100.0
@export var restart_on_death := true  ## placeholder: reloads the scene when you die

var health := 100.0  ## read this from your HUD later

var _player: CharacterBody3D
var _fire_cd := 0.0
var _captured_last_frame := false
var _marker: ColorRect
var _marker_time := 0.0
var _flash: ColorRect
var _flash_alpha := 0.0


func _ready() -> void:
	_player = get_parent() as CharacterBody3D
	if _player == null:
		push_error("player_combat.gd must be a child of the Player node.")
		set_process(false)
		set_physics_process(false)
		return
	health = max_health
	add_to_group("player_combat")  # this is how enemies find the player
	_setup_input()
	_setup_ui()


func _physics_process(delta: float) -> void:
	_fire_cd = maxf(_fire_cd - delta, 0.0)

	# Don't shoot on the same click that recaptures the mouse, or during the grapple cutscene.
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var busy := bool(_player.get("is_grappling"))
	if captured and _captured_last_frame and not busy \
			and _fire_cd <= 0.0 and Input.is_action_pressed("fire"):
		_shoot()
	_captured_last_frame = captured


func _process(delta: float) -> void:
	# Fade the hit marker and the red damage flash.
	_marker_time = maxf(_marker_time - delta, 0.0)
	_marker.visible = _marker_time > 0.0
	_flash_alpha = maxf(_flash_alpha - delta * 2.5, 0.0)
	_flash.color = Color(1.0, 0.1, 0.1, _flash_alpha)


func _shoot() -> void:
	_fire_cd = 1.0 / maxf(fire_rate, 0.01)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var from := cam.global_transform.origin
	var to := from - cam.global_transform.basis.z * weapon_range
	var query := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [_player.get_rid()])
	var hit := _player.get_world_3d().direct_space_state.intersect_ray(query)

	var end := to
	if not hit.is_empty():
		end = hit["position"]
		var target := hit["collider"] as Node
		if target and target.has_method("take_damage"):
			target.call("take_damage", damage)
			_marker_time = 0.08
	_spawn_tracer(cam.global_transform * Vector3(0.3, -0.25, -0.6), end)


func take_damage(amount: float) -> void:
	if health <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	_flash_alpha = 0.45
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
	_player.add_child(tracer)
	var dir := offset / length
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	var tracer_basis := Basis.looking_at(dir, up) * Basis.from_scale(Vector3(1.0, 1.0, length))
	tracer.global_transform = Transform3D(tracer_basis, (from + to) * 0.5)
	get_tree().create_timer(0.05).timeout.connect(tracer.queue_free)


func _setup_input() -> void:
	if InputMap.has_action("fire"):
		return  # Project Settings take priority
	InputMap.add_action("fire")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("fire", ev)


func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10

	_flash = ColorRect.new()
	_flash.color = Color(1.0, 0.1, 0.1, 0.0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_flash)

	_marker = ColorRect.new()
	_marker.color = Color.WHITE
	_marker.custom_minimum_size = Vector2(14.0, 14.0)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	layer.add_child(_marker)

	add_child(layer)
	_flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_marker.pivot_offset = Vector2(7.0, 7.0)
	_marker.rotation = PI / 4.0  # a diamond
