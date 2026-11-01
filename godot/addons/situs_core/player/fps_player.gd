# TEMPLATE CORE – nicht verändern
extends CharacterBody3D

## fps_player.gd – Desktop-Fallback für Tests ohne Headset.
##
## Steuerung: WASD bewegen, Maus für Umsehen, Leertaste = Boost-Sprung (wie bei der Brille:
## nur der Kopf hebt ab, der Körper bleibt am Boden), ESC Maus freigeben.
## Gleiche Netzwerk-Logik wie xr_player.gd – beide senden via NetworkManager.send_player_state().


@export var SPEED: float        = 1.2
@export var MOUSE_SENSITIVITY: float = 0.003
const SEND_RATE: float    = 0.05

@onready var head: Node3D   = $Head
@onready var camera: Camera3D = $Head/Camera3D

const JumpBoost := preload("res://addons/situs_core/player/jump_boost.gd")

var _send_timer: float = 0.0
var _boost := JumpBoost.new()   # Höhenverlauf des Boost-Sprungs


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	camera.current = true
	# Layer 2 (Wert 2): "players" | Mask 1: nur mit Welt kollidieren, NICHT mit Avataren
	collision_layer = 2
	collision_mask  = 1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		head.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		head.rotation.x = clamp(head.rotation.x, -PI * 0.45, PI * 0.45)

	if event.is_action_pressed("ui_cancel"):
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if event is InputEventMouseButton \
			and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Q / E → Szene wechseln (aktiviert Standalone-Modus falls nötig)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_boost.start()
		if event.keycode == KEY_Q or event.keycode == KEY_E:
			if not SceneManager.standalone_mode:
				SceneManager.activate_standalone()
			if event.keycode == KEY_E:
				SceneManager.advance_scene()
			else:
				SceneManager.retreat_scene()


## Höhe des echten Bodens. Der Körper des Avatars bleibt hier, auch wenn der Kopf beim
## Sprung oben ist.
func get_floor_y() -> float:
	return global_position.y


func _process(delta: float) -> void:
	# Boost-Sprung: nur der Kopf (Kamera) hebt ab
	head.position.y += _boost.step(delta)


func _physics_process(delta: float) -> void:
	# Gravitation
	if not is_on_floor():
		velocity += get_gravity() * delta

	# WASD-Bewegung (ui_left/right/up/down = A/D/W/S per Default)
	var input_dir: Vector2 = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	input_dir += Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	)
	input_dir = input_dir.clamp(Vector2(-1, -1), Vector2(1, 1))
	var direction: Vector3 = (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()
	_clamp_to_walk_area()

	# Position senden
	_send_timer += delta
	if _send_timer >= SEND_RATE:
		_send_timer = 0.0
		_broadcast_position()


func _clamp_to_walk_area() -> void:
	var walk_area := get_tree().root.find_child("XRWalkArea", true, false) as MeshInstance3D
	if not walk_area or not walk_area.mesh is PlaneMesh:
		return
	var plane := walk_area.mesh as PlaneMesh
	var half_x := plane.size.x * 0.5 * walk_area.scale.x
	var half_z := plane.size.y * 0.5 * walk_area.scale.z
	var center := walk_area.global_position
	global_position.x = clamp(global_position.x, center.x - half_x, center.x + half_x)
	global_position.z = clamp(global_position.z, center.z - half_z, center.z + half_z)


func _broadcast_position() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	NetworkManager.send_player_state(
		global_position,
		head.global_position,
		head.global_rotation
	)
