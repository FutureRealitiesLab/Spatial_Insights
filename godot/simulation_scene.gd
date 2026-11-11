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


var _freeze_label: Label3D
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


## Schwebendes Schild über dem Raum (für Brillen und Server) und ein Button für den Server.
func _build_freeze_ui() -> void:
	_freeze_label = Label3D.new()
	_freeze_label.text = "EINGEFROREN"
	_freeze_label.font_size = 96
	_freeze_label.pixel_size = 0.004
	_freeze_label.modulate = Color(1.0, 0.6, 0.1)
	_freeze_label.outline_modulate = Color(0, 0, 0)
	_freeze_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_freeze_label.position = Vector3(0.0, 2.4, 0.0)
	_freeze_label.visible = false
	add_child(_freeze_label)

	if SimulationRelay.role == SimulationRelay.Role.SERVER or SimulationRelay.role == SimulationRelay.Role.DIRECT:
		_freeze_button = Button.new()
		_freeze_button.toggle_mode = true
		_freeze_button.text = "Freeze (F)"
		_freeze_button.focus_mode = Control.FOCUS_NONE
		_freeze_button.position = Vector2(12.0, 280.0)
		_freeze_button.toggled.connect(func(on: bool) -> void: SimulationRelay.set_frozen(on))
		$DebugLayer.add_child(_freeze_button)


func _on_frozen_changed(frozen: bool) -> void:
	_freeze_label.visible = frozen
	if _freeze_button != null:
		_freeze_button.set_pressed_no_signal(frozen)
