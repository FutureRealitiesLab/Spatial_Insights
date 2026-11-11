extends "res://addons/situs_core/templates/scene_hooks.gd"

## Simulationsszene für Situs Core: zeigt die MATLAB-Daten im Raum.
## Raumgröße kommt aus den Project Settings (situs_core/room), die Drehung des
## Raums gegenüber den Brillen übernimmt der XR-Ursprung (nicht dieser Inhalt).

const SitusSettings := preload("res://addons/situs_core/core/situs_settings.gd")


func _enter_tree() -> void:
	# Läuft vor _ready() der Kinder, damit scene_view.gd die Größe schon kennt.
	var room: Vector2 = SitusSettings.get_room_size()
	var view := $Plot/View
	view.box_size = Vector3(room.y, room.x, view.box_size.z)
	view.room_rotation_deg = 90.0


var _freeze_labels: Array[Label3D] = []
var _freeze_button: Button


func _ready() -> void:
	super()
	SimulationRelay.attach()
	SimulationRelay.replay()
	_build_freeze_ui()
	SimulationRelay.frozen_changed.connect(_on_frozen_changed)
	_on_frozen_changed(SimulationRelay.frozen)


## Taste F (Server und Direkt-Instanz) hält die Simulation für alle an. Die Leertaste ist
## für den Boost-Sprung der PC-Spieler reserviert.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		SimulationRelay.toggle_frozen()


## "FREEZE" mittig auf den vier Seitenflaechen des Raums (ca. 1 m breit, ohne Drehung, von
## innen lesbar) und ein Button rechts oben fuer den Server.
func _build_freeze_ui() -> void:
	var room: Vector2 = SitusSettings.get_room_size()   # x = Breite, y = Laenge (Godot-z)
	var height: float = ($Plot/View.box_size as Vector3).z / 2.0
	var inset := 0.02
	# [Position, Drehung um y]: die Schrift zeigt nach innen.
	var walls := [
		[Vector3(room.x / 2.0 - inset, height, 0.0), -90.0],
		[Vector3(-room.x / 2.0 + inset, height, 0.0), 90.0],
		[Vector3(0.0, height, room.y / 2.0 - inset), 180.0],
		[Vector3(0.0, height, -room.y / 2.0 + inset), 0.0],
	]
	for wall: Array in walls:
		var label := Label3D.new()
		label.text = "FREEZE"
		label.font_size = 128
		label.pixel_size = 0.0025
		label.modulate = Color(1.0, 0.6, 0.1)
		label.outline_modulate = Color(0, 0, 0)
		label.position = wall[0]
		label.rotation_degrees.y = wall[1]
		label.visible = false
		add_child(label)
		_freeze_labels.append(label)

	if SimulationRelay.role == SimulationRelay.Role.SERVER or SimulationRelay.role == SimulationRelay.Role.DIRECT:
		_freeze_button = Button.new()
		_freeze_button.toggle_mode = true
		_freeze_button.text = "Freeze (F)"
		_freeze_button.focus_mode = Control.FOCUS_NONE
		# Rechts oben am Fensterrand, waechst mit der Fenstergroesse (Stretch-Modus).
		_freeze_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_freeze_button.offset_left = -132.0
		_freeze_button.offset_right = -12.0
		_freeze_button.offset_top = 12.0
		_freeze_button.offset_bottom = 48.0
		_freeze_button.toggled.connect(func(on: bool) -> void: SimulationRelay.set_frozen(on))
		$DebugLayer.add_child(_freeze_button)

func _on_frozen_changed(frozen: bool) -> void:
	for label: Label3D in _freeze_labels:
		label.visible = frozen
	if _freeze_button != null:
		_freeze_button.set_pressed_no_signal(frozen)
