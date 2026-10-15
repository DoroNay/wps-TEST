extends CharacterBody3D
## A simple billboard-sprite enemy that loops a sprite-sheet animation (Doom style).
##
## Setup: add a CharacterBody3D to your level, attach this script, then in the Inspector
## drag your sprite sheet into "Sprite Sheet" and set H Frames / V Frames.
## The sprite and the collision are created in code, so the enemy only shows up
## when you run the game, not in the editor viewport.

@export_group("Sprite")
@export var sprite_sheet: Texture2D  ## drag your sprite-sheet image here
@export var hframes := 4  ## columns in the sheet (4 for a horizontal strip of 4 frames)
@export var vframes := 1  ## rows in the sheet
@export var fps := 8.0  ## animation speed; low values (6-10) give a stop-motion feel
@export var world_height := 2.0  ## how tall the enemy is in the game, in meters
@export var always_upright := true  ## true = turns to face you but never tilts (Doom style)
@export var pixel_art := false  ## true = sharp pixels, false = smooth edges
@export var randomize_start := true  ## so several enemies don't animate in perfect sync

@export_group("Body")
@export var collision_radius := 0.4
@export var gravity := 32.0

var _sprite: Sprite3D
var _time := 0.0
var _frame_count := 1


func _ready() -> void:
	_frame_count = maxi(hframes * vframes, 1)
	_build_sprite()
	_build_collision()
	if randomize_start:
		_time = randf() * float(_frame_count) / maxf(fps, 0.01)


func _process(delta: float) -> void:
	# Loop through the frames: 0, 1, 2, 3, 0, 1, 2, 3...
	_time += delta
	_sprite.frame = int(_time * fps) % _frame_count


func _physics_process(delta: float) -> void:
	# Just gravity for now, so the enemy settles onto the floor.
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta
	move_and_slide()


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
