extends Node3D
## Darstellung der empfangenen Frames (Port von udp/udpDrawnow.m, Protokoll v2).
##
## magic(1) Datentyp, magic(2) Dimension, magic(3) Darstellung, magic(4) Extra.
## Das vollstaendige Magic ist der Ebenen-Schluessel; jede Ebene wird nur bei
## geaenderter Form neu gebaut.
##
## Spatial Box: Jedes Frame traegt info.box = [xmin xmax ymin ymax zmin zmax] in
## Metern. Die erste Box eines Magics legt Lage und Groesse der Ebene fest, 2D-Daten
## liegen bei zmin. `box_size` ist das Betrachtervolumen (MATLAB: [8 4 2]).
##
## S/C 2s<m>  Skalarfeld/Automat, m: 0 Ebene, 1 Hoehe, 2 Kugel, 3 Torus
## S/C 3s<n>  Schnitte, n: 0 drei Mittelschnitte, 1..9 n xy-Schnitte
## S/C 3v<a>  Volumen (Raymarching), a: 0 Standard, 1..9 Deckkraft 0.1..0.9
## V 2p/3p<k> Gitterpunkte um den Vektor verschoben (k=1 autoskaliert)
## V 2q/3q<c> Pfeile mit exakter Laenge (c: 0 Farbe nach Betrag, 1..9 feste Farbe)
## P 2p/3p<c> Partikel (c: 0 Farbe nach Geschwindigkeit, 1..9 feste Farbe)
## P 2q/3q<c> Partikelvektoren (auch Strassen), wie V q
##
## Koordinaten wie in MATLAB (x, y, z); die Node `Plot` dreht sie so, dass z in
## Godot nach oben zeigt. Texturen sind [ny nx nz] (Breite ny, Hoehe nx) und werden roh aus dem
## spaltenweisen Payload erzeugt; die Shader vertauschen x und y.

const Receiver := preload("res://udp_receiver.gd")
const BoxOutline := preload("res://box_outline.gd")

@export var receiver_path: NodePath
## Betrachtervolumen in Metern: x, y (Bodenflaeche) und z (Hoehe). Die lange Seite
## ist x (MATLAB: 8 x 4 x 2).
@export var box_size := Vector3(8.0, 4.0, 2.0)
## Drehung des ganzen Raums um die Senkrechte in Grad (Ausrichtung zum echten
## Raum). Bei 0 liegt MATLAB-y entlang -z, bei 90 liegt MATLAB-x entlang -z.
@export var room_rotation_deg: float = 90.0
## Radius der Partikelkugeln in Metern.
@export var particle_radius: float = 0.04
@export var outline_path: NodePath
@export var floor_outline_path: NodePath
## 0 rainbow, 1 hot, 2 gray, 3 viridis (Taste C wechselt).
@export var colormap: int = 0
## false: Taste C wird hier nicht ausgewertet (die Szene steuert die Farbskala).
@export var handle_keys: bool = true

const COLORMAP_NAMES := ["rainbow", "hot", "gray", "viridis"]
## MATLAB lines(9): die ersten sieben Farben, danach wiederholt.
const SPECIES_COLORS := [
	Color(0.0, 0.447, 0.741), Color(0.85, 0.325, 0.098), Color(0.929, 0.694, 0.125),
	Color(0.494, 0.184, 0.556), Color(0.466, 0.674, 0.188), Color(0.301, 0.745, 0.933),
	Color(0.635, 0.078, 0.184),
]
const VECTOR_POINT_COLOR := Color(0.12, 0.4, 0.8)
const MAX_SURFACE_SEGMENTS := 255
const PACKED_TEX_WIDTH := 2048

var layers: Dictionary = {}
## Rahmen der Spatial Boxes sichtbar (der Server gibt das vor, siehe SimulationRelay).
var show_boxes := true
var current_magic: String = ""
var _session: int = -1
var _arrow_mesh: ArrayMesh
var _shaders: Dictionary = {}


func _ready() -> void:
	_arrow_mesh = _make_arrow_mesh()
	_apply_layout()
	var receiver := get_node_or_null(receiver_path)
	if receiver:
		receiver.frame_received.connect(show_frame)
	else:
		push_error("SceneView: receiver_path zeigt auf keine Node.")


func _unhandled_key_input(event: InputEvent) -> void:
	if handle_keys and event is InputEventKey and event.pressed and event.keycode == KEY_C:
		set_colormap((colormap + 1) % COLORMAP_NAMES.size())


## Setzt die Farbskala fuer alle Ebenen (in der Simulationsszene gibt der Server sie vor).
func set_colormap(index: int) -> void:
	colormap = clampi(index, 0, COLORMAP_NAMES.size() - 1)
	for layer: Dictionary in layers.values():
		for mat: ShaderMaterial in layer.mats:
			mat.set_shader_parameter("colormap", colormap)


func colormap_name() -> String:
	return COLORMAP_NAMES[colormap]


## Dreht `Plot` so, dass MATLAB-x nach +x, MATLAB-y nach -z (in den Raum) und
## MATLAB-z nach oben zeigt, danach um `room_rotation_deg` um die Senkrechte
## (um den Boden-Mittelpunkt), und setzt die Rahmen von Box und Boden.
func _apply_layout() -> void:
	var plot := get_parent() as Node3D
	if plot:
		var yaw := Basis(Vector3.UP, deg_to_rad(room_rotation_deg))
		plot.transform = Transform3D(yaw * Basis(Vector3.RIGHT, -PI / 2.0),
				yaw * Vector3(-box_size.x / 2.0, 0.0, box_size.y / 2.0))
	# Der Rahmen des Betrachtervolumens bleibt aus: Jede Ebene zeichnet ihre eigene Box.
	var outline := get_node_or_null(outline_path) as Node3D
	if outline:
		outline.visible = false
	var floor_outline := get_node_or_null(floor_outline_path) as Node3D
	if floor_outline:
		floor_outline.scale = Vector3(box_size.x, box_size.y, 0.001)
		floor_outline.position = Vector3(box_size.x / 2.0, box_size.y / 2.0, 0.0)


func show_frame(magic: String, info: Dictionary, payload: PackedByteArray) -> void:
	# Eine neue Session verwirft alle Ebenen.
	if info.session_id != _session:
		_clear()
		_session = info.session_id
	current_magic = magic

	var box: Array = info.box
	var origin := Vector3(box[0], box[2], box[4])
	var extent := Vector3(box[1], box[3], box[5]) - origin
	if extent.x <= 0.0 or extent.y <= 0.0 or extent.z <= 0.0:
		push_warning("Ungueltige Box bei Magic %s." % magic)
		return

	var dims: Array = info.dims
	var sig: Array = [dims[1]] if magic[0] == "P" else dims.duplicate()
	if magic[0] == "C":
		sig.append(info.nostates)
	var layer: Dictionary = layers.get(magic, {})
	var rebuild: bool = layer.is_empty() or layer.sig != sig
	if rebuild:
		if not layer.is_empty():
			layer.root.queue_free()
		layer = {"magic": magic, "sig": sig, "root": Node3D.new(), "mats": [],
				"o": origin, "e": extent}
		add_child(layer.root)
		layers[magic] = layer
		# Weisser Rahmen der Spatial Box dieser Ebene (folgt dem Datensatz).
		var frame_lines := MeshInstance3D.new()
		frame_lines.set_script(BoxOutline)
		frame_lines.scale = extent
		frame_lines.position = origin + extent / 2.0
		layer.root.add_child(frame_lines)
		layer.frame = frame_lines
		frame_lines.visible = show_boxes

	var ok := false
	match magic[0]:
		"S":
			ok = _scalar(layer, rebuild, magic, info, payload)
		"V":
			ok = _vectors(layer, rebuild, magic, info, payload)
		"P":
			ok = _particles(layer, rebuild, magic, info, payload)
		"C":
			ok = _cellular(layer, rebuild, magic, info, payload)
	if not ok:
		push_warning("Keine Darstellung fuer Magic %s." % magic)
		layer.root.queue_free()
		layers.erase(magic)


func set_show_boxes(value: bool) -> void:
	show_boxes = value
	for layer: Dictionary in layers.values():
		if layer.has("frame"):
			(layer.frame as Node3D).visible = value


func _clear() -> void:
	for layer: Dictionary in layers.values():
		layer.root.queue_free()
	layers.clear()


# ---- Skalarfelder und Automaten -----------------------------------------------

func _map_mode(digit: String) -> String:
	if digit.is_valid_int() and int(digit) <= 3:
		return ["plane", "height", "sphere", "torus"][int(digit)]
	return ""


func _scalar(layer: Dictionary, rebuild: bool, magic: String, info: Dictionary, payload: PackedByteArray) -> bool:
	var dims: Array = info.dims
	match magic.substr(1, 2):
		"2s":
			var mode := _map_mode(magic[3])
			if mode == "":
				return false
			_field2d(layer, rebuild, dims[0], dims[1], payload, mode, 1.0, false)
		"3s":
			return _slices(layer, rebuild, magic, dims, payload)
		"3v":
			return _volume(layer, rebuild, magic, dims, payload)
		_:
			return false
	return true


func _cellular(layer: Dictionary, rebuild: bool, magic: String, info: Dictionary, payload: PackedByteArray) -> bool:
	var dims: Array = info.dims
	var nostates: int = info.nostates
	var scale := 255.0 / maxf(1.0, nostates - 1.0)
	match magic.substr(1, 2):
		"2s":
			var mode := _map_mode(magic[3])
			if mode == "":
				return false
			_field2d(layer, rebuild, dims[0], dims[1], payload, mode, scale, true, info.bits, nostates)
		"3s":
			return _slices(layer, rebuild, magic, dims, _states_to_bytes(payload, dims[0] * dims[1] * dims[2], nostates))
		"3v":
			return _volume(layer, rebuild, magic, dims, _states_to_bytes(payload, dims[0] * dims[1] * dims[2], nostates))
		_:
			return false
	return true


## Entpackt Automatenzustaende auf der CPU und skaliert sie auf 0..255 (ein Byte pro Zelle).
func _states_to_bytes(payload: PackedByteArray, cells: int, nostates: int) -> PackedByteArray:
	var states := Receiver.unpack_states(payload, cells, nostates)
	if nostates > 1:
		var k := 255.0 / (nostates - 1)
		for i in cells:
			states[i] = int(states[i] * k + 0.5)
	return states


## Zweidimensionales Feld: erste Ebene [ny nx] als Textur auf Flaeche/Kugel/Torus/Hoehe.
## bits > 0: bytes sind bitgepackte Zustaende, die der Shader entpackt (nicht bei "height").
func _field2d(layer: Dictionary, rebuild: bool, ny: int, nx: int, bytes: PackedByteArray,
		mode: String, value_scale: float, nearest: bool, bits: int = 0, nostates: int = 0) -> void:
	if bits > 0 and mode == "height":
		bytes = _states_to_bytes(bytes, ny * nx, nostates)
		bits = 0
	var img: Image
	if bits > 0:
		var needed := ceili(ny * nx * bits / 8.0)
		var rows := ceili(needed / float(PACKED_TEX_WIDTH))
		var padded := bytes.slice(0, needed)
		padded.resize(PACKED_TEX_WIDTH * rows)
		img = Image.create_from_data(PACKED_TEX_WIDTH, rows, false, Image.FORMAT_R8, padded)
	else:
		img = Image.create_from_data(ny, nx, false, Image.FORMAT_R8, bytes.slice(0, ny * nx))
	if not rebuild:
		(layer.tex as ImageTexture).update(img)
		return
	var tex := ImageTexture.create_from_image(img)
	layer.tex = tex

	var mat := ShaderMaterial.new()
	mat.shader = _shader("field_height" if mode == "height" else "field_image")
	mat.set_shader_parameter("tex", tex)
	mat.set_shader_parameter("colormap", colormap)
	if bits > 0:
		mat.set_shader_parameter("packed_states", true)
		mat.set_shader_parameter("bits", bits)
		mat.set_shader_parameter("grid", Vector2i(ny, nx))
	var mesh: ArrayMesh
	var o: Vector3 = layer.o
	var e: Vector3 = layer.e
	var center := o + e / 2.0
	var r := minf(e.x, minf(e.y, e.z)) / 2.0
	match mode:
		"plane":
			mat.set_shader_parameter("value_scale", value_scale)
			mat.set_shader_parameter("nearest", nearest)
			mesh = _surface(1, 1, func(u: float, v: float) -> Vector3:
				return Vector3(o.x + e.x * u, o.y + e.y * v, o.z))
		"height":
			mat.set_shader_parameter("extent", Vector2(e.x, e.y))
			mat.set_shader_parameter("height", e.z)
			mesh = _surface(clampi(nx, 1, MAX_SURFACE_SEGMENTS), clampi(ny, 1, MAX_SURFACE_SEGMENTS),
					func(u: float, v: float) -> Vector3:
				return Vector3(o.x + e.x * u, o.y + e.y * v, o.z))
		"sphere":
			mat.set_shader_parameter("value_scale", value_scale)
			mat.set_shader_parameter("nearest", nearest)
			mesh = _surface(64, 32, func(u: float, v: float) -> Vector3:
				var phi := TAU * u
				var theta := PI * v
				return center + r * Vector3(
						sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)))
		_:  # torus
			mat.set_shader_parameter("value_scale", value_scale)
			mat.set_shader_parameter("nearest", nearest)
			mesh = _surface(64, 32, func(u: float, v: float) -> Vector3:
				var phi := TAU * u
				var theta := TAU * v
				var ring := 0.7 * r + 0.3 * r * cos(theta)
				return center + Vector3(ring * cos(phi), ring * sin(phi), 0.3 * r * sin(theta)))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.extra_cull_margin = 1.0
	layer.root.add_child(mi)
	layer.mats.append(mat)


## S/C 3s<n>: n=0 drei Mittelschnitte (xy, xz, yz), n=1..9 n xy-Schnitte entlang z.
func _slices(layer: Dictionary, rebuild: bool, magic: String, dims: Array, payload: PackedByteArray) -> bool:
	var ny: int = dims[0]
	var nx: int = dims[1]
	var nz: int = dims[2]
	var count := int(magic[3]) if magic[3].is_valid_int() else 0
	if nx < 2 or ny < 2 or (count == 0 and nz < 2):
		return false
	var images := _volume_images(ny, nx, nz, payload)
	if not rebuild:
		(layer.tex as ImageTexture3D).update(images)
		return true
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_R8, ny, nx, nz, false, images)
	layer.tex = tex

	# [Achse, normierte Position]: 0 z konstant, 1 y konstant, 2 x konstant.
	var specs: Array = []
	if count == 0:
		specs = [[0, _mid(nz)], [2, _mid(nx)], [1, _mid(ny)]]
	else:
		var seen := {}
		for i in range(1, count + 1):
			var k := clampi(roundi((i - 0.5) * nz / count), 1, nz)
			if not seen.has(k):
				seen[k] = true
				specs.append([0, (k - 0.5) / nz])

	var off: Vector3 = layer.o
	var ext: Vector3 = layer.e
	for spec: Array in specs:
		var axis: int = spec[0]
		var pos: float = spec[1]
		var origin := off
		var du := Vector3.ZERO
		var dv := Vector3.ZERO
		match axis:
			0:
				origin.z += ext.z * pos
				du = Vector3(ext.x, 0, 0)
				dv = Vector3(0, ext.y, 0)
			1:
				origin.y += ext.y * pos
				du = Vector3(ext.x, 0, 0)
				dv = Vector3(0, 0, ext.z)
			_:
				origin.x += ext.x * pos
				du = Vector3(0, ext.y, 0)
				dv = Vector3(0, 0, ext.z)
		var mat := ShaderMaterial.new()
		mat.shader = _shader("field_slice")
		mat.set_shader_parameter("vol", tex)
		mat.set_shader_parameter("axis", axis)
		mat.set_shader_parameter("slice", pos)
		mat.set_shader_parameter("colormap", colormap)
		mat.set_shader_parameter("alpha", 0.5 if specs.size() > 1 else 1.0)
		var mi := MeshInstance3D.new()
		mi.mesh = _surface(1, 1, func(u: float, v: float) -> Vector3:
			return origin + du * u + dv * v)
		mi.material_override = mat
		layer.root.add_child(mi)
		layer.mats.append(mat)
	return true


func _mid(n: int) -> float:
	return (clampi(roundi(n / 2.0), 1, n) - 0.5) / n


## S/C 3v<a>: Raymarching. a=0 Standarddeckkraft (0.25), a=1..9 entspricht 0.1..0.9.
func _volume(layer: Dictionary, rebuild: bool, magic: String, dims: Array, payload: PackedByteArray) -> bool:
	var ny: int = dims[0]
	var nx: int = dims[1]
	var nz: int = dims[2]
	var images := _volume_images(ny, nx, nz, payload)
	if not rebuild:
		(layer.tex as ImageTexture3D).update(images)
		return true
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_R8, ny, nx, nz, false, images)
	layer.tex = tex

	var alpha := (int(magic[3]) / 10.0) if magic[3].is_valid_int() else 0.0
	if alpha == 0.0:
		alpha = 0.25
	var off: Vector3 = layer.o
	var ext: Vector3 = layer.e
	var mat := ShaderMaterial.new()
	mat.shader = _shader("volume_raymarch")
	mat.set_shader_parameter("volume_tex", tex)
	mat.set_shader_parameter("colormap", colormap)
	# Standard density_scale 4.0 entspricht alpha 0.25.
	mat.set_shader_parameter("density_scale", 16.0 * alpha)
	var box := BoxMesh.new()
	box.size = ext
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.position = off + ext / 2.0
	mi.material_override = mat
	layer.root.add_child(mi)
	layer.mats.append(mat)
	return true


func _volume_images(ny: int, nx: int, nz: int, payload: PackedByteArray) -> Array[Image]:
	var images: Array[Image] = []
	var plane := ny * nx
	for z in nz:
		images.append(Image.create_from_data(ny, nx, false, Image.FORMAT_R8,
				payload.slice(z * plane, (z + 1) * plane)))
	return images


# ---- Vektorfelder -----------------------------------------------------------

## V 2p/3p<k>: Gitterpunkte um den Vektor verschoben (k=1: auf etwa einen Gitterabstand
## autoskaliert, sonst Originallaenge). V 2q/3q<c>: Pfeile mit exakter Laenge.
func _vectors(layer: Dictionary, rebuild: bool, magic: String, info: Dictionary, payload: PackedByteArray) -> bool:
	var vis := magic[2]
	if vis != "p" and vis != "q":
		return false
	var dims: Array = info.dims
	var ny: int = dims[0]
	var nx: int = dims[1]
	var nz: int = dims[2]
	var is_2d := magic[1] == "2"
	var ncomp := 2 if is_2d else 3
	var sy := maxi(1, ceili(ny / (25.0 if is_2d else 12.0)))
	var sx := maxi(1, ceili(nx / (25.0 if is_2d else 12.0)))
	var sz := 1 if is_2d else maxi(1, ceili(nz / 8.0))
	var o: Vector3 = layer.o
	var e: Vector3 = layer.e
	var step := Vector3(e.x / nx, e.y / ny, e.z / nz)
	var vspan: Array = info.vspan
	var k := int(magic[3]) if magic[3].is_valid_int() else 0

	var positions := PackedVector3Array()
	var vectors := PackedVector3Array()
	var speeds := PackedFloat32Array()
	var maxmag := 0.0
	for iz in range(0, 1 if is_2d else nz, sz):
		for ix in range(0, nx, sx):
			for iy in range(0, ny, sy):
				var v := Vector3.ZERO
				for c in ncomp:
					var q := payload[iy + ny * (ix + nx * (iz + nz * c))]
					v[c] = vspan[0] + q / 255.0 * (vspan[1] - vspan[0])
				var z := o.z if is_2d else o.z + step.z * (iz + 0.5)
				positions.append(Vector3(o.x + step.x * (ix + 0.5), o.y + step.y * (iy + 0.5), z))
				vectors.append(v)
				speeds.append(v.length())
				maxmag = maxf(maxmag, v.length())

	if vis == "p":
		var spacing := minf(step.x * sx, step.y * sy)
		if not is_2d:
			spacing = minf(spacing, step.z * sz)
		var factor := 1.0
		if k == 1:
			factor = 0.7 * spacing / maxf(maxmag, 1e-12)
		var colors := PackedColorArray()
		for i in positions.size():
			positions[i] += factor * vectors[i]
			colors.append(VECTOR_POINT_COLOR)
		_set_points(layer, rebuild, positions, colors, 0.5 * particle_radius)
	else:
		_set_arrow_layer(layer, rebuild, positions, vectors, _arrow_colors(speeds, k))
	return true


# ---- Partikel -----------------------------------------------------------------

## P 2p/3p<c>: Partikel, P 2q/3q<c>: Vektoren (Strassen). Spalten [x y (z) (vx vy (vz))],
## Positionen normiert 0..1 in der Box, Vektoren werden mit der Boxausdehnung skaliert.
func _particles(layer: Dictionary, rebuild: bool, magic: String, info: Dictionary, payload: PackedByteArray) -> bool:
	var vis := magic[2]
	if vis != "p" and vis != "q":
		return false
	var dims: Array = info.dims
	var n: int = dims[0]
	var nc: int = dims[1]
	var nd := int(magic[1])
	var has_vel := nc == 2 * nd
	if nc != nd and not has_vel:
		return false
	if vis == "q" and not has_vel:
		return false
	var k := int(magic[3]) if magic[3].is_valid_int() else 0
	var data := payload.to_float32_array()
	var o: Vector3 = layer.o
	var e: Vector3 = layer.e

	var positions := PackedVector3Array()
	var vectors := PackedVector3Array()
	var speeds := PackedFloat32Array()
	for i in n:
		var p := Vector3(0.0, 0.0, o.z)
		for c in nd:
			p[c] = o[c] + e[c] * data[i + n * c]
		positions.append(p)
		if has_vel:
			var raw := Vector3.ZERO
			for c in nd:
				raw[c] = data[i + n * (nd + c)]
			speeds.append(raw.length())
			vectors.append(Vector3(e.x * raw.x, e.y * raw.y, e.z * raw.z))

	if vis == "p":
		var colors: PackedColorArray
		if k == 0 and has_vel:
			colors = _speed_colors(speeds)
		else:
			colors = PackedColorArray()
			colors.resize(n)
			colors.fill(_palette(k))
		_set_points(layer, rebuild, positions, colors, particle_radius)
	else:
		_set_arrow_layer(layer, rebuild, positions, vectors, _arrow_colors(speeds, k))
	return true


# ---- Punkte und Pfeile -------------------------------------------------------

func _set_points(layer: Dictionary, rebuild: bool, points: PackedVector3Array,
		colors: PackedColorArray, radius: float) -> void:
	if rebuild:
		var created := MultiMesh.new()
		created.transform_format = MultiMesh.TRANSFORM_3D
		created.use_colors = true
		var ball := SphereMesh.new()
		ball.radius = radius
		ball.height = 2.0 * radius
		ball.radial_segments = 16
		ball.rings = 8
		created.mesh = ball
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = created
		mi.material_override = _lit_material()
		layer.root.add_child(mi)
		layer.spheres = created
	var spheres: MultiMesh = layer.spheres
	if spheres.instance_count != points.size():
		spheres.instance_count = points.size()
	for i in points.size():
		spheres.set_instance_transform(i, Transform3D(Basis.IDENTITY, points[i]))
		spheres.set_instance_color(i, colors[i])


## Pfeile mit Laenge |vector| (Einheit der Box), gefaerbt nach `colors`.
func _set_arrow_layer(layer: Dictionary, rebuild: bool, positions: PackedVector3Array,
		vectors: PackedVector3Array, colors: PackedColorArray) -> void:
	if rebuild or not layer.has("mm"):
		layer.mm = _arrow_instances(layer.root, positions.size())
	elif (layer.mm as MultiMesh).instance_count != positions.size():
		(layer.mm as MultiMesh).instance_count = positions.size()
	var arrow_lengths := PackedFloat32Array()
	for i in positions.size():
		arrow_lengths.append(vectors[i].length())
	_set_arrows(layer.mm, positions, vectors, arrow_lengths, colors)


## Farbe nach Betrag (c=0, Skala bis max(1, groesster Betrag)) oder feste Farbe (c=1..9).
func _arrow_colors(speeds: PackedFloat32Array, k: int) -> PackedColorArray:
	if k == 0:
		return _speed_colors(speeds)
	var colors := PackedColorArray()
	colors.resize(speeds.size())
	colors.fill(_palette(k))
	return colors


func _speed_colors(speeds: PackedFloat32Array) -> PackedColorArray:
	var limit := 1.0
	for s in speeds:
		limit = maxf(limit, s)
	var colors := PackedColorArray()
	for s in speeds:
		colors.append(_turbo(s / limit))
	return colors


func _palette(k: int) -> Color:
	return SPECIES_COLORS[(maxi(1, k) - 1) % SPECIES_COLORS.size()]


func _arrow_instances(root: Node3D, count: int, color := Color.WHITE) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _arrow_mesh
	mm.instance_count = count
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = _flat_material(color, true)
	root.add_child(mi)
	return mm


func _set_arrows(mm: MultiMesh, positions: PackedVector3Array, vectors: PackedVector3Array,
		lengths: PackedFloat32Array, colors: PackedColorArray) -> void:
	for i in positions.size():
		var len := lengths[i]
		var basis := Basis.from_scale(Vector3.ZERO)
		if len > 1e-9:
			var x := vectors[i].normalized()
			var up := Vector3.UP if absf(x.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			var z := x.cross(up).normalized()
			var y := z.cross(x)
			basis = Basis(x * len, y * len, z * len)
		mm.set_instance_transform(i, Transform3D(basis, positions[i]))
		mm.set_instance_color(i, colors[i])


## Beleuchtetes Material fuer Kugeln (Partikel, Gitterpunkte): Farbe pro Instanz.
func _lit_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.5
	mat.metallic = 0.0
	return mat


func _flat_material(color: Color, vertex_colors: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mat.vertex_color_use_as_albedo = vertex_colors
	return mat


## Pfeil entlang +x mit Laenge 1: sechseckiger Schaft und Kegelspitze.
func _make_arrow_mesh() -> ArrayMesh:
	var sides := 6
	var shaft_r := 0.015
	var head_r := 0.05
	var neck := 0.7
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in sides:
		var a := TAU * i / sides
		verts.append(Vector3(0.0, cos(a) * shaft_r, sin(a) * shaft_r))
	for i in sides:
		var a := TAU * i / sides
		verts.append(Vector3(neck, cos(a) * shaft_r, sin(a) * shaft_r))
	for i in sides:
		var a := TAU * i / sides
		verts.append(Vector3(neck, cos(a) * head_r, sin(a) * head_r))
	var tip := verts.size()
	verts.append(Vector3(1.0, 0.0, 0.0))
	for i in sides:
		var j := (i + 1) % sides
		idx.append_array([i, j, sides + i, j, sides + j, sides + i])
		idx.append_array([2 * sides + i, 2 * sides + j, tip])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Polynomnaeherung der Turbo-Farbskala (wie MATLAB turbo).
func _turbo(t: float) -> Color:
	t = clampf(t, 0.0, 1.0)
	var r := 0.13572138 + t * (4.61539260 + t * (-42.66032258 + t * (132.13108234 + t * (-152.94239396 + t * 59.28637943))))
	var g := 0.09140261 + t * (2.19418839 + t * (4.84296658 + t * (-14.18503333 + t * (4.27729857 + t * 2.82956604))))
	var b := 0.10667330 + t * (12.64194608 + t * (-60.58204836 + t * (110.36276771 + t * (-89.90310912 + t * 27.34824973))))
	return Color(clampf(r, 0.0, 1.0), clampf(g, 0.0, 1.0), clampf(b, 0.0, 1.0))


# ---- Hilfen ---------------------------------------------------------------------

func _shader(shader_name: String) -> Shader:
	if not _shaders.has(shader_name):
		_shaders[shader_name] = load("res://%s.gdshader" % shader_name)
	return _shaders[shader_name]


## Parametrische Flaeche mit UV = (u, v) auf dem Gitter nu x nv.
func _surface(nu: int, nv: int, fn: Callable) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for j in nv + 1:
		for i in nu + 1:
			var u := float(i) / nu
			var v := float(j) / nv
			verts.append(fn.call(u, v))
			uvs.append(Vector2(u, v))
	for j in nv:
		for i in nu:
			var a := j * (nu + 1) + i
			var b := a + 1
			var c := a + nu + 1
			var d := c + 1
			idx.append_array([a, b, d, a, d, c])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
