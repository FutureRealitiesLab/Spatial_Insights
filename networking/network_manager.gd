# TEMPLATE CORE – nicht verändern
extends Node

## network_manager.gd – Verbindet alle Geräte über WLAN.
##
## Schickt die eigene Position und Kopfbewegung an den Server;
## empfängt dieselben Daten von anderen Spielern und aktualisiert ihre Avatare.
## Der Server-PC leitet nur weiter — er hat keinen eigenen Avatar.
## Server-IP: Project Settings → Situs Core → Network → Server Ip
## (vor dem APK-Export auf die LAN-IP des Server-PCs setzen).

const SitusSettings := preload("res://addons/situs_core/core/situs_settings.gd")

const PORT: int = 7777
const MAX_CLIENTS: int = 8

## Sekunden zwischen automatischen Verbindungsversuchen (Client-Modus).
const RECONNECT_INTERVAL: float = 5.0

## IP-Adresse des Servers, aus den Project Settings. Bei Änderung APK neu exportieren.
var server_ip: String = SitusSettings.get_server_ip()

## Wird true sobald der Client erfolgreich verbunden hat
var client_connected_flag: bool = false

## Laufende Verbindungsversuche (öffentlich – NetDiag liest es)
var reconnect_attempts: int = 0

var _peer: ENetMultiplayerPeer = null
var _is_client: bool = false
var _reconnect_pending: bool = false
var _reconnect_timer: float = 0.0
var _client_signals_connected: bool = false


func _ready() -> void:
	print("[NetworkManager] Server-IP: ", server_ip)

# ── Signale (von world.gd und anderen abonniert) ────────────────
signal player_joined(peer_id: int)
signal player_left(peer_id: int)
signal client_connected()
## Wird emittiert wenn die Verbindung zum Server verloren geht.
## SceneManager räumt daraufhin Remote-Avatare auf.
signal client_disconnected()


# ══════════════════════════════════════════════════════════════════
#  Reconnect-Timer
# ══════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if not _reconnect_pending or not _is_client or client_connected_flag:
		return
	_reconnect_timer -= delta
	if _reconnect_timer <= 0.0:
		_reconnect_pending = false
		_reconnect_timer = 0.0
		reconnect_attempts += 1
		print("[NetworkManager] Verbindungsversuch %d zu %s:%d …" % [
			reconnect_attempts, server_ip, PORT])
		_do_connect()


# ══════════════════════════════════════════════════════════════════
#  Öffentliche API
# ══════════════════════════════════════════════════════════════════

func start_server() -> void:
	_peer = ENetMultiplayerPeer.new()
	if GameState.local_only:
		_peer.set_bind_ip("127.0.0.1")   # Einzelspieler: nur dieser PC
	var err: int = _peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		push_error("[NetworkManager] Server konnte nicht gestartet werden (Error %d)" % err)
		return
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[NetworkManager] Server läuft auf Port %d%s" % [PORT, " (nur lokal)" if GameState.local_only else ""])


func start_client(target_ip: String = "") -> void:
	if not target_ip.is_empty():
		server_ip = target_ip
	_is_client = true
	_reconnect_pending = false
	_reconnect_timer = 0.0
	reconnect_attempts = 1
	_do_connect()


## Interne Verbindungsaufbau-Routine – wird von start_client() und dem
## Reconnect-Timer aufgerufen.
func _do_connect() -> void:
	# Alten Peer sauber schließen bevor ein neuer aufgebaut wird.
	# Kein Signal-Cleanup nötig: Signale hängen am MultiplayerAPI-Objekt,
	# nicht am Peer selbst, und bleiben erhalten.
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null

	_peer = ENetMultiplayerPeer.new()
	var err: int = _peer.create_client(server_ip, PORT)
	if err != OK:
		push_error("[NetworkManager] create_client fehlgeschlagen (Error %d) – Retry in %.0fs" % [
			err, RECONNECT_INTERVAL])
		_reconnect_pending = true
		_reconnect_timer = RECONNECT_INTERVAL
		return

	multiplayer.multiplayer_peer = _peer

	# Signale nur beim ersten Aufruf verbinden (bleiben über Reconnects erhalten)
	if not _client_signals_connected:
		multiplayer.connected_to_server.connect(_on_connected_to_server)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)
		_client_signals_connected = true

	print("[NetworkManager] Verbinde mit %s:%d … (Versuch %d)" % [
		server_ip, PORT, reconnect_attempts])


## Sendet die eigene Position an den Server; der Server leitet sie weiter.
## Wird von xr_player.gd und fps_player.gd jeden Frame aufgerufen.
## Controller (optional, nur XR): hands = [links_pos, links_rot, rechts_pos, rechts_rot]
## (Weltkoordinaten, Rotation als Euler), hands_mask = Bit 0 links, Bit 1 rechts getrackt.
func send_player_state(body_pos: Vector3, head_pos: Vector3, head_rot: Vector3,
		hands: PackedVector3Array = PackedVector3Array(), hands_mask: int = 0) -> void:
	# Nur senden wenn wirklich mit einem Server verbunden (nicht im F6-Einzeltest)
	if not client_connected_flag:
		return
	_server_receive_state.rpc_id(1, multiplayer.get_unique_id(), body_pos, head_pos, head_rot, hands, hands_mask)


## Gibt den empfangenen Zustand an den Avatar weiter. Varianten ohne update_hands()
## (z. B. remote_avatar.gd) zeigen einfach keine Controller.
func _apply_state(avatar: Node, body_pos: Vector3, head_pos: Vector3, head_rot: Vector3,
		hands: PackedVector3Array, hands_mask: int) -> void:
	avatar.update_transform(body_pos, head_pos, head_rot)
	if avatar.has_method("update_hands"):
		avatar.update_hands(hands, hands_mask)


# ══════════════════════════════════════════════════════════════════
#  Interne RPC-Relay-Kette  (Client → Server → andere Clients)
# ══════════════════════════════════════════════════════════════════

## Läuft auf dem Server: Empfängt Positionen und leitet sie weiter.
@rpc("any_peer", "unreliable_ordered", "call_remote")
func _server_receive_state(
		sender_id: int,
		body_pos: Vector3,
		head_pos: Vector3,
		head_rot: Vector3,
		hands: PackedVector3Array,
		hands_mask: int) -> void:
	if not multiplayer.is_server():
		return
	# Server-eigenen Avatar aktualisieren (für Server-Viewport-Anzeige)
	if SceneManager.remote_avatars.has(sender_id):
		_apply_state(SceneManager.remote_avatars[sender_id], body_pos, head_pos, head_rot, hands, hands_mask)
	for peer_id: int in multiplayer.get_peers():
		if peer_id != sender_id:
			_client_receive_state.rpc_id(peer_id, sender_id, body_pos, head_pos, head_rot, hands, hands_mask)


## Läuft auf dem Client: Empfängt relayten State und aktualisiert Remote-Avatar.
## Remote-Avatare leben in SceneManager.remote_avatars (persistent über Szenenwechsel).
@rpc("authority", "unreliable_ordered", "call_remote")
func _client_receive_state(
		sender_id: int,
		body_pos: Vector3,
		head_pos: Vector3,
		head_rot: Vector3,
		hands: PackedVector3Array,
		hands_mask: int) -> void:
	if SceneManager.remote_avatars.has(sender_id):
		_apply_state(SceneManager.remote_avatars[sender_id], body_pos, head_pos, head_rot, hands, hands_mask)


# ── Spieler-Join/Leave-Benachrichtigungen ────────────────────────

## Server → alle bestehenden Clients: neuer Spieler beigetreten
@rpc("authority", "reliable", "call_remote")
func _notify_player_joined(peer_id: int) -> void:
	print("[NetworkManager] Spieler %d beigetreten." % peer_id)
	player_joined.emit(peer_id)


## Server → alle Clients: Spieler hat verlassen
@rpc("authority", "reliable", "call_remote")
func _notify_player_left(peer_id: int) -> void:
	print("[NetworkManager] Spieler %d hat verlassen." % peer_id)
	GameState.player_colors.erase(peer_id)
	player_left.emit(peer_id)


## Server → Clients: verbindliche Farbzuweisung für einen Spieler.
## Läuft auf Clients; der Server setzt seine eigene Farbe direkt.
@rpc("authority", "reliable", "call_remote")
func _rpc_set_player_color(peer_id: int, color: Color) -> void:
	GameState.set_color_for_id(peer_id, color)
	# Remote-Avatar aktualisieren falls bereits gespawnt
	if SceneManager.remote_avatars.has(peer_id):
		SceneManager.remote_avatars[peer_id].peer_id = peer_id  # re-triggert _apply_color()
	# Eigener Self-Avatar aktualisieren wenn diese Farbe für uns selbst gilt
	if peer_id == GameState.my_id and is_instance_valid(SceneManager.self_avatar):
		SceneManager.self_avatar.peer_id = peer_id


## Client -> Server: neue Zufallsfarbe für den eigenen Avatar anfordern (z. B. Taste ax_touch).
## Der Server würfelt, speichert sie und verteilt sie an alle (auch an den Anfragenden).
func request_random_color() -> void:
	if client_connected_flag:
		_rpc_request_random_color.rpc_id(1)


@rpc("any_peer", "reliable", "call_remote")
func _rpc_request_random_color() -> void:
	if not multiplayer.is_server():
		return
	var id: int = multiplayer.get_remote_sender_id()
	var color := Color.from_hsv(randf(), randf_range(0.65, 1.0), randf_range(0.85, 1.0))
	GameState.set_color_for_id(id, color)
	if SceneManager.remote_avatars.has(id):
		SceneManager.remote_avatars[id].peer_id = id   # re-triggert _apply_color() auf dem Server
	_rpc_set_player_color.rpc(id, color)


# ── Server-seitige Callbacks ─────────────────────────────────────

func _on_peer_connected(id: int) -> void:
	print("[Server] Peer verbunden: %d" % id)

	# Server weist Farbe zu und ist die einzige Autorität dafür.
	# Dadurch sehen alle Clients denselben Spieler in derselben Farbe.
	var color: Color = GameState.get_color_for_id(id)

	var all_peers: Array = multiplayer.get_peers()

	# Alle bestehenden Clients über den Neuen informieren
	for peer_id: int in all_peers:
		if peer_id != id:
			_notify_player_joined.rpc_id(peer_id, id)

	# Den Neuen über alle bestehenden Clients informieren + deren Farben
	for peer_id: int in all_peers:
		if peer_id != id:
			_notify_player_joined.rpc_id(id, peer_id)
			# Farbe des bestehenden Spielers an den Neuen senden
			_rpc_set_player_color.rpc_id(id, peer_id, GameState.player_colors[peer_id])

	# Farbe des Neuen an alle bestehenden Clients senden
	_rpc_set_player_color.rpc(id, color)

	player_joined.emit(id)  # Für Server-eigene Listener (Logging)


func _on_peer_disconnected(id: int) -> void:
	print("[Server] Peer getrennt: %d" % id)
	_notify_player_left.rpc(id)
	GameState.player_colors.erase(id)
	player_left.emit(id)


# ── Client-seitige Callbacks ─────────────────────────────────────

func _on_connected_to_server() -> void:
	client_connected_flag = true
	reconnect_attempts = 0
	GameState.my_id = multiplayer.get_unique_id()
	print("[Client] Verbunden! Eigene ID: %d" % GameState.my_id)
	client_connected.emit()


func _on_connection_failed() -> void:
	push_warning("[NetworkManager] Verbindung zu %s:%d fehlgeschlagen. Retry in %.0fs (Versuch %d) …" % [
		server_ip, PORT, RECONNECT_INTERVAL, reconnect_attempts])
	_reconnect_pending = true
	_reconnect_timer = RECONNECT_INTERVAL


func _on_server_disconnected() -> void:
	client_connected_flag = false
	GameState.my_id = 0
	print("[NetworkManager] Verbindung zum Server getrennt. Reconnect in %.0fs …" % RECONNECT_INTERVAL)
	client_disconnected.emit()   # SceneManager räumt Remote-Avatare auf
	_reconnect_pending = true
	_reconnect_timer = RECONNECT_INTERVAL
