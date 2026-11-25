extends PanelContainer
## Farbmenue am Server: Verlauf mit 2 bis 5 Farbpunkten (Farbe, Deckkraft, Position),
## Vorlagen und Wertebereich. Die Aenderungen gehen als Signale an die Szene, die sie ueber
## SimulationRelay an alle Clients verteilt.

signal preset_chosen(name: String)
signal gradient_edited(gradient: Dictionary)
signal range_edited(range_01: Vector2)

const Colormaps := preload("res://colormaps.gd")

## Die Ansicht (scene_view.gd): liefert Farbtabelle und Datenbereiche.
var view: Node

var _presets: OptionButton
var _stops: VBoxContainer
var _add: Button
var _min: HSlider
var _max: HSlider
var _info: Label


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.96)
	style.set_content_margin_all(10.0)
	style.set_corner_radius_all(6)
	add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	add_child(box)

	_presets = OptionButton.new()
	_presets.focus_mode = Control.FOCUS_NONE
	for name: String in Colormaps.NAMES:
		_presets.add_item(name)
	_presets.add_item("custom")
	_presets.set_item_disabled(Colormaps.NAMES.size(), true)
	_presets.item_selected.connect(func(i: int) -> void: preset_chosen.emit(_presets.get_item_text(i)))
	box.add_child(_presets)

	var preview := TextureRect.new()
	preview.texture = view.lut   # dieselbe Textur wie die Materialien, aktualisiert sich mit
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.custom_minimum_size = Vector2(300.0, 18.0)
	box.add_child(preview)

	_stops = VBoxContainer.new()
	box.add_child(_stops)
	_add = _button("Add color", _add_stop)
	box.add_child(_add)

	box.add_child(HSeparator.new())
	_min = _range_row(box, "Min", 0.0)
	_max = _range_row(box, "Max", 1.0)
	box.add_child(_button("Fit range to current data", _fit_range))
	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 12)
	box.add_child(_info)

	var timer := Timer.new()
	timer.wait_time = 1.0
	timer.autostart = true
	timer.timeout.connect(_update_info)
	add_child(timer)


## Zeigt einen Verlauf an (Vorlage gewaehlt oder beim Oeffnen), ohne Signale auszuloesen.
func show_gradient(gradient: Dictionary, preset: String) -> void:
	var index: int = Colormaps.NAMES.find(preset)
	_presets.select(index if index >= 0 else Colormaps.NAMES.size())
	for row in _stops.get_children():
		_stops.remove_child(row)
		row.queue_free()
	for i in (gradient.offsets as PackedFloat32Array).size():
		_add_row(gradient.colors[i], gradient.offsets[i])
	_update_buttons()


func show_range(range_01: Vector2) -> void:
	_min.set_value_no_signal(range_01.x)
	_max.set_value_no_signal(range_01.y)
	_update_info()


func _button(label: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


func _slider(value: float) -> HSlider:
	var slider := HSlider.new()
	slider.max_value = 1.0
	slider.step = 0.005
	slider.value = value
	slider.focus_mode = Control.FOCUS_NONE
	slider.custom_minimum_size = Vector2(200.0, 0.0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return slider


func _add_row(color: Color, offset: float) -> void:
	var row := HBoxContainer.new()
	var picker := ColorPickerButton.new()
	picker.color = color   # der Alphawert ist die Deckkraft
	picker.edit_alpha = true
	picker.focus_mode = Control.FOCUS_NONE
	picker.custom_minimum_size = Vector2(56.0, 28.0)
	picker.color_changed.connect(func(_c: Color) -> void: _emit_gradient())
	row.add_child(picker)
	var slider := _slider(offset)
	slider.value_changed.connect(func(_v: float) -> void: _emit_gradient())
	row.add_child(slider)
	row.add_child(_button("x", func() -> void:
		_stops.remove_child(row)
		row.queue_free()
		_update_buttons()
		_emit_gradient()))
	_stops.add_child(row)


func _gradient() -> Dictionary:
	var stops := []
	for row in _stops.get_children():
		stops.append([(row.get_child(1) as HSlider).value, (row.get_child(0) as ColorPickerButton).color])
	stops.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for stop: Array in stops:
		offsets.append(stop[0])
		colors.append(stop[1])
	return {"offsets": offsets, "colors": colors}


func _emit_gradient() -> void:
	_presets.select(Colormaps.NAMES.size())   # "custom"
	gradient_edited.emit(_gradient())


## Neuer Farbpunkt in der groessten Luecke, mit der dort vorhandenen Farbe.
func _add_stop() -> void:
	var g := _gradient()
	var gradient := Gradient.new()
	gradient.offsets = g.offsets
	gradient.colors = g.colors
	var at := 0.5
	var gap := 0.0
	for i in range(1, (g.offsets as PackedFloat32Array).size()):
		var width: float = g.offsets[i] - g.offsets[i - 1]
		if width > gap:
			gap = width
			at = g.offsets[i - 1] + width / 2.0
	_add_row(gradient.sample(at), at)
	_update_buttons()
	_emit_gradient()


func _update_buttons() -> void:
	var count := _stops.get_child_count()
	_add.disabled = count >= Colormaps.MAX_STOPS
	for row in _stops.get_children():
		(row.get_child(2) as Button).disabled = count <= 2


func _range_row(box: VBoxContainer, label: String, value: float) -> HSlider:
	var row := HBoxContainer.new()
	var name_label := Label.new()
	name_label.text = label
	name_label.custom_minimum_size = Vector2(56.0, 0.0)
	row.add_child(name_label)
	var slider := _slider(value)
	slider.value_changed.connect(func(_v: float) -> void: _emit_range())
	row.add_child(slider)
	box.add_child(row)
	return slider


func _emit_range() -> void:
	var low := minf(_min.value, _max.value - 0.005)
	range_edited.emit(Vector2(low, maxf(_max.value, low + 0.005)))
	_update_info()


## Bereich auf die gerade uebertragenen Extremwerte aller Skalarfelder setzen.
func _fit_range() -> void:
	var low := 1.0
	var high := 0.0
	for r: Dictionary in view.scalar_ranges():
		var span: float = r.vmax - r.vmin
		if span > 0.0:
			low = minf(low, (r.low - r.vmin) / span)
			high = maxf(high, (r.high - r.vmin) / span)
	if high > low:
		_min.set_value_no_signal(low)
		_max.set_value_no_signal(high)
		_emit_range()


## Datenwerte zu den Reglern, je Skalarfeld (die Werte ausserhalb von vspan schneidet der
## Sender ab, sie sind hier nicht sichtbar).
func _update_info() -> void:
	if not is_visible_in_tree():
		return
	var lines: PackedStringArray = []
	for r: Dictionary in view.scalar_ranges():
		var span: float = r.vmax - r.vmin
		lines.append("%s  data %.2f .. %.2f  (vspan %.2f .. %.2f)\n      colors span %.2f .. %.2f" % [
				r.magic, r.low, r.high, r.vmin, r.vmax,
				r.vmin + _min.value * span, r.vmin + _max.value * span])
	_info.text = "\n".join(lines) if not lines.is_empty() else "No scalar field (S) received yet"
