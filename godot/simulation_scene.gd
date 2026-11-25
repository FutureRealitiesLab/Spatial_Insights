extends "res://addons/situs_core/templates/scene_hooks.gd"

## Simulationsszene für Situs Core: zeigt die MATLAB-Daten im Raum.
## Raumgröße kommt aus den Project Settings (situs_core/room), die Drehung des
## Raums gegenüber den Brillen übernimmt der XR-Ursprung (nicht dieser Inhalt).

const SitusSettings := preload("res://addons/situs_core/core/situs_settings.gd")
const Colormaps := preload("res://colormaps.gd")
const ColorPanel := preload("res://color_panel.gd")


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
var _color_panel: PanelContainer
var _direct_label: Label3D
var _last_frame_ms: int = -DIRECT_HINT_AFTER_MS

## Im Direktmodus erscheint der Hinweis mit der IP, wenn so lange kein Frame kam.
const DIRECT_HINT_AFTER_MS := 3000


func _ready() -> void:
	super()
	SimulationRelay.attach()
	SimulationRelay.frame_received.connect(
			func(_m: String, _i: Dictionary, _p: PackedByteArray) -> void: _last_frame_ms = Time.get_ticks_msec())
	SimulationRelay.replay()
	_build_direct_hint()
	_build_freeze_ui()
	SimulationRelay.frozen_changed.connect(_on_frozen_changed)
	_on_frozen_changed(SimulationRelay.frozen)
	SimulationRelay.view_setting_changed.connect(_on_view_setting_changed)
	for key: String in SimulationRelay.view_settings:
		_on_view_setting_changed(key, SimulationRelay.view_settings[key])


## Direktmodus (MATLAB sendet an dieses Geraet): schwebender Hinweis mit eigener IP und Port,
## solange kein Datenstrom ankommt.
func _build_direct_hint() -> void:
	_direct_label = Label3D.new()
	_direct_label.font_size = 64
	_direct_label.pixel_size = 0.0015
	_direct_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_direct_label.outline_modulate = Color(0, 0, 0)
	_direct_label.position = Vector3(0.0, 1.5, 0.0)
	_direct_label.visible = false
	add_child(_direct_label)


func _process(_delta: float) -> void:
	var waiting: bool = SimulationRelay.role == SimulationRelay.Role.DIRECT \
			and Time.get_ticks_msec() - _last_frame_ms > DIRECT_HINT_AFTER_MS
	if waiting and not _direct_label.visible:
		var ips: PackedStringArray = []
		for addr: String in IP.get_local_addresses():
			if "." in addr and not addr.begins_with("127.") and not addr.begins_with("169.254."):
				ips.append(addr)
		_direct_label.text = "Direct mode: waiting for data\nIn MATLAB: udpOpen(address=\"%s\", port=%d)" % [
				" / ".join(ips) if not ips.is_empty() else "no network", SimulationRelay.port]
	_direct_label.visible = waiting


## Taste F (Server und Direkt-Instanz) haelt die Simulation fuer alle an, Taste B blendet die
## Rahmen der Spatial Boxes fuer alle ein oder aus, Taste C schaltet die Farbskala fuer alle weiter,
## M zeigt das Farbmenue.
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
			KEY_M:
				_toggle_color_panel()


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
		_build_color_panel()
		var colors_button := _shortcut_button("Colors (M)")
		colors_button.pressed.connect(_toggle_color_panel)
		box.add_child(_freeze_button)
		box.add_child(_boxes_button)
		box.add_child(_colormap_button)
		box.add_child(colors_button)
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
	match key:
		"show_boxes":
			$Plot/View.set_show_boxes(bool(value))
			if _boxes_button != null:
				_boxes_button.set_pressed_no_signal(bool(value))
		"gradient":
			$Plot/View.set_gradient(value)
		"palette":
			$Plot/View.set_palette(value)
			if _color_panel != null:
				_color_panel.show_palette(value)
		"range":
			$Plot/View.set_value_range(value)
			if _color_panel != null:
				_color_panel.show_range(value)
		"preset":
			$Plot/View.preset_name = str(value)
			if _colormap_button != null:
				_colormap_button.text = "Colormap (C): %s" % value
			# Bei "custom" kommt die Aenderung aus dem Menue selbst, nicht neu aufbauen.
			if _color_panel != null and value != "custom":
				_color_panel.show_gradient(Colormaps.preset(value), value)


## Vorlage fuer alle waehlen (nur Server und Direkt-Instanz wirken).
func _choose_preset(preset: String) -> void:
	SimulationRelay.set_view_setting("preset", preset)
	SimulationRelay.set_view_setting("gradient", Colormaps.preset(preset))


## Taste C und Button: naechste Vorlage.
func _next_colormap() -> void:
	var index: int = Colormaps.NAMES.find(SimulationRelay.view_settings.get("preset", "rainbow"))
	_choose_preset(Colormaps.NAMES[(index + 1) % Colormaps.NAMES.size()])


## Farbmenue (Server): links unten, mit M oder Button ein- und ausblenden.
func _build_color_panel() -> void:
	_color_panel = ColorPanel.new()
	_color_panel.view = $Plot/View
	_color_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_color_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_color_panel.offset_left = 12.0
	_color_panel.offset_bottom = -12.0
	_color_panel.visible = false
	$DebugLayer.add_child(_color_panel)
	_color_panel.preset_chosen.connect(_choose_preset)
	_color_panel.gradient_edited.connect(func(gradient: Dictionary) -> void:
		SimulationRelay.set_view_setting("preset", "custom")
		SimulationRelay.set_view_setting("gradient", gradient))
	_color_panel.range_edited.connect(func(range_01: Vector2) -> void:
		SimulationRelay.set_view_setting("range", range_01))
	_color_panel.palette_edited.connect(func(colors: PackedColorArray) -> void:
		SimulationRelay.set_view_setting("palette", colors))
	_color_panel.show_palette(SimulationRelay.view_settings.get("palette", Colormaps.default_palette()))
	var preset: String = SimulationRelay.view_settings.get("preset", "rainbow")
	_color_panel.show_gradient(SimulationRelay.view_settings.get("gradient", Colormaps.preset(preset)), preset)
	_color_panel.show_range(SimulationRelay.view_settings.get("range", Vector2(0.0, 1.0)))


func _toggle_color_panel() -> void:
	if _color_panel != null:
		_color_panel.visible = not _color_panel.visible
		# Das Menue braucht den Platz der Statistik (F3 blendet sie sonst ein und aus).
		$DebugLayer/Stats.visible = not _color_panel.visible
