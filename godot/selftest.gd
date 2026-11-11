extends SceneTree
## Selbsttest ohne Netzwerk:
##   Godot --headless --path godot --script res://selftest.gd
## Speist synthetische Pakete (Format von udpSend.m) in den Empfaenger und
## zeichnet jedes Magic ueber die Hauptszene.

var _failures := 0


func _initialize() -> void:
	_test_bits()
	_test_receiver()
	await _test_scene()
	print("selftest: %s" % ("OK" if _failures == 0 else "%d FEHLER" % _failures))
	quit(0 if _failures == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if not cond:
		_failures += 1
		printerr("FEHLER: ", what)


# ---- Paketbau (spiegelt udpSend.m) -----------------------------------------

func _base(magic: String, session: int, frame: int, index: int, count: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(44)
	b.encode_u32(4, session)
	b.encode_u32(8, frame)
	b.encode_u32(12, index)
	b.encode_u32(16, count)
	# Spatial Box [xmin xmax ymin ymax zmin zmax] ab Byte 20 (float32).
	var box := [0.0, 8.0, 0.0, 4.0, 0.0, 2.0]
	for i in 6:
		b.encode_float(20 + 4 * i, box[i])
	var m := magic.to_ascii_buffer()
	for i in 4:
		b[i] = m[i]
	return b


func _ext_header(magic: String, dims: Array, vspan: Array, nostates: int) -> PackedByteArray:
	var h := PackedByteArray()
	match magic[0]:
		"S", "V":
			h.resize(32)
			for i in 4:
				h.encode_u32(4 * i, dims[i])
			h.encode_double(16, vspan[0])
			h.encode_double(24, vspan[1])
		"P":
			h.resize(8)
			h.encode_u32(0, dims[0])
			h.encode_u32(4, dims[1])
		"C":
			h.resize(13)
			for i in 3:
				h.encode_u32(4 * i, dims[i])
			h[12] = nostates
	return h


func _packets(magic: String, session: int, frame: int, dims: Array, vspan: Array,
		nostates: int, payload: PackedByteArray, chunk_size: int) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	var count := ceili(payload.size() / float(chunk_size))
	for k in count:
		var p := _base(magic, session, frame, k, count)
		p.append_array(_ext_header(magic, dims, vspan, nostates))
		p.append_array(payload.slice(k * chunk_size, (k + 1) * chunk_size))
		out.append(p)
	return out


func _receiver() -> Node:
	var r: Node = load("res://udp_receiver.gd").new()
	r.listen = false
	return r


# ---- Tests --------------------------------------------------------------------

func _test_bits() -> void:
	var bits := load("res://udp_receiver.gd")
	for pair in [[1, 1], [2, 1], [3, 2], [4, 2], [5, 4], [16, 4], [17, 8], [200, 8], [255, 8]]:
		_check(bits.bits_per_state(pair[0]) == pair[1], "bits_per_state(%d)" % pair[0])


func _test_receiver() -> void:
	var r := _receiver()

	# Feld in zwei Chunks.
	var payload := PackedByteArray()
	for i in 42:
		payload.append(i * 5)
	for p in _packets("S2i0", 1, 1, [6, 7, 1, 1], [-1.0, 1.0], 0, payload, 30):
		r.handle_packet(p)
	var f: Dictionary = r.pop_frame()
	_check(not f.is_empty() and f.payload == payload, "S2i0 payload")
	_check(f.info.vspan == [-1.0, 1.0] and f.info.dims == [6, 7, 1, 1], "S2i0 info")

	# Zellularautomat nostates=5 (4 Bit, niederwertiges Nibble zuerst).
	var states := PackedByteArray()
	for i in 35:
		states.append(i % 5)
	var packed := PackedByteArray()
	packed.resize(18)
	for i in 35:
		packed[i / 2] = packed[i / 2] | (states[i] << ((i % 2) * 4))
	for p in _packets("C2i0", 1, 2, [5, 7, 1], [], 5, packed, 100):
		r.handle_packet(p)
	f = r.pop_frame()
	_check(not f.is_empty() and f.payload == packed and f.info.bits == 4, "C payload stays packed")
	_check(not f.is_empty() and load("res://udp_receiver.gd").unpack_states(f.payload, 35, 5) == states, "C unpack")

	# Abwechselnde Daten: S1, V2, S3 -> V2 und S3 (S1 wird ersetzt), je ein Frame pro Aufruf.
	var vp := PackedByteArray()
	vp.resize(5 * 6 * 4 * 3)
	var sp := PackedByteArray()
	sp.resize(5 * 6 * 4)
	for p in _packets("S3i0", 2, 1, [5, 6, 4, 1], [0.0, 1.0], 0, sp, 100):
		r.handle_packet(p)
	for p in _packets("V3q0", 2, 2, [5, 6, 4, 3], [-1.0, 1.0], 0, vp, 100):
		r.handle_packet(p)
	for p in _packets("S3i0", 2, 3, [5, 6, 4, 1], [0.0, 1.0], 0, sp, 100):
		r.handle_packet(p)
	var first: Dictionary = r.pop_frame()
	var second: Dictionary = r.pop_frame()
	_check(first.magic == "V3q0" and first.info.frame_id == 2, "queue order V")
	_check(second.magic == "S3i0" and second.info.frame_id == 3, "queue newest S")
	_check(r.pop_frame().is_empty(), "queue empty")

	# Altes Frame und alte Session werden verworfen.
	for p in _packets("S3i0", 2, 3, [5, 6, 4, 1], [0.0, 1.0], 0, sp, 100):
		r.handle_packet(p)
	_check(r.pop_frame().is_empty(), "duplicate frame ignored")
	for p in _packets("S3i0", 1, 9, [5, 6, 4, 1], [0.0, 1.0], 0, sp, 100):
		r.handle_packet(p)
	_check(r.pop_frame().is_empty(), "retired session ignored")

	# Ungueltige Dimensionen: V3 braucht nv=3.
	for p in _packets("V3q0", 3, 1, [5, 6, 4, 2], [-1.0, 1.0], 0, vp, 100):
		r.handle_packet(p)
	_check(r.pop_frame().is_empty(), "invalid header rejected")
	r.free()


func _test_scene() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	scene.get_node("Receiver").listen = false
	root.add_child(scene)
	await process_frame  # _ready der Szene (Pfeilmesh) muss vor dem ersten Frame laufen
	var r: Node = scene.get_node("Receiver")
	var view: Node = scene.get_node("Plot/View")

	var cases := [
		["S2s0", [12, 16, 1, 1]], ["S2s1", [12, 16, 1, 1]], ["S2s2", [12, 16, 1, 1]], ["S2s3", [12, 16, 1, 1]],
		["S3s0", [8, 10, 6, 1]], ["S3s3", [8, 10, 6, 1]], ["S3v0", [8, 10, 6, 1]], ["S3v5", [8, 10, 6, 1]],
		["V2p1", [8, 10, 1, 2]], ["V2q0", [8, 10, 1, 2]], ["V2q3", [8, 10, 1, 2]],
		["V3p0", [6, 6, 4, 3]], ["V3q0", [6, 6, 4, 3]], ["V3q2", [6, 6, 4, 3]],
		["P2p0", [20, 4]], ["P2p1", [20, 2]], ["P2q0", [20, 4]], ["P3p0", [20, 6]], ["P3q2", [20, 6]],
		["C2s0", [9, 11, 1]], ["C2s1", [9, 11, 1]], ["C2s2", [9, 11, 1]], ["C2s3", [9, 11, 1]],
		["C3s0", [6, 7, 5]], ["C3v0", [6, 7, 5]],
	]
	var frame := 0
	for round_index in 2:  # Zweite Runde: Update statt Neuaufbau.
		for c: Array in cases:
			var magic: String = c[0]
			var dims: Array = c[1]
			var n := 1
			for d: int in dims:
				n *= d
			var payload := PackedByteArray()
			match magic[0]:
				"S", "V":
					payload.resize(n)
					for i in n:
						payload[i] = (i * 7 + frame) % 256
				"P":
					var f32 := PackedFloat32Array()
					for i in n:
						f32.append(fmod(i * 0.137 + frame * 0.01, 1.0))
					payload = f32.to_byte_array()
				"C":
					payload.resize(ceili(n * 4 / 8.0))
					for i in payload.size():
						payload[i] = (i * 37) % 256
			frame += 1
			for p in _packets(magic, 9, frame, dims, [-1.0, 1.0], 5, payload, 200):
				r.handle_packet(p)
			var f: Dictionary = r.pop_frame()
			_check(not f.is_empty(), "frame " + magic)
			if not f.is_empty():
				view.show_frame(f.magic, f.info, f.payload)
	_check(view.layers.size() == cases.size(), "layer count %d" % view.layers.size())
	# 2D-Daten liegen bei zmin der Box, jede Ebene traegt die Box des Senders.
	for key: String in ["S2s0", "V2q0", "P2p0", "C2s0"]:
		_check(view.layers.has(key) and is_zero_approx(view.layers[key].o.z), "floor " + key)
	_check(view.layers["S3v0"].e.is_equal_approx(Vector3(8.0, 4.0, 2.0)), "box extent")
	# MATLAB x/y/z -> Raum: x (8 m) entlang -z, y (4 m) entlang -x, z nach oben.
	var plot: Node3D = view.get_parent()
	var corner: Vector3 = plot.transform * Vector3(view.box_size.x, view.box_size.y, view.box_size.z)
	_check(corner.is_equal_approx(Vector3(-2.0, 2.0, -4.0)), "plot corner %s" % corner)
	scene.free()
