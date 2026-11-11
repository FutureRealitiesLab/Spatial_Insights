# TEMPLATE CORE – nicht verändern
extends XROrigin3D

## xr_player.gd – Lokaler XR-Spieler (Focus Vision / Quest / OpenXR).
##
## Beide Controller gleichwertig:
##   Primary   (A / X)  → Standalone-Modus aktivieren
##   Secondary (B / Y)  → nächste Szene
##   Thumbstick Y       → Vor/Zurück-Bewegung (beide Controller, max-Betrag gewinnt)
##   Thumbstick X       → Links/Rechts-Rotation (beide Controller, max-Betrag gewinnt)


const SitusSettings := preload("res://addons/situs_core/core/situs_settings.gd")
const JumpBoost := preload("res://addons/situs_core/player/jump_boost.gd")

## Sendeintervall in Sekunden (20 Hz)
const SEND_RATE: float = 0.05

## Bewegungsgeschwindigkeit (m/s) – im Godot-Editor einstellbar
@export var move_speed: float = 1.2

## Rotation via Thumbstick X aktivieren
@export var rotation_enabled: bool = true

## Drehgeschwindigkeit (Grad/s)
@export var rotation_speed: float = 60.0

## Boost-Sprung: Auslöser sind die Sprungtaste (Standard B, nur rechter Controller) oder Hocke
## und Hochspringen. Danach steigt der Spieler wie bei einem Wurf auf die Sprunghöhe, die
## Energie läuft nach oben hin aus, und er sinkt langsam zurück. Höhe und Zeiten: Project Settings → Situs Core → Jump. Während des Flugs sind
## weitere Sprünge gesperrt.
## Hocke: so viel muss der Kopf unter die normale Höhe gehen (Meter)
@export var jump_crouch_drop: float = 0.4
## Mindest-Steiggeschwindigkeit des Kopfes beim Hochspringen (m/s)
@export var jump_speed: float = 1.5
## Pause nach einem Sprung (Sekunden), zusätzlich zur Sperre während des Flugs
@export var jump_cooldown: float = 3.0

var _send_timer: float = 0.0
var _hand_mat: StandardMaterial3D = null     # Spielerfarbe
var _flash_mat: StandardMaterial3D = null    # weißes Aufblitzen bei Tastendruck
var _flash_t: Array = [0.0, 0.0]             # verbleibende Blitzzeit links, rechts
var _flash_on: Array = [false, false]
var _hint: Label3D = null
var _hint_time: float = 0.0
var _boost := JumpBoost.new()      # Höhenverlauf des Boost-Sprungs
var _jump_baseline: float = -1.0   # normale Kopfhöhe (langsam nachgeführt)
var _jump_prev_h: float = 0.0
var _jump_vy: float = 0.0
var _jump_crouched: bool = false
var _jump_crouch_t: float = 0.0
var _jump_crouch_min: float = 0.0
var _jump_cool: float = 0.0
var _hand_color: Color = Color(0, 0, 0, 0)
var _stick_l: Vector2 = Vector2.ZERO
var _stick_r: Vector2 = Vector2.ZERO


func _ready() -> void:
	$XRCamera3D.make_current()
	if has_node("LeftHand"):
		$LeftHand.button_pressed.connect(_on_button)
		$LeftHand.button_pressed.connect(_on_hand_button)
		$LeftHand.button_pressed.connect(_flash_hand.bind(0))
		$LeftHand.button_pressed.connect(_show_button_info.bind(0))
		$LeftHand.input_vector2_changed.connect(_on_left_stick)
	if has_node("RightHand"):
		$RightHand.button_pressed.connect(_on_button)
		$RightHand.button_pressed.connect(_flash_hand.bind(1))
		$RightHand.button_pressed.connect(_show_button_info.bind(1))
		$RightHand.button_pressed.connect(_on_hand_button)
		$RightHand.input_vector2_changed.connect(_on_right_stick)


func _on_button(button_name: String) -> void:
	# Standalone nur aktivieren, wenn KEINE Server-Verbindung besteht
	if not NetworkManager.client_connected_flag and not SceneManager.standalone_mode:
		SceneManager.activate_standalone()
	# Secondary Button (B/Y) → nächste Szene (nur im Standalone-Modus; im Multiplayer steuert der Server)
	if button_name == "by_button" and SceneManager.standalone_mode:
		SceneManager.advance_scene()


## Sprungtaste (Setting Situs Core -> Jump -> Button) auf beiden Controllern löst den Sprung aus.
## ax_touch (X links, A rechts) würfelt die eigene Spielerfarbe neu, alle sehen sie.
func _on_hand_button(button_name: String) -> void:
	if button_name == SitusSettings.get_jump_button():
		start_boost()
	if button_name == "ax_touch":
		NetworkManager.request_random_color()


## Zeigt Hand, Aktionsname der Taste und das aktive Controller-Profil (OpenXR) im Blickfeld.
## Damit sieht man, ob die Brille das Focus-3-Profil nutzt (dann kommen A/B/X/Y als
## ax_button/by_button) oder auf ein einfaches Profil zurückfällt (nur select/menu).
func _show_button_info(button_name: String, hand_index: int) -> void:
	if not SitusSettings.get_show_button_names():
		return
	var ctrl := get_node_or_null("LeftHand" if hand_index == 0 else "RightHand") as XRController3D
	var profile := "?"
	if ctrl != null:
		var tracker := XRServer.get_tracker(ctrl.tracker) as XRPositionalTracker
		if tracker != null and tracker.profile != "":
			profile = tracker.profile.get_file()   # z. B. vive_focus3_controller
	_show_hint("%s: %s\nProfile: %s" % ["left" if hand_index == 0 else "right", button_name, profile])


## Kurzer Hinweistext im Blickfeld (zeigt den Namen der gedrückten Taste), um die
## Sprungtaste in den Project Settings (Situs Core → Jump → Button) einzustellen.
func _show_hint(text: String) -> void:
	if _hint == null:
		_hint = Label3D.new()
		_hint.font_size = 28
		_hint.pixel_size = 0.0008
		_hint.no_depth_test = true
		_hint.render_priority = 10
		_hint.modulate = Color(1.0, 0.8, 0.2)
		_hint.outline_modulate = Color(0, 0, 0)
		_hint.position = Vector3(0.0, -0.14, -0.6)
		$XRCamera3D.add_child(_hint)
	_hint.text = text
	_hint.visible = true
	_hint_time = 2.0


## Startet den Boost-Sprung. Ignoriert, wenn abgeschaltet oder der Spieler noch fliegt.
func start_boost() -> void:
	if _boost.start():
		_jump_cool = jump_cooldown


## Höhe des echten Bodens (ohne Sprung). Der Körper des Avatars bleibt hier, auch wenn
## der Kopf beim Sprung oben ist (Kollisionsschutz für die anderen im Raum).
func get_floor_y() -> float:
	return global_position.y - _boost.offset


## Hebt den XR-Ursprung an und lässt ihn wieder herabgleiten.
func _update_boost(delta: float) -> void:
	global_position.y += _boost.step(delta)


func _on_left_stick(_action: String, value: Vector2) -> void:
	_stick_l = value


func _on_right_stick(_action: String, value: Vector2) -> void:
	_stick_r = value


func _process(delta: float) -> void:
	_update_boost(delta)
	if _hint != null and _hint.visible:
		_hint_time -= delta
		if _hint_time <= 0.0:
			_hint.visible = false
	_update_hand_visuals(delta)


## Ein Controller gilt nur als aktiv, wenn er Tracking-Daten liefert und nicht auf dem
## Ursprung liegt (ausgeschaltete Controller melden sonst die Raummitte).
func _hand_tracked(ctrl: XRController3D) -> bool:
	return ctrl != null and ctrl.get_is_active() and ctrl.get_has_tracking_data() \
			and ctrl.position.length() > 0.02


## Kontrolle: Beim Drücken einer Controller-Taste blitzt der Controller-Quader kurz weiß auf.
func _flash_hand(_button_name: String, hand_index: int) -> void:
	_flash_t[hand_index] = 0.15


## Zeigt die eigenen Controller nur, wenn sie aktiv sind, in der eigenen Spielerfarbe
## (weiß beim Tastendruck).
func _update_hand_visuals(delta: float) -> void:
	if _flash_mat == null:
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.albedo_color = Color.WHITE
		_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var color := Color.WHITE
	if GameState.my_id != 0 and GameState.player_colors.has(GameState.my_id):
		color = GameState.player_colors[GameState.my_id]
	if _hand_mat == null or color != _hand_color:
		_hand_color = color
		_hand_mat = StandardMaterial3D.new()
		_hand_mat.albedo_color = color
		_hand_mat.roughness = 0.5
		_flash_on = [true, true]  # Material neu setzen (siehe unten)
	for i in 2:
		var ctrl := get_node_or_null("LeftHand" if i == 0 else "RightHand") as XRController3D
		if ctrl == null:
			continue
		ctrl.visible = _hand_tracked(ctrl)
		_flash_t[i] = maxf(0.0, _flash_t[i] - delta)
		var flashing: bool = _flash_t[i] > 0.0
		if flashing != _flash_on[i]:
			_flash_on[i] = flashing
			var mesh := ctrl.get_node_or_null("ControllerMesh") as MeshInstance3D
			if mesh != null:
				mesh.set_surface_override_material(0, _flash_mat if flashing else _hand_mat)


func _physics_process(delta: float) -> void:
	_send_timer += delta
	if _send_timer >= SEND_RATE:
		_send_timer = 0.0
		_broadcast_position()
	_do_locomotion(delta)
	_detect_jump(delta)


## Hocke, dann Hochspringen erkennen (Kopfhöhe im Tracking-Raum, nur Auswertung der Höhe).
## Spätere Ansätze für den Fall, dass das nicht zuverlässig auslöst: docs/JUMP_FALLBACKS.md
func _detect_jump(delta: float) -> void:
	if delta <= 0.0 or not SitusSettings.get_jump_enabled():
		return
	var cam := $XRCamera3D as XRCamera3D
	# Während des Flugs hebt sich der Ursprung mit: nur die Kopfhöhe relativ zum Ursprung zählt.
	var h: float = cam.position.y
	_jump_vy = lerpf(_jump_vy, (h - _jump_prev_h) / delta, 0.5)
	_jump_prev_h = h
	_jump_cool = maxf(0.0, _jump_cool - delta)
	if _jump_baseline < 0.0:
		if h > 0.8:
			_jump_baseline = h
		return
	if not _jump_crouched:
		if h < _jump_baseline - jump_crouch_drop:
			_jump_crouched = true
			_jump_crouch_t = 0.0
			_jump_crouch_min = h
		elif absf(_jump_vy) < 0.3:
			_jump_baseline = lerpf(_jump_baseline, h, 1.0 - exp(-delta / 3.0))
		return
	_jump_crouch_t += delta
	_jump_crouch_min = minf(_jump_crouch_min, h)
	if _jump_vy > jump_speed and h > _jump_crouch_min + 0.15 and _jump_cool <= 0.0:
		_jump_crouched = false
		start_boost()
	elif h > _jump_baseline - 0.15 or _jump_crouch_t > 2.5:
		_jump_crouched = false  # wieder aufgestanden oder zu lange unten


func _do_locomotion(delta: float) -> void:
	# Im Multiplayer (mit Server verbunden): KEINE Thumbstick-Bewegung erlaubt!
	# Verhindert Virtual/Physical Offset in Co-located VR – Besucher bewegen sich rein physisch.
	# Nur im Offline- / Standalone-Modus für Einzelnutzer aktiv.
	if not SceneManager.standalone_mode or NetworkManager.client_connected_flag:
		return

	# Vor/Zurück: Controller mit größtem Y-Betrag gewinnt
	var fwd: float = _stick_l.y if abs(_stick_l.y) >= abs(_stick_r.y) else _stick_r.y
	# Rotation: Controller mit größtem X-Betrag gewinnt
	var turn: float = _stick_l.x if abs(_stick_l.x) >= abs(_stick_r.x) else _stick_r.x

	if abs(fwd) > 0.2:
		var cam := $XRCamera3D as XRCamera3D
		var forward := -cam.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() > 0.0001:
			forward = forward.normalized()
		global_position += forward * fwd * move_speed * delta
		_clamp_to_walk_area()

	if rotation_enabled and abs(turn) > 0.2:
		rotate_y(deg_to_rad(-turn * rotation_speed * delta))


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
	var cam: XRCamera3D = $XRCamera3D
	if not is_instance_valid(cam):
		return
	var body_floor := Vector3(cam.global_position.x, get_floor_y(), cam.global_position.z)
	var hands := PackedVector3Array()
	var mask := 0
	for i in 2:
		var ctrl := get_node_or_null("LeftHand" if i == 0 else "RightHand") as XRController3D
		var tracked: bool = _hand_tracked(ctrl)
		if tracked:
			mask |= 1 << i
			hands.append(ctrl.global_position)
			hands.append(ctrl.global_rotation)
		else:
			hands.append(Vector3.ZERO)
			hands.append(Vector3.ZERO)
	NetworkManager.send_player_state(body_floor, cam.global_position, cam.global_rotation, hands, mask)
