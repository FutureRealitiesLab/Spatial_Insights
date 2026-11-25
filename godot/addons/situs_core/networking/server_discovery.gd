extends Node

## server_discovery.gd – Findet Situs-Server im lokalen Netz.
##
## Server:  hört auf DISCOVERY_PORT und antwortet auf jede Suchanfrage direkt an den
##          Absender mit Rechnername, ENet-Port und Projektname.
## Client:  schickt die Anfrage per UDP-Broadcast und sammelt die Antworten in `servers`
##          (IP → Info). Nur Server desselben Projekts werden aufgenommen. Die Liste ist
##          auch die Grundlage für eine spätere Serverauswahl in VR.
##
## Es genügt Broadcast hin und eine normale Antwort zurück. Android braucht dafür keinen
## Multicast-Lock. Am Server-PC muss eingehend UDP DISCOVERY_PORT erlaubt sein.

## Ein neuer Server hat geantwortet.
signal server_found(ip: String, info: Dictionary)

const DISCOVERY_PORT: int = 7778
const QUERY := "SITUS?1"
const REPLY := "SITUS!1"
const QUERY_INTERVAL: float = 0.5

## IP → {name, port, project}
var servers: Dictionary = {}

var _udp: PacketPeerUDP = null
var _responding: bool = false
var _searching: bool = false
var _timer: float = 0.0
var _game_port: int = 7777


## Server: auf Suchanfragen antworten.
func start_responding(game_port: int) -> void:
	stop()
	_game_port = game_port
	_udp = PacketPeerUDP.new()
	var err := _udp.bind(DISCOVERY_PORT, "0.0.0.0")
	if err != OK:
		push_warning("[Discovery] Port %d nicht frei (Error %d), Server ist nicht auffindbar." % [DISCOVERY_PORT, err])
		_udp = null
		return
	_responding = true
	print("[Discovery] Antworte auf Suchanfragen, UDP %d" % DISCOVERY_PORT)


## Client: nach Servern suchen, bis stop() gerufen wird.
func start_searching() -> void:
	stop()
	servers.clear()
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	var err := _udp.bind(0, "0.0.0.0")
	if err != OK:
		push_warning("[Discovery] UDP-Socket nicht möglich (Error %d)" % err)
		_udp = null
		return
	_searching = true
	_timer = 0.0


func stop() -> void:
	_responding = false
	_searching = false
	if _udp != null:
		_udp.close()
		_udp = null


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if _udp == null:
		return
	if _searching:
		_timer -= delta
		if _timer <= 0.0:
			_timer = QUERY_INTERVAL
			_send_query()
	while _udp != null and _udp.get_available_packet_count() > 0:
		var text := _udp.get_packet().get_string_from_utf8()
		var ip := _udp.get_packet_ip()
		var port := _udp.get_packet_port()
		if _responding and text == QUERY:
			_udp.set_dest_address(ip, port)
			_udp.put_packet((REPLY + JSON.stringify(_own_info())).to_utf8_buffer())
		elif _searching and text.begins_with(REPLY):
			_add_server(ip, text.substr(REPLY.length()))


func _own_info() -> Dictionary:
	var host := OS.get_environment("COMPUTERNAME")
	if host.is_empty():
		host = OS.get_environment("HOSTNAME")
	return {"name": host, "port": _game_port, "project": _project_name()}


func _project_name() -> String:
	return str(ProjectSettings.get_setting("application/config/name", ""))


func _add_server(ip: String, json: String) -> void:
	var info: Variant = JSON.parse_string(json)
	if not info is Dictionary or info.get("project", "") != _project_name():
		return
	var is_new := not servers.has(ip)
	servers[ip] = info
	if is_new:
		print("[Discovery] Server gefunden: %s (%s)" % [ip, info.get("name", "?")])
		server_found.emit(ip, info)


## Anfrage an alle: allgemeiner Broadcast und je lokaler Schnittstelle die Adresse x.y.z.255
## (Windows schickt 255.255.255.255 sonst nur über eine Netzwerkkarte).
func _send_query() -> void:
	var targets := {"255.255.255.255": true}
	for addr: String in IP.get_local_addresses():
		if "." in addr and not addr.begins_with("127.") and not addr.begins_with("169.254."):
			targets[addr.get_slice(".", 0) + "." + addr.get_slice(".", 1) + "." + addr.get_slice(".", 2) + ".255"] = true
	var packet := QUERY.to_utf8_buffer()
	for target: String in targets:
		if _udp.set_dest_address(target, DISCOVERY_PORT) == OK:
			_udp.put_packet(packet)
