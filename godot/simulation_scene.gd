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
	view.handle_keys = false   # Farbskala kommt vom Server (SimulationRelay.view_settings)


var _freeze_labels: Array[Label3D] = []
var _freeze_button: Button
var _boxes_button: Button
var _colormap_button: Button


func _ready() -> void:
	super()
	SimulationRelay.attach()
	SimulationRelay.replay()
	_build_freeze_ui()
	SimulationRelay.frozen_changed.connect(_on_frozen_changed)
	_on_frozen_changed(SimulationRelay.frozen)
	SimulationRelay.view_setting_changed.connect(_on_view_setting_changed)
	for key: String in SimulationRelay.view_settings:
		_on_view_setting_changed(key, SimulationRelay.view_settings[key])


## Taste F (Server und Direkt-Instanz) haelt die Simulation fuer alle an, Taste B blendet die
## Rahmen der Spatial Boxes fuer alle ein oder aus, Taste C schaltet die Farbskala fuer alle weiter.
## Die Leertaste ist fuer den Boost-Sprung
## der PC-Spieler reserviert.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F:
				SimulationRelay.toggle_frozen()
			KEY_B:
				SimulationRelay.toggle_view_setting("show_boxes")
			KEY_C:
				_next_colormap()



## "FREEZE" mittig auf den vier Seitenflaechen des Raums (ca. 1 m breit, ohne Drehung, von
## innen lesbar) und Buttons unten rechts fuer den Server (oben rechts stehen die Client-Infos).
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
		# Shortcuts des Servers unten rechts; waechst mit der Fenstergroesse (Stretch-Modus).
		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		box.grow_vertical = Control.GROW_DIRECTION_BEGIN
		box.offset_right = -12.0
		box.offset_bottom = -12.0
		_freeze_button = _shortcut_button("Freeze (F)", func(on: bool) -> void: SimulationRelay.set_frozen(on))
		_boxes_button = _shortcut_button("Boxes (B)", func(on: bool) -> void: SimulationRelay.set_view_setting("show_boxes", on))
		_colormap_button = _shortcut_button("")
		_colormap_button.pressed.connect(_next_colormap)
		box.add_child(_freeze_button)
		box.add_child(_boxes_button)
		box.add_child(_colormap_button)
		$DebugLayer.add_child(box)


func _shortcut_button(label: String, on_toggled: Callable = Callable()) -> Button:
	var button := Button.new()
	button.toggle_mode = on_toggled.is_valid()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(170.0, 36.0)
	if on_toggled.is_valid():
		button.toggled.connect(on_toggled)
	return button


func _on_frozen_changed(frozen: bool) -> void:
	for label: Label3D in _freeze_labels:
		label.visible = frozen
	if _freeze_button != null:
		_freeze_button.set_pressed_no_signal(frozen)


## Darstellungs-Einstellungen kommen vom Server (SimulationRelay.view_settings).
func _on_view_setting_changed(key: String, value: Variant) -> void:
	if key == "show_boxes":
		$Plot/View.set_show_boxes(bool(value))
		if _boxes_button != null:
			_boxes_button.set_pressed_no_signal(bool(value))
	elif key == "colormap":
		$Plot/View.set_colormap(int(value))
		if _colormap_button != null:
			_colormap_button.text = "Colormap (C): %s" % $Plot/View.colormap_name()


## Taste C und Button: naechste Farbskala fuer alle (nur Server und Direkt-Instanz wirken).
func _next_colormap() -> void:
	var count: int = ($Plot/View.COLORMAP_NAMES as Array).size()
	SimulationRelay.set_view_setting("colormap", (int(SimulationRelay.view_settings.get("colormap", 0)) + 1) % count)
