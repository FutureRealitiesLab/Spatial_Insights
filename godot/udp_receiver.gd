extends Node
## Empfaengt typisierte Simulationsframes per UDP (Port von udp/udpReceive.m).
##
## Protokoll v2 (PROTOCOL.md, 2026-11-11): 44-Byte-Gemeinsamer-Header mit
## Spatial Box (float32[6] [xmin xmax ymin ymax zmin zmax]) an Offset 20-43.
## Typ-spezifische Daten beginnen ab Offset 44 (vorher 20).
##
## magic(1) waehlt Header und Payload: S/V Feld, P Partikel, C Zellularautomat.
## Mehrere Magics koennen denselben Frame-ID haben; jedes Magic wird
## unabhaengig verfolgt. Pro Frame wird `frame_received` ausgeloest.
## Payload:
##   S/V: quantisierte uint8-Werte (Bereich info.vspan), V dequantisieren per vspan
##   P:   float32-Bytes [N nCoords], Positionen normalisiert 0..1
##   C:   bitgepackte Zustaende (info.bits Bit pro Zelle), der Shader entpackt
## info.box = [xmin xmax ymin ymax zmin zmax] gibt den Simulationsraum an.

signal frame_received(magic: String, info: Dictionary, payload: PackedByteArray)

## Gemeinsamer Header: 44 Bytes (vorher 20; Box ab Offset 20 hinzugekommen).
const BASE_HEADER := 44
const MAX_FRAME_BYTES := 256 * 1024 * 1024
const MAX_CHUNKS := 100000
const MAX_RETIRED := 32
const MAX_PACKETS_PER_TICK := 4096

@export var port: int = 4242
## IPv4-Absender (MATLAB udpport 'IPV4'); "*" bindet je nach Plattform nur IPv6.
@export var bind_address: String = "0.0.0.0"
@export var recv_buffer_size: int = 4 * 1024 * 1024
## Ohne Socket arbeiten (fuer Tests): Pakete per handle_packet() einspeisen.
@export var listen: bool = true

var _udp := PacketPeerUDP.new()
var _session_id: int = -1
var _retired: Array[int] = []
var _queue: Array[Dictionary] = []
## Per-Magic aktiver Frame: magic → {frame_id, hdr, chunks, got}
var _active: Dictionary = {}
## Per-Magic letzter abgeschlossener Frame-ID: magic → int
var _completed_frame_id: Dictionary = {}

# Statistik (vom Debug-Overlay gelesen)
var listening: bool = false
var packets_per_s: float = 0.0
var frames_per_s: float = 0.0
var kb_per_s: float = 0.0
var kb_per_frame: float = 0.0
var dropped_frames: int = 0
var bad_packets: int = 0
var last_sender: String = "-"
var last_magic: String = ""
var last_frame_id: int = -1
var session_id: int = -1
var queue_size: int = 0

var _stat_time: float = 0.0
var _stat_packets: int = 0
var _stat_frames: int = 0
var _stat_bytes: int = 0


func _ready() -> void:
	if not listen:
		return
	var err := _udp.bind(port, bind_address, recv_buffer_size)
	listening = err == OK
	if listening:
		print("UDP-Empfaenger lauscht auf Port ", port)
	else:
		push_error("UDP bind auf Port %d fehlgeschlagen: %s" % [port, error_string(err)])


func _exit_tree() -> void:
	_udp.close()


func _process(delta: float) -> void:
	var count := 0
	while listening and _udp.get_available_packet_count() > 0 and count < MAX_PACKETS_PER_TICK:
		var pkt := _udp.get_packet()
		count += 1
		if _udp.get_packet_error() != OK:
			continue
		last_sender = "%s:%d" % [_udp.get_packet_ip(), _udp.get_packet_port()]
		_stat_packets += 1
		_stat_bytes += pkt.size()
		handle_packet(pkt)

	# Pro Aufruf nur ein Frame, damit jede Darstellung einzeln ankommt.
	var frame := pop_frame()
	if not frame.is_empty():
		_stat_frames += 1
		kb_per_frame = (frame.payload as PackedByteArray).size() / 1024.0
		frame_received.emit(frame.magic, frame.info, frame.payload)

	_stat_time += delta
	if _stat_time >= 1.0:
		packets_per_s = _stat_packets / _stat_time
		frames_per_s = _stat_frames / _stat_time
		kb_per_s = _stat_bytes / 1024.0 / _stat_time
		_stat_time = 0.0
		_stat_packets = 0
		_stat_frames = 0
		_stat_bytes = 0
	queue_size = _queue.size()


## Aeltestes fertiges Frame ({magic, info, payload}) oder leeres Dictionary.
func pop_frame() -> Dictionary:
	if _queue.is_empty():
		return {}
	return _queue.pop_front()


func handle_packet(pkt: PackedByteArray) -> void:
	if pkt.size() <= BASE_HEADER:
		bad_packets += 1
		return
	var magic := pkt.slice(0, 4).get_string_from_ascii()
	var header_size := _header_size(magic)
	if header_size == 0 or pkt.size() <= header_size:
		bad_packets += 1
		return

	var sid := pkt.decode_u32(4)
	var frame_id := pkt.decode_u32(8)
	var index := pkt.decode_u32(12)
	var count := pkt.decode_u32(16)
	if count < 1 or count > MAX_CHUNKS or index >= count:
		bad_packets += 1
		return

	# Eine neue Session (Neustart der Simulation) verwirft den Zustand aller Magics.
	if _session_id < 0 or sid != _session_id:
		if _retired.has(sid):
			return  # Spaetes Paket einer alten Session.
		if _session_id >= 0:
			_retired.append(_session_id)
			if _retired.size() > MAX_RETIRED:
				_retired.pop_front()
		_session_id = sid
		session_id = sid
		_active.clear()
		_completed_frame_id.clear()
		_queue.clear()

	# Per-Magic Frame-Tracking: jedes Magic kann gleichzeitig einen eigenen
	# aktiven Frame haben. Gleicher Frame-ID mit unterschiedlichem Magic ist erlaubt.
	var last_id: int = _completed_frame_id.get(magic, -1)
	if last_id >= 0 and frame_id <= last_id:
		return  # Altes Frame fuer dieses Magic.

	var active: Dictionary = _active.get(magic, {})
	if active.is_empty() or frame_id > active.frame_id:
		var hdr := _read_header(pkt, magic)
		# Allokationen gegen fehlerhaften Netzwerkverkehr begrenzen.
		if hdr.is_empty() or hdr.required_bytes > MAX_FRAME_BYTES or count > hdr.required_bytes:
			bad_packets += 1
			return
		if not active.is_empty():
			dropped_frames += 1  # Unvollstaendiges Frame wurde ueberholt.
		hdr["magic"] = magic
		var chunks := []
		chunks.resize(count)
		active = {"frame_id": frame_id, "hdr": hdr, "chunks": chunks, "got": 0}
		_active[magic] = active
	elif frame_id < active.frame_id or count != active.chunks.size():
		return

	var chunks: Array = active.chunks
	if chunks[index] == null:
		chunks[index] = pkt.slice(header_size)
		active.got += 1
	if active.got == chunks.size():
		_complete(magic)


func _complete(magic: String) -> void:
	var active: Dictionary = _active[magic]
	var frame_id: int = active.frame_id
	var hdr: Dictionary = active.hdr
	var bytes := PackedByteArray()
	for c: PackedByteArray in active.chunks:
		bytes.append_array(c)
	if bytes.size() == hdr.required_bytes:
		var info := {
			"magic": magic,
			"session_id": _session_id,
			"frame_id": frame_id,
			"dims": hdr.dims,
			"vspan": hdr.vspan,
			"nostates": hdr.nostates,
			"box": hdr.box,
			"bits": bits_per_state(hdr.nostates) if magic[0] == "C" else 0,
			"packets": active.chunks.size(),
		}
		# Pro Magic bleibt nur das neueste Frame in der Warteschlange.
		for i in range(_queue.size() - 1, -1, -1):
			if _queue[i].magic == magic:
				_queue.remove_at(i)
		_queue.append({"magic": magic, "info": info, "payload": bytes})
		_completed_frame_id[magic] = frame_id
		last_magic = magic
		last_frame_id = frame_id
	_active.erase(magic)


# ---- Header (analog zu headerSizeOf/headerField/... in udpReceive.m) ------

func _header_size(magic: String) -> int:
	match magic[0]:
		"S", "V":
			return 76   # 44 Gemeinsam + 32 Typ (4x uint32 + 2x float64)
		"P":
			return 52   # 44 + 8 (2x uint32)
		"C":
			return 57   # 44 + 13 (3x uint32 + 1x uint8)
	return 0


func _read_header(pkt: PackedByteArray, magic: String) -> Dictionary:
	match magic[0]:
		"S", "V":
			return header_field(pkt, magic)
		"P":
			return header_particle(pkt)
		"C":
			return header_cellular(pkt)
	return {}


## Liest die Spatial Box aus dem gemeinsamen Header (Offset 20, 6x float32 LE).
## Gibt [xmin, xmax, ymin, ymax, zmin, zmax] zurueck; Default [0,1,0,1,0,1].
func _read_box(pkt: PackedByteArray) -> Array:
	var b := []
	for i in 6:
		b.append(pkt.decode_float(20 + 4 * i))
	return b


## Feld: dims [ny nx nz nv] ab Byte 44, vspan [vmin vmax] ab Byte 60.
func header_field(pkt: PackedByteArray, magic: String) -> Dictionary:
	var dims := _read_dims(pkt, 4)
	var vspan := [pkt.decode_double(60), pkt.decode_double(68)]
	if dims.min() < 1 or not is_finite(vspan[0]) or not is_finite(vspan[1]):
		return {}
	var components := 1
	if magic[0] == "V":
		components = 2 if magic[1] == "2" else 3
	if dims[3] != components or (magic[1] == "2" and dims[2] != 1):
		return {}
	return {"dims": dims, "vspan": vspan, "nostates": 0,
			"box": _read_box(pkt),
			"required_bytes": dims[0] * dims[1] * dims[2] * dims[3]}


## Partikel: dims [nParticles nCoords] ab Byte 44.
func header_particle(pkt: PackedByteArray) -> Dictionary:
	var dims := _read_dims(pkt, 2)
	if dims.min() < 1 or not [2, 3, 4, 6].has(dims[1]):
		return {}
	return {"dims": dims, "vspan": [], "nostates": 0,
			"box": _read_box(pkt),
			"required_bytes": dims[0] * dims[1] * 4}


## Zellularautomat: dims [ny nx nz] ab Byte 44, nostates bei Byte 56.
func header_cellular(pkt: PackedByteArray) -> Dictionary:
	var dims := _read_dims(pkt, 3)
	var nostates := pkt.decode_u8(56)
	if dims.min() < 1 or nostates < 1:
		return {}
	var cells := _cell_count(dims)
	return {"dims": dims, "vspan": [], "nostates": nostates,
			"box": _read_box(pkt),
			"required_bytes": ceili(cells * bits_per_state(nostates) / 8.0)}


func _read_dims(pkt: PackedByteArray, n: int) -> Array:
	var dims := []
	for i in n:
		dims.append(pkt.decode_u32(BASE_HEADER + 4 * i))
	return dims


func _cell_count(dims: Array) -> int:
	var cells := 1
	for d: int in dims:
		cells *= d
	return cells


# ---- Zellularautomat entpacken ---------------------------------------------

## 2^ceil(log2(max(1, ceil(log2(nostates))))), exakt in Ganzzahlen.
static func bits_per_state(nostates: int) -> int:
	var levels := 0
	while (1 << levels) < nostates:
		levels += 1
	var target := maxi(1, levels)
	var bits := 1
	while bits < target:
		bits *= 2
	return bits


## Referenz zum Pruefen des Shaders (der Viewer entpackt auf der GPU).
## Packt Zustaende aus (niederwertige Bits zuerst); ein Byte pro Zelle.
static func unpack_states(payload: PackedByteArray, cells: int, nostates: int) -> PackedByteArray:
	var bits := bits_per_state(nostates)
	var per_byte := 8 / bits
	var mask := (1 << bits) - 1
	var out := PackedByteArray()
	out.resize(cells)
	for i in cells:
		out[i] = (payload[i / per_byte] >> ((i % per_byte) * bits)) & mask
	return out
