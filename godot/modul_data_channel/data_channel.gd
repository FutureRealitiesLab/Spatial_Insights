extends Node

## data_channel.gd – Autoload "DataChannel" (modul_data_channel).
##
## Verteilt große Datenframes vom Server an alle Clients, getrennt vom Rest des
## Spiels. Das Modul kennt keinen Dateninhalt: ein Frame ist ein benannter Kanal,
## ein Meta-Dictionary und ein PackedByteArray.
##
## Server:   DataChannel.publish("kanal", meta, bytes)
## Clients:  DataChannel.received.connect(func(channel, meta, bytes, server_time_ms): ...)
##
## Eigenschaften:
##   • Eigener ENet-Transferkanal (TRANSFER_CHANNEL): blockiert keine Avatar-Posen.
##   • Ack-Flusskontrolle je Client und Kanal: ein Frame ist unterwegs, der nächste
##     geht erst nach dem Ack. Bis dahin zählt nur der neueste ("latest wins").
##   • Late Join: Neue Clients bekommen den letzten Frame jedes Kanals.
##   • Optional zstd-Kompression auf dem Server (publish(..., true)).
##
## Voraussetzung: Der Server hat Peer-ID 1 (Situs Core) und der Autoload existiert
## auf allen Instanzen unter demselben Namen. Keine Abhängigkeit zu Situs Core
## oder zum Dateninhalt.

## Auf Clients: ein Frame ist angekommen (bereits entpackt).
signal received(channel: String, meta: Dictionary, payload: PackedByteArray, server_time_ms: int)

## ENet-Kanal für Frames und Acks. 0 nutzt Godot für das normale RPC.
const TRANSFER_CHANNEL := 1
## Geht ein Ack verloren, darf nach dieser Zeit erneut gesendet werden.
const ACK_TIMEOUT_MS := 1500

## Server-Statistik (für Overlays)
var stats := {
	"published": 0,       # publish()-Aufrufe
	"sent": 0,            # tatsächlich gesendete Frames (an alle Clients zusammen)
	"skipped": 0,         # Frames, die durch einen neueren ersetzt wurden, bevor sie gesendet wurden
	"bytes_sent": 0,      # Bytes auf der Leitung (nach Kompression)
	"bytes_raw": 0,       # Bytes vor Kompression, gleiche Zählung
}

## Client-Statistik (für Overlays)
var client_stats := {
	"frames": 0,
	"bytes": 0,           # Bytes auf der Leitung
	"last_channel": "",
	"last_seq": -1,
}

var _seq: int = 0
## channel → Frame (letzter veröffentlichter Stand, für Late Join und Nachsenden)
var _latest: Dictionary = {}
## peer_id → { channel → { "inflight": bool, "sent_ms": int, "seq": int, "pending": bool } }
var _peers: Dictionary = {}
## peer_id → geglaettete Ack-Zeit in ms (gleitender Mittelwert)
var _ack_ms: Dictionary = {}


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


# ══════════════════════════════════════════════════════════════════
#  Server
# ══════════════════════════════════════════════════════════════════

## Veröffentlicht einen Frame auf einem Kanal. Nur auf dem Server.
## `meta` muss mit dem Godot-Variant-Format übertragbar sein (Zahlen, Strings, Arrays, Dictionaries).
func publish(channel: String, meta: Dictionary, payload: PackedByteArray, compress: bool = false) -> void:
	if not multiplayer.is_server():
		push_warning("[DataChannel] publish() ist nur auf dem Server erlaubt.")
		return
	_seq += 1
	var wire := payload
	if compress and payload.size() > 0:
		wire = payload.compress(FileAccess.COMPRESSION_ZSTD)
	_latest[channel] = {
		"seq": _seq,
		"time_ms": Time.get_ticks_msec(),
		"meta": meta,
		"compressed": compress and payload.size() > 0,
		"raw_size": payload.size(),
		"bytes": wire,
	}
	stats.published += 1
	for peer_id: int in multiplayer.get_peers():
		_offer(peer_id, channel)


## Vergisst alle gespeicherten Frames (z. B. bei einer neuen Datenquelle), damit
## spät beitretende Clients keinen veralteten Stand bekommen.
func clear_all() -> void:
	_latest.clear()
	for peer_id: int in _peers:
		for state: Dictionary in _peers[peer_id].values():
			state.pending = false


func _peer_state(peer_id: int, channel: String) -> Dictionary:
	if not _peers.has(peer_id):
		_peers[peer_id] = {}
	if not _peers[peer_id].has(channel):
		_peers[peer_id][channel] = {"inflight": false, "sent_ms": 0, "seq": 0, "pending": false}
	return _peers[peer_id][channel]


func _offer(peer_id: int, channel: String) -> void:
	var state := _peer_state(peer_id, channel)
	if state.inflight and Time.get_ticks_msec() - state.sent_ms < ACK_TIMEOUT_MS:
		if state.pending:
			stats.skipped += 1
		state.pending = true
		return
	_send(peer_id, channel, state)


func _send(peer_id: int, channel: String, state: Dictionary) -> void:
	var frame: Dictionary = _latest[channel]
	state.inflight = true
	state.pending = false
	state.sent_ms = Time.get_ticks_msec()
	state.seq = frame.seq
	var bytes: PackedByteArray = frame.bytes
	_rpc_frame.rpc_id(peer_id, channel, frame.seq, frame.time_ms, frame.meta,
			frame.compressed, frame.raw_size, bytes)
	stats.sent += 1
	stats.bytes_sent += bytes.size()
	stats.bytes_raw += frame.raw_size


func _on_peer_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	for channel: String in _latest:
		_offer(peer_id, channel)


func _on_peer_disconnected(peer_id: int) -> void:
	_peers.erase(peer_id)
	_ack_ms.erase(peer_id)


## Geglaettete Ack-Zeit eines Clients in ms (alle Kanaele zusammen), -1 wenn noch keine.
func get_ack_ms(peer_id: int) -> float:
	return _ack_ms.get(peer_id, -1.0)


## Client → Server: Frame `seq` ist angekommen. Läuft auf dem Server.
@rpc("any_peer", "reliable", "call_remote", TRANSFER_CHANNEL)
func _rpc_ack(channel: String, seq: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var state := _peer_state(peer_id, channel)
	if seq < state.seq:
		return
	# Ack-Zeit: Senden bis Bestaetigung = Netzlaufzeit hin und zurueck plus Verarbeitung auf dem
	# Client (Entpacken, Textur-Update), weil der Client erst nach dem Anzeigen bestaetigt.
	if seq == state.seq and state.inflight:
		var ms := float(Time.get_ticks_msec() - state.sent_ms)
		_ack_ms[peer_id] = ms if not _ack_ms.has(peer_id) else lerpf(_ack_ms[peer_id], ms, 0.2)
	state.inflight = false
	if state.pending and _latest.has(channel):
		_send(peer_id, channel, state)


# ══════════════════════════════════════════════════════════════════
#  Client
# ══════════════════════════════════════════════════════════════════

## Server → Client: ein Frame. Läuft auf Clients.
@rpc("authority", "reliable", "call_remote", TRANSFER_CHANNEL)
func _rpc_frame(channel: String, seq: int, time_ms: int, meta: Dictionary,
		compressed: bool, raw_size: int, bytes: PackedByteArray) -> void:
	var payload := bytes
	if compressed:
		payload = bytes.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	client_stats.frames += 1
	client_stats.bytes += bytes.size()
	client_stats.last_channel = channel
	client_stats.last_seq = seq
	received.emit(channel, meta, payload, time_ms)
	_rpc_ack.rpc_id(1, channel, seq)
