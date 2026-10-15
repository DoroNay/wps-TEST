extends CharacterBody3D
## A billboard-sprite enemy: loops its animation, chases the player, melee-attacks,
## has health, and dies when shot.
##
## Setup: a CharacterBody3D with this script. Drag your sprite sheet into "Sprite Sheet"
## and set H Frames / V Frames. It finds you through the "player" group, which player.gd
## joins by itself, so there's nothing else to set up.

signal died

enum State { CHASE, WINDUP, RECOVER, DEAD }

@export_group("Sprite")
@export var sprite_sheet: Texture2D  ## drag your sprite-sheet image here
@export var hframes := 4  ## columns in the sheet (4 for a horizontal strip of 4 frames)
@export var vframes := 1  ## rows in the sheet
@export var fps := 8.0  ## animation speed; low values (6-10) give a stop-motion feel
@export var world_height := 2.0  ## how tall the enemy is in the game, in meters
@export var always_upright := true  ## true = turns to face you but never tilts (Doom style)
@export var pixel_art := false  ## true = sharp pixels, false = smooth edges
@export var randomize_start := true  ## so several enemies don't animate in perfect sync

@export_group("Stats")
@export var max_health := 60.0
@export var move_speed := 4.0

@export_group("Attack")
@export var attack_range := 1.7  ## starts an attack when this close (flat distance)
@export var attack_height := 1.2  ## can't hit you if you're this much higher or lower: platforms and poles are safe
@export var stop_distance := 1.2  ## stays this far from you while chasing
@export var attack_damage := 10.0
@export var attack_windup := 0.35  ## warning (the sprite turns yellow) before the hit lands
@export var attack_cooldown := 0.9  ## pause after an attack
@export var hit_reach := 2.3  ## the hit only lands if you're still this close, so you can dodge

@export_group("Body")
@export var collision_radius := 0.4
@export var gravity := 32.0

var health := 60.0

var _sprite: Sprite3D
var _state := State.CHASE
var _state_time := 0.0
var _time := 0.0
var _frame_count := 1
var _flash_time := 0.0
var _player: Node3D
var _no_player_time := 0.0
var _warned := false


func _ready() -> void:
	_frame_count = maxi(hframes * vframes, 1)
	health = max_health
	add_to_group("enemies")  # handy later for counting enemies in a wave
	_build_sprite()
	_build_collision()
	if randomize_start:
		_time = randf() * float(_frame_count) / maxf(fps, 0.01)
	_find_target()


func _process(delta: float) -> void:
	# Loop through the frames: 0, 1, 2, 3, 0, 1, 2, 3... (frozen once dead)
	if _state != State.DEAD:
		_time += delta
		_sprite.frame = int(_time * fps) % _frame_count

	# Tint: red when hit, yellow while winding up an attack.
	_flash_time = maxf(_flash_time - delta, 0.0)
	if _flash_time > 0.0:
		_sprite.modulate = Color(1.0, 0.3, 0.3)
	elif _state == State.WINDUP:
		_sprite.modulate = Color(1.0, 0.85, 0.3)
	else:
		_sprite.modulate = Color.WHITE


func _physics_process(delta: float) -> void:
	if _state == State.DEAD:
		return

	if _player == null:
		_find_target()
		if _player == null:
			_no_player_time += delta
			if _no_player_time > 1.0 and not _warned:
				_warned = true
				push_warning("Enemy can't find the player. Is player.gd attached to your Player node?")

	var to_player := Vector3.ZERO
	var dist := INF
	var can_reach := false
	if _player:
		to_player = _player.global_position - global_position
		# Melee only works at about the same height. On a pole or a high platform you're safe.
		can_reach = absf(to_player.y) <= attack_height
		to_player.y = 0.0
		dist = to_player.length()

	var move_dir := Vector3.ZERO
	match _state:
		State.CHASE:
			if dist <= attack_range and can_reach:
				_state = State.WINDUP
				_state_time = attack_windup
			elif _player and dist > stop_distance:
				move_dir = to_player / dist
		State.WINDUP:
			# Standing still, telegraphing the hit.
			_state_time -= delta
			if _state_time <= 0.0:
				if _player and dist <= hit_reach and can_reach and _player.has_method("take_damage"):
					_player.call("take_damage", attack_damage)
				_state = State.RECOVER
				_state_time = attack_cooldown
		State.RECOVER:
			_state_time -= delta
			if _state_time <= 0.0:
				_state = State.CHASE

	velocity.x = move_dir.x * move_speed
	velocity.z = move_dir.z * move_speed
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()


func take_damage(amount: float) -> void:
	if _state == State.DEAD:
		return
	health -= amount
	_flash_time = 0.1
	if health <= 0.0:
		_die()


func _die() -> void:
	_state = State.DEAD
	velocity = Vector3.ZERO
	# Stop being shootable / solid right away.
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)
	died.emit()
	# Squash flat like a paper cutout being stamped, then disappear.
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_sprite, "scale", Vector3(1.3, 0.05, 1.3), 0.25)
	tween.tween_property(_sprite, "position:y", 0.0, 0.25)
	tween.chain().tween_callback(queue_free)


func _find_target() -> void:
	_player = get_tree().get_first_node_in_group("player") as Node3D


func _build_sprite() -> void:
	if sprite_sheet == null:
		push_warning("Enemy has no Sprite Sheet assigned (see the Inspector).")

	_sprite = Sprite3D.new()
	_sprite.texture = sprite_sheet
	_sprite.hframes = maxi(hframes, 1)
	_sprite.vframes = maxi(vframes, 1)
	_sprite.shaded = false  # flat, unlit look
	_sprite.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y if always_upright \
		else BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_OPAQUE_PREPASS  # clean edges, no sorting glitches
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST if pixel_art \
		else BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

	if sprite_sheet:
		# Size the sprite so one frame is exactly world_height meters tall.
		var frame_height := float(sprite_sheet.get_height()) / float(maxi(vframes, 1))
		_sprite.pixel_size = world_height / maxf(frame_height, 1.0)

	# The enemy's origin is at its feet, so lift the sprite by half its height.
	_sprite.position.y = world_height * 0.5
	add_child(_sprite)


func _build_collision() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = collision_radius
	shape.height = maxf(world_height, collision_radius * 2.0)
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position.y = shape.height * 0.5
	add_child(col)
