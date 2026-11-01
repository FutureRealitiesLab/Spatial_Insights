# Changelog

Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/). Der Branch `feature/situs-core` ist am 2026-10-30 nach `main` gemergt und gelöscht.

## [Unreleased]

### Hinzugefügt
- PC-Versionen (Details: `docs/plan_pc_versionen.md`): Windows-Export-Preset `PC` (eine Exe mit Startmenü), OpenXR am PC per Feature-Override aus (`openxr/enabled.pc=false`), Einzelspieler als zweite, minimierte Server-Instanz, MATLAB-Empfang beim lokalen Server nur an 127.0.0.1. Freeze liegt jetzt auf der Taste **F** (die Leertaste ist der Boost-Sprung der PC-Spieler).
- Freeze: Leertaste oder Button am Server hält die Simulation für alle Brillen an (`SimulationRelay.set_frozen()`, RPC, Anzeige „EINGEFROREN“).
- Situs Core 1.1.0 als Plugin (`godot/addons/situs_core/`, git subtree von `dist`). Hauptszene ist `main.tscn` des Plugins, die Simulation ist die Standardszene (`situs_core/default_scene`).
- Datenkanal `godot/modul_data_channel/`: ENet-Transferkanal 1, Ack-Flusskontrolle je Client, neuester Frame gewinnt, Late-Join-Cache, optional zstd.
- `godot/simulation_relay.gd`: Rollen Server, Client und Direct. Einstellungen `sim/udp_port` (4242) und `sim/udp_on_clients`.
- Serveransicht mit Maus: links drehen, rechts verschieben, Rad zoomen.
- `docs/INSTALL.md` und `tools/setup_android.ps1` (Einrichtung und Export), Firewall-Hinweise für UDP 7777 und 4242.
- `docs/plan.md` mit Umsetzungsstand und TODO-Liste, `docs/ai-chat-log.md`, dieser Changelog.

### Geändert
- Umbenennung MatLab_CommTest → **Spatial Insights**: Repo `Spatial_Insights`, Projekt- und App-Name, APK-Namen `spatial_insights_*.apk`, `package/unique_name` `org.spatialinsights.viewer` (alte App auf den Brillen deinstallieren).
- Raum 4 × 8 m, Rotation `-90` (entspricht der alten Content-Drehung 90, Vorzeichen auf der Brille noch zu prüfen) über die Situs-Project-Settings.
- Server-IP steht in `project.godot` (`situs_core/network/server_ip`), nicht in einer Datei.
- Presets: `Vive_LBE` als Run-Ziel, `export_presets.cfg` im Godot-4.7-Format neu geschrieben.
- README und Projektstand aktualisiert.

### Entfernt
- `godot-stephan/` (Altlast).

### Meilenstein 2026-10-30
- Auf Hardware bestätigt: APK läuft auf der Brille, Verbindung zum Server über die LAN-IP, MATLAB-Daten kommen im Netzwerk an, die zweite Brille ist sichtbar.

## Vorher
- Alter Betrachter (`main.tscn`, `udp_receiver.gd`, `scene_view.gd`, Shader) mit SteamVR und Standalone auf der Vive Focus Vision. Er bleibt im Repo.
