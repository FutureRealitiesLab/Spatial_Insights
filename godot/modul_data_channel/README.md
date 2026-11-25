# modul_data_channel

Verteilt große Datenframes vom Server an alle Clients über einen eigenen ENet-Kanal.
Das Modul kennt keinen Dateninhalt und hängt nur von Godots Multiplayer-API ab (Server = Peer-ID 1, wie in Situs Core).
Es ist als Autoload `DataChannel` gedacht und kann später unverändert nach `addons/situs_core/modules/modul_data_channel/` verschoben werden. Dort muss nur das Plugin den Autoload eintragen.

## Benutzung

```gdscript
# Server
DataChannel.publish("kanalname", {"beliebig": 1}, bytes)        # roh
DataChannel.publish("kanalname", meta, bytes, true)             # mit zstd-Kompression

# Client
DataChannel.received.connect(func(channel, meta, bytes, server_time_ms): ...)
```

`publish()` löst auf dem Server selbst kein `received` aus. Wer die Daten dort auch braucht, verarbeitet sie direkt.

## Verhalten

| Punkt | Umsetzung |
|-------|-----------|
| Eigener Kanal | `TRANSFER_CHANNEL = 1`, getrennt vom normalen RPC-Verkehr (Avatar-Posen laufen auf Kanal 0) |
| Zuverlässigkeit | `reliable`, damit Frames vollständig ankommen. Die Flusskontrolle verhindert einen Rückstau |
| Flusskontrolle | Je Client und Kanal sind höchstens `frames_in_flight` Frames (Standard 2, Projekt-Setting `sim/frames_in_flight`) ohne Ack unterwegs. Ist das Fenster voll, gewinnt der neueste Frame, ältere werden ersetzt (`stats.skipped`) |
| Ack verloren | Nach `ACK_TIMEOUT_MS` (1,5 s) darf erneut gesendet werden |
| Late Join | Ein neuer Client bekommt den letzten Frame jedes Kanals |
| Kompression | Optional zstd auf dem Server, der Client entpackt automatisch |
| Neue Datenquelle | `clear_all()` verwirft gespeicherte Frames, damit späte Clients nichts Veraltetes bekommen |

Statistik: `DataChannel.stats` (Server: veröffentlicht, gesendet, ersetzt, Bytes mit und ohne Kompression) und `DataChannel.client_stats` (Client: Frames, Bytes).

## Grenzen

- Ein Kanal ist kein Streaming mit Jitter-Puffer. Der Frame trägt `server_time_ms` (Server-Uhr), ein Puffer auf den Clients ist noch nicht umgesetzt.
- Mehrere Kanäle teilen sich einen ENet-Kanal. Ein großer Frame blockiert dort kurz die anderen.
- Auf WLAN ist die Frame-Größe der Engpass. Kompression und kleinere Felder helfen, siehe `docs/plan.md`.
