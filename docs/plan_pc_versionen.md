# Plan: PC-Versionen (Client, Single Player, Server)

Stand 2026-11-01. Zielbild: eine Windows-App mit drei Einstiegen. Der Avatar ist überall derselbe wie beim VR-Client (`avatar_dynamic_cone`), Sprung auf der Leertaste.

## Die drei Varianten

| | Was | Heute | Fehlt |
|---|---|---|---|
| **PC-Client (FPS)** | Tritt einem Server im LAN bei, läuft mit WASD und Maus, sieht Daten und die anderen Avatare | Menü *Als Spieler starten* (`fps_player.gd`), Avatar wie VR, eigener Körper sichtbar | Sprung auf Leertaste ist noch ein Physiksprung, kein Boost-Sprung. IP nur aus den Project Settings, kein Eingabefeld. Kein Windows-Export. |
| **Single Player** | Server und Spieler lokal, beides als zwei Instanzen derselben Exe (Server localhost, Client localhost) | Menü hat *Server* und *Spieler lokal*, aber keinen Einstieg, der beides startet | Menüeintrag *Einzelspieler*, Prozess starten und beenden |
| **Server only** | Server ohne Spieleransicht, Orbit-Kamera auf die Daten, Avatare der Clients sichtbar | Menü *Als Server starten* mit Orbit-Kamera und HUD | Nur Feinschliff: Windows-Export, Startparameter |

## Was für die Umsetzung gebraucht wird

### A. Boost-Sprung auf Leertaste (Situs-Core), klein bis mittel

- Boost-Logik aus `xr_player.gd` in eine gemeinsame Komponente ziehen (z. B. `player/jump_boost.gd`): Phasen, Kurve, Sperre in der Luft, Project Settings *Situs Core → Jump*.
- `fps_player.gd`: Leertaste startet den Boost statt `JUMP_VELOCITY`. Der Boost hebt nur den Kopf (`Head`, Kamera) an. Der Körper bleibt am Boden, also `get_floor_y()` wie im XR-Spieler. WASD läuft in der Luft weiter.
- Die Körpererkennung (Hocke, Hochspringen) und die B-Taste bleiben dem XR-Spieler vorbehalten.
- Auswirkung auf die anderen: keine, die Ringsäule streckt sich schon heute von Boden bis Kopf.

### B. Einzelspieler als zwei Instanzen (Entscheidung 2026-11-01)

Statt den Server um einen eigenen Spieler zu erweitern (Host-Modus), startet der Einzelspieler zwei Instanzen derselben Exe: Server auf localhost und Client auf localhost. Das Menü hat *Server* und *Spieler lokal* schon, es fehlt nur ein Button *Einzelspieler*, der beides zusammen startet:

1. Menüeintrag *Einzelspieler* (oder `--solo`).
2. Zweiter Prozess im Servermodus: `OS.create_process(OS.get_executable_path(), ["--server"])`.
3. Nach ca. 1 s (Server lauscht) verbindet sich die erste Instanz als Client mit 127.0.0.1 und startet den FPS-Spieler.
4. Beim Beenden des Spieler-Fensters wird der Server-Prozess mitbeendet (Prozess-ID merken).

Das Serverfenster ist das Bedienfeld (Freeze, Szene weiter, Orbit-Übersicht, Status). Andere können dem Einzelspieler beitreten, weil der Server auf 7777 lauscht.

Der Host-Modus (ein Fenster, Server mit eigenem Spieler, Peer-ID 1 als Spieler, `GameState.host_player`, Änderungen in `NetworkManager`, `SceneManager`, `main.gd`) bleibt als spätere Option und wird erst gebaut, wenn zwei Fenster stören.

### C. Freeze-Taste verschieben (Spatial Insights), klein

Freeze liegt heute auf der Leertaste (nur Server). Weil die Leertaste im Host-Modus springt, wechselt Freeze auf `F`. Der Button am Server bleibt.

### D. Menü: IP-Feld, Button Lokal, Einzelspieler (Spatial Insights), klein bis mittel

- Eingabefeld für die Server-IP, zuletzt benutzten Wert in `user://` merken.
- Button *Lokal* (setzt 127.0.0.1), Button *Verbinden*.
- Button *Einzelspieler* (siehe B).
- Später: automatische Server-Suche im LAN (Todo in Situs Core), dann ist das Feld nur noch die Alternative.

### E. Ein Windows-Export mit Startmenü, mittel

- Das Startmenü gibt es schon (`main.tscn`, erscheint ohne Headset). Es fehlt der **Windows-Export**: Preset *Windows* mit dem Menü als Start. Windows-Export-Vorlagen installieren (`docs/INSTALL.md`).
- Startparameter zum Überspringen des Menüs (optional): `--server`, `--client=<IP>`, `--solo`.
- **XR am PC abschalten:** Das Projekt hat `openxr/enabled=true`. Läuft am PC SteamVR, könnte die App unerwartet in den XR-Modus gehen. Im PC-Preset `xr/openxr/enabled` per Feature-Override ausschalten (oder `--xr-mode off`).
- Rendering: Compatibility, VRS wird am PC in `main.gd` abgeschaltet.
- Firewall: UDP 7777 (Server) und UDP 4242 (MATLAB).

### F. Avatar-Gleichheit, bereits erfüllt, kleine Lücken

- Alle sehen denselben Avatar (Ringe, Kopfkugel mit Brillen-Würfel, Farbe vom Server).
- FPS-Spieler haben keine Controller: die Quader bleiben bei ihnen ausgeblendet (Tracking-Maske 0). Das ist gewollt.
- Der Kopf des FPS-Spielers sitzt auf 1,6 m. Wenn die Augenhöhe einstellbar sein soll, kommt ein Setting dazu.

## Reihenfolge

1. A: Boost-Sprung auf Leertaste (ohne Blickrichtung, nur Kopfhöhe).
2. C: Freeze auf `F`.
3. D + E: Menü (IP-Feld, Lokal, Einzelspieler), Startparameter, Windows-Export, XR am PC aus. Damit sind alle drei Varianten nutzbar.
4. Test mit einer Brille: PC-Client und Brille sehen sich, Sprung, Freeze.
5. Später und nur bei Bedarf: Host-Modus in einem Fenster.

## Entschieden (2026-11-01)

- Sprung nur auf Leertaste, ohne extra nach oben zu schauen.
- Einzelspieler als zwei Instanzen (Server localhost, Client localhost).
- Freeze auf `F`.
- IP-Feld mit Button *Lokal*.
- Ein Windows-Export mit Startmenü (das Menü existiert schon).

## Offen

1. Augenhöhe der FPS-Spieler fest 1,6 m oder einstellbar?
2. Serverfenster beim Einzelspieler sichtbar oder minimiert?
3. Port 7777 beim Einzelspieler für andere offen (so voreingestellt) oder abschaltbar?

Ausführliche Logik mit Ablauf je Variante: Notion-Unterseite *PC features* unter *Spatial Insights*.
