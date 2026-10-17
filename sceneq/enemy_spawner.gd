extends Node3D
## Spawns a horde of enemies. Put this node in the middle of your arena.
## Give it EITHER an enemy scene OR an Enemy node that's already in your level.
## Press T while playing to clear the horde and spawn it again.

@export var enemy_scene: PackedScene  ## option A: an enemy saved as its own scene
@export var enemy_template: Node3D  ## option B: an Enemy node in your level (used as the pattern, then removed)
@export var count := 100
@export var radius := 25.0  ## enemies appear randomly inside this circle around the spawner
@export var min_player_distance := 12.0  ## ...but never closer than this to the player
@export var spawn_over_seconds := 0.0  ## 0 = all at once, otherwise spread over this time
@export var speed_variation := 0.25  ## +/- random speed, so they don't arrive as one blob
@export var spawn_on_start := true

const RAY_HEIGHT := 20.0  ## floor search starts this far above the spawner (assumes open sky)

var _generation := 0
var _busy := false
var _template_script: Script
var _template_props := {}


func _ready() -> void:
	# Option B: remember the Enemy node's script and Inspector values, then remove it.
	if enemy_scene == null and enemy_template != null:
		_template_script = enemy_template.get_script()
		for p in enemy_template.get_property_list():
			if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and p["usage"] & PROPERTY_USAGE_EDITOR:
				_template_props[p["name"]] = enemy_template.get(p["name"])
		enemy_template.queue_free()
	if spawn_on_start:
		await get_tree().create_timer(0.3).timeout  # let the level's collisions finish loading
		spawn_horde()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_T:
		restart_horde()


func restart_horde() -> void:
	if _busy:
		return
	_busy = true
	clear_horde()
	await get_tree().create_timer(0.1).timeout
	await spawn_horde()
	_busy = false


func clear_horde() -> void:
	_generation += 1  # also stops a spawn that is still in progress
	for enemy in get_tree().get_nodes_in_group("enemies"):
		enemy.queue_free()


func spawn_horde() -> void:
	if enemy_scene == null and _template_script == null:
		push_warning("EnemySpawner needs an Enemy Scene or an Enemy Template (see the Inspector).")
		return
	_generation += 1
	var generation := _generation
	var delay := spawn_over_seconds / maxf(float(count), 1.0)
	for i in count:
		_spawn_one()
		if delay > 0.0:
			await get_tree().create_timer(delay).timeout
			if generation != _generation:
				return


func _make_enemy() -> Node3D:
	if enemy_scene:
		return enemy_scene.instantiate() as Node3D
	var enemy := CharacterBody3D.new()  # enemy.gd extends CharacterBody3D
	enemy.set_script(_template_script)
	for prop_name in _template_props:
		enemy.set(prop_name, _template_props[prop_name])
	return enemy


func _spawn_one() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	for attempt in 20:
		var angle := randf() * TAU
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * sqrt(randf()) * radius
		var pos := global_position + offset
		if player and Vector2(pos.x - player.global_position.x, pos.z - player.global_position.z).length() < min_player_distance:
			continue

		# Find the floor under that spot, so nothing starts inside a platform.
		var query := PhysicsRayQueryParameters3D.create(
			pos + Vector3.UP * RAY_HEIGHT, pos + Vector3.DOWN * 100.0)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7:
			continue
		var collider := hit["collider"] as Node
		if collider and (collider.is_in_group("pole") or collider.is_in_group("enemies")):
			continue  # not on a pole top, not on another enemy's head

		var enemy := _make_enemy()
		var factor := randf_range(1.0 - speed_variation, 1.0 + speed_variation)
		enemy.set("move_speed", float(enemy.get("move_speed")) * factor)
		get_tree().current_scene.add_child(enemy)
		enemy.global_position = (hit["position"] as Vector3) + Vector3.UP * 0.1
		return
