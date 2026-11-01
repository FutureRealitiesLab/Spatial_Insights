# Plan: PC-Versionen (Client, Single Player, Server)

Stand 2026-11-01. Zielbild: eine Windows-App mit drei Einstiegen. Der Avatar ist überall derselbe wie beim VR-Client (`avatar_dynamic_cone`), Sprung auf der Leertaste.

## Die drei Varianten

| | Was | Heute | Fehlt |
|---|---|---|---|
| **PC-Client (FPS)** | Tritt einem Server im LAN bei, läuft mit WASD und Maus, sieht Daten und die anderen Avatare | Menü *Als Spieler starten* (`fps_player.gd`), Avatar wie VR, eigener Körper sichtbar | Sprung auf Leertaste ist noch ein Physiksprung, kein Boost-Sprung. IP nur aus den Project Settings, kein Eingabefeld. Kein Windows-Export. |
| **Single Player (Host)** | Server und Spieler in einer Instanz, andere können optional beitreten | Gibt es nicht. Der Server ist reiner Relay-Server ohne Spieler und ohne Avatar. | Host-Modus (siehe unten), Menüeintrag, Freeze-Taste |
| **Server only** | Server ohne Spieleransicht, Orbit-Kamera auf die Daten, Avatare der Clients sichtbar | Menü *Als Server starten* mit Orbit-Kamera und HUD | Nur Feinschliff: Windows-Export, Startparameter |

## Was für die Umsetzung gebraucht wird

### A. Boost-Sprung auf Leertaste (Situs-Core), klein bis mittel

- Boost-Logik aus `xr_player.gd` in eine gemeinsame Komponente ziehen (z. B. `player/jump_boost.gd`): Phasen, Kurve, Sperre in der Luft, Project Settings *Situs Core → Jump*.
- `fps_player.gd`: Leertaste startet den Boost statt `JUMP_VELOCITY`. Der Boost hebt nur den Kopf (`Head`, Kamera) an. Der Körper bleibt am Boden, also `get_floor_y()` wie im XR-Spieler. WASD läuft in der Luft weiter.
- Die Körpererkennung (Hocke, Hochspringen) und die B-Taste bleiben dem XR-Spieler vorbehalten.
- Auswirkung auf die anderen: keine, die Ringsäule streckt sich schon heute von Boden bis Kopf.

### B. Host-Modus: Server mit eigenem Spieler (Situs-Core), größter Posten

Problem: Der Server hat Peer-ID 1 und spielt nicht mit. Spieler-IDs, Farben und Positionsweitergabe gehen von Clients aus.

Vorschlag: `GameState.mode` bleibt `SERVER`, dazu ein Flag `host_player` (statt eines vierten Modus, denn rund 15 Stellen prüfen auf `SERVER` und sollen es weiter tun). Änderungen:

- `NetworkManager`: Der Server meldet beitretenden Clients die ID 1 als Spieler (`_notify_player_joined`, Farbe für ID 1) und gibt dem Host-Spieler einen Sendeweg (`send_player_state` verteilt direkt per `_client_receive_state` an alle Peers, ohne Umweg). `my_id` des Hosts ist 1.
- `SceneManager`: Ort, an dem bisher `mode != SERVER` über lokalen Spieler und Eigenavatar entscheidet (`_spawn_local_player`, `start()`, `_load_scene_local`, `on_team_scene_ready`), muss den Host-Spieler zulassen. Statt der ServerCamera zählt dann die FPS-Kamera.
- `main.gd` und `main.tscn`: Menüeintrag *Einzelspieler (Server + Spieler)*. Der Host öffnet den Port 7777 (andere dürfen beitreten).
- `SimulationRelay` (Spatial Insights): braucht nichts. Die Rolle ist Server, Daten werden lokal angezeigt und an Clients verteilt.
- Optionaler Übersichtsmodus: Taste, die zwischen FPS-Ansicht und Orbit-Kamera umschaltet.

### C. Freeze-Taste verschieben (Spatial Insights), klein

Freeze liegt heute auf der Leertaste (nur Server). Weil die Leertaste im Host-Modus springt, wechselt Freeze auf `F`. Der Button am Server bleibt.

### D. PC-Client verbessern, klein bis mittel

- Eingabefeld für die Server-IP im Menü, zuletzt benutzten Wert in `user://` merken (bisher nur Project Setting).
- Später: automatische Server-Suche im LAN (Todo in Situs Core), dann entfällt das Feld als Standard.
- Anzeige im Spiel: Verbindungsstatus ist über `NetInfoBoard` und `NetDiag` schon da.

### E. Windows-Export und Startparameter, mittel

- Export-Preset *Windows* mit einer Exe und dem Menü als Standard. Windows-Export-Vorlagen installieren (siehe `docs/INSTALL.md`, Punkt steht schon im Plan).
- Startparameter zum Überspringen des Menüs: `--server`, `--host`, `--client=<IP>` (über `OS.get_cmdline_user_args()`), damit z. B. der Server-PC per Verknüpfung direkt startet.
- **XR am PC abschalten:** Das Projekt hat `openxr/enabled=true`. Läuft am PC SteamVR oder ein anderes OpenXR-Runtime, könnte die App unerwartet in den XR-Modus gehen. Dafür im PC-Preset `xr/openxr/enabled` per Feature-Override auf aus setzen (oder Startparameter `--xr-mode off`).
- Rendering: Compatibility-Renderer reicht, VRS wird am PC schon in `main.gd` abgeschaltet.

### F. Avatar-Gleichheit, bereits erfüllt, kleine Lücken

- Alle sehen denselben Avatar (Ringe, Kopfkugel mit Brillen-Würfel, Farbe vom Server).
- FPS-Spieler haben keine Controller: die Quader bleiben bei ihnen ausgeblendet (Tracking-Maske 0). Das ist gewollt.
- Der Kopf des FPS-Spielers sitzt auf 1,6 m. Wenn die Augenhöhe einstellbar sein soll, kommt ein Setting dazu.

## Reihenfolge

1. A: Boost-Sprung auf Leertaste (kleine Änderung, sofort testbar zusammen mit VR-Clients).
2. C: Freeze auf `F`.
3. D + E: IP-Feld, Startparameter, Windows-Export, XR am PC aus. Damit sind PC-Client und Server-only fertig.
4. B: Host-Modus (größter Eingriff, eigene Testrunde mit einer Brille).

## Offene Entscheidungen

1. Freeze auf `F` ok?
2. Soll der Single Player den Port 7777 öffnen (andere können beitreten) oder rein lokal laufen?
3. Soll der Host zwischen FPS-Ansicht und Orbit-Übersicht umschalten können?
4. Augenhöhe der FPS-Spieler fest 1,6 m oder einstellbar?
5. Test: nächste Session zusammen mit Boost-Sprung und Freeze auf den Brillen.
