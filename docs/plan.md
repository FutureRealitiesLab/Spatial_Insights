# Plan: Spatial Insights (ehemals MatLab_CommTest): Architektur MATLAB → Server-PC → Brillen (WLAN)

> **Umbenennung (2026-10-30):** Das Repo heißt jetzt `Spatial_Insights` (Forschungsvorhaben Spatial Insights, HTW Berlin). Aus dem Kommunikationstest ist das Produkt geworden.

> **Status (2026-10-30): Meilenstein erreicht.** MATLAB-Daten laufen über den Server im Netzwerk zu den Brillen, und die Brillen sehen einander. Offen sind Messungen mit mehreren Brillen und Feinschliff (TODO-Liste unten).
>
> Umsetzung seit 2026-10-30 auf `main` (Branch `feature/situs-core` gemergt und gelöscht). Die Architekturempfehlung unten ist umgesetzt. Offene Arbeit steht in der [TODO-Liste](#todo-liste) am Ende.

## Kontext

Ziel: Colocated-VR auf Basis von Situs Core (Nachfolger des Templates Hyper-Irrealismus III; Godot 4.7, GL Compatibility Renderer, ENet UDP Port 7777, bis 8 Clients, HTC Vive Focus Vision / Focus 3; Meta Quest wird nicht mehr unterstützt, Pico 4 Ultimate später). Der MATLAB-Rechner und der Server-PC hängen per Kabel am Router, die Brillen per WLAN.

Frage: Wie kommen die Simulationsdaten zu den Brillen, und was schickt der Server: fertige Textur oder Rohdaten?

Gelesen wurden die Notion-Seite "Technische Basis: Hyper-Irrealismus III Template", README und ARCHITECTURE.md des Repos sowie `network_manager.gd` und `game_state.gd`. Der Server ist dort reines Avatar-Relay (~20 Hz, `unreliable_ordered`, ENet). Nicht gelesen werden konnte `SITUS_CORE_REFACTOR_PLAN_v2.md` (signierte Notion-Datei, HTTP 403).

## Empfehlung

**Kabel-Hop reich, WLAN-Hop budgetiert. Der Server ist die einzige Datenquelle, die Brillen rendern selbst.**

```
MATLAB (Kabel) --UDP, typisiertes Protokoll (`PROTOCOL.md` in der MATLAB-Sammlung, HTW-Cloud), unverändert--> Server-PC (Kabel)
   Server: Empfang + Frame-Zusammenbau (bestehende Logik), optional Downsampling/Kompression
   Server --ENet, eigener Kanal, Ack-Flusskontrolle, uint8-Skalarfeld (+Config)--> Brillen (WLAN)
   Brille: Textur (ImageTexture3D R8) + Raymarch-Shader + Interpolation lokal
```

### Fertige Textur oder Rohdaten?

Die "Textur" ist das Rohdatenfeld: ein 3D-Skalarfeld mit 1 Byte pro Voxel. **Das Skalarfeld wird weitergeleitet, Farbe, Transferfunktion und Raymarching laufen auf der Brille.**

- Nicht senden: vorgefärbte RGBA-Texturen (4× größer, Colormap und Schwelle nicht mehr interaktiv) und keine Video-Streams (blickpunktabhängig pro Auge, Latenz).
- Das Volumen muss ohnehin pro Auge auf der Brille gerendert werden. Der Server kann das nicht vorab erledigen.

### Warum der Server als Relay und nicht MATLAB direkt an alle Brillen

- Ein MATLAB-`write` kostet ~10 ms je Datagramm, 8 Empfänger wären 8× teurer. MATLAB kennt keine Client-IPs, Reconnects oder späte Beitritte.
- Broadcast und Multicast im WLAN laufen mit niedrigster Rate, ohne ACK und werden oft geblockt. Sinnvoll nur mit AP-Multicast-zu-Unicast-Umsetzung.
- Der Server ist im Template schon zentral (Peer-IDs, Reconnect, Szenensignal) und kann die Daten server-autoritativ halten (im Notion als Phase-2-Punkt vorgesehen).

## Bandbreite

WLAN ist ein geteiltes Medium, und der Server sendet an jede Brille einzeln.

| Feld (uint8) | KB/Frame | Hz | je Brille | 8 Brillen gesamt |
|---|---:|---:|---:|---|
| 32³ | 32 | 20 | 0,6 MB/s | 5 MB/s (~41 Mbit/s) |
| 64³ | 256 | 10 | 2,6 MB/s | 21 MB/s (~168 Mbit/s), grenzwertig |
| 64³ | 256 | 20 | 5,1 MB/s | 41 MB/s (~330 Mbit/s), unrealistisch |

Hebel: Auflösung senken, Sende-Hz senken (die Brille interpoliert lokal), zstd-Kompression auf dem Server (`PackedByteArray.compress`, Felder komprimieren oft 2–5×), später Delta oder ROI. Der Kabel-Hop MATLAB → Server kann hochauflösend und schnell bleiben, der Server dezimiert für die WLAN-Strecke.

## Designpunkte für die spätere Umsetzung

1. **Eigener ENet-Transferkanal** für Volumendaten, damit Kopf- und Avatar-Posen (Kanal 0, `unreliable_ordered`) nicht hinter 256-KB-Frames hängen.
2. **Ack-basierte Flusskontrolle je Client:** Der nächste Frame wird erst gesendet, wenn der Client den vorigen bestätigt hat. Sonst wächst der Rückstau bei langsamen Brillen. Es gilt "neuester Frame gewinnt", ältere werden verworfen.
3. **Serverzeit im Frame** und ein Jitter-Puffer von einem Frame auf den Brillen, damit alle nahezu dasselbe Bild zeigen (Co-located: gemeinsame Realität).
4. **Late Join:** Bei `peer_connected` werden der letzte Frame je Magic und die Session-ID geschickt. Das neue Protokoll kennt keine Konfigurationspakete mehr; Magic und `vspan` stehen im Frame-Header, Colormap und Platzierung entscheidet die Brille bzw. die Szene. Die Session-ID erkennt einen MATLAB-Neustart, der Server setzt dann seinen Zustand und die Frame-Zähler der Clients zurück.
5. **Renderer-Risiko (GL Compatibility, Focus Vision):** Das Raymarching ist der teuerste Teil (Pixel × Schritte × 2 Augen, plus zweites Sample für die Interpolation). Schritte auf ca. 24–32, frühes Abbrechen, Render-Scale wie im Template. Float32-Texturen mit linearem Filter sind auf Mobile nicht garantiert, daher **R8 (uint8) verwenden**. Shader und `ImageTexture3D.update()` früh auf der Zielhardware testen.
6. **WLAN:** eigenes 5/6-GHz-Netz, WiFi-6-AP, Energiesparmodus der Brillen aus, kein anderer Verkehr.
7. **Platzierung im gemeinsamen Raum:** Die Volumen-Transform steht in der Szene (`scene_hooks.gd` / `scene_info.cfg`), nicht im Datenstrom.

## Später umzusetzen (nicht jetzt)

- Empfangslogik aus `godot/udp_receiver.gd` in eine wiederverwendbare `FrameSource` auslagern (Server: UDP-Quelle, Client: ENet-Quelle). Der Empfänger liefert bereits fertige Frames als Signal `frame_received(magic, info, payload)`, `godot/scene_view.gd` stellt sie dar; beide sind schon getrennt.
- Das Protokoll ist nicht mehr nur ein Volumen: Skalar-, Vektorfelder, Partikel und Automaten haben andere Datenmengen (Partikel `float32`, Automaten bitgepackt). Bandbreitentabelle und Downsampling gelten für S/V, für P und C getrennt betrachten.
- Autoload `SimulationRelay` im Hyper-Irrealismus-Projekt.
- Szene `volume_display.tscn` (Volumen-Mesh + Shader), einbindbar über `scene_info.cfg`.
- Eingebauter Testdaten-Generator in Godot, damit sich der Datenpfad ohne MATLAB prüfen lässt.

## Messcheckliste (wenn Hardware da ist)

1. Server + 1 Brille, dann 4 und 8 Brillen.
2. Kennzahlen je Brille: Frame-Rate der Daten, verworfene Frames, RTT, GPU-Zeit des Raymarchings.
3. Zielwerte prüfen: Volumen mit 32³ bei 20 Hz und 64³ bei 10 Hz (mit Kompression) auf allen 8 Brillen stabil.


---

## Umsetzungsstand

Im Code vorhanden und per Headless-Test geprüft (Server + Late-Join-Client mit synthetischen UDP-Paketen):

- Situs Core 1.1.0 als Plugin (`godot/addons/situs_core/`, git subtree von `dist`), Hauptszene `main.tscn` des Plugins.
- Datenkanal `godot/modul_data_channel/`: ENet-Transferkanal 1, Ack-Flusskontrolle je Client, neuester Frame gewinnt, Late-Join-Cache, optional zstd.
- `godot/simulation_relay.gd`: Rollen Server / Client / Direct, UDP-Port `sim/udp_port` (4242), `sim/udp_on_clients`.
- Situs-Einstellungen in den Project Settings: Server-IP, Raumbreite und -länge (4 × 8 m), Rotation (`-90`).
- Server-Ansicht mit Maus: links drehen, rechts verschieben, Rad zoomen.
- Installation und Export: `docs/INSTALL.md`, `tools/setup_android.ps1`.

Auf echter Hardware bestätigt (2026-10-30): APK läuft auf der Brille, Verbindung zum Server über die LAN-IP (`situs_core/network/server_ip`), MATLAB-Daten kommen im Netzwerk an, die andere Brille ist sichtbar.

Auf der Brille bestätigt (2026-10-30, zweiter Test): Controller als Quader in Spielerfarbe, lineare Schleppe, Körpersprung. Freeze am Server getestet, läuft.

**Noch nicht geprüft:** Rotationsvorzeichen, Android-Override der IP, Betrieb mit 4 und 8 Brillen, Messwerte (Daten-Hz, RTT, GPU-Zeit), Freeze auf den Brillen, Sprungtaste B, Gefühl des überarbeiteten Boost-Sprungs.

## TODO-Liste

Reihenfolge = empfohlene Abarbeitung. Kästchen abhaken, wenn erledigt.

### 0. Test nächste Session

**Ergebnis Brillentest 2026-11-11** (3 Brillen, APK 1.261111.01, GoL-Demos):
- [x] Drei Brillen gleichzeitig funktionieren (mehr waren noch nicht verfügbar). Late Join funktioniert. Raumrotation ist korrekt.
- [x] Protokoll v2: alle Magics erscheinen, zwei Magics laufen gleichzeitig.
- [x] Boost-Sprung durch Hinknien und schnelles Aufstehen löst aus. Ringsäule lokal und bei den anderen korrekt. Lineare Schleppe gut. Controller in Spielerfarbe, blitzen auf.
- [x] Freeze funktioniert. Schild jetzt auf den vier Seitenflächen statt drehend in der Mitte, Button rechts oben.
- [ ] Sprungtaste: Profil `touch_controller`, es kommen nur `ax_touch`, `by_touch`, `trigger_click`, `grip_click`, `primary_click` an. Neuer Standard `trigger_click` testen.
- [ ] Spatial Box: Rahmen je Ebene aus dem Datensatz (neu), prüfen, ob er mit den Daten deckungsgleich ist.
- [ ] GoL-Demo2 (1500×1500, zwei Magics) ruckelt gelegentlich: Overlay-Werte (Frames/s, Verworfen, Relay gesendet/ersetzt) notieren, Rate in MATLAB begrenzen.
- [ ] PC-Versionen weiterhin ungetestet. 4 und 8 Brillen offen.

- [ ] **Boost-Sprung** (aus Situs Core, Details in dessen `docs/plan.md`): Körpersprung löst aus. Prüfen, ob der überarbeitete Verlauf (Wurf auf 4 m in 1,2 s, Sinken über 6,8 s, insgesamt rund 8 s) realistisch wirkt. Sprungtaste B löst nicht aus: beim Drücken zeigt ein Hinweis im Blickfeld den Namen der Taste, diesen in *Project Settings → Situs Core → Jump → Button* eintragen. Die genaue Flugzeit aus der Anforderung war abgeschnitten, 8 s sind angenommen.
- [ ] Zweite Brille: Ringsäule beim Sprung (Lücken, Ringanzahl), Körper bleibt am Boden.
- [ ] **Freeze** auf mehreren Brillen prüfen (Schild, Standbild, Late Join während Freeze).
- [ ] Neu exportieren: alle Brillen brauchen denselben Stand (RPC-Signatur geändert), alte App `org.matlabcommtest.viewer*` deinstallieren.

- [ ] **PC-Versionen testen** (`docs/plan_pc_versionen.md`): Windows-Export `PC`, Menü, Einzelspieler (Server minimiert, Beenden schließt ihn, MATLAB an 127.0.0.1), PC-Client mit IP-Feld, Sprung auf Leertaste, Freeze auf F, PC-Client und Brille sehen sich. Alles umgesetzt, nichts getestet.

### 0b. Plan nächste Session: Datenverteilung (Stand 2026-11-11)

**Befund aus dem Test mit 7 Brillen (GoL):** Bewegung und Rendering laufen flüssig, aber die Simulation ruckelt, weil zu wenige Frames ankommen. Paketverlust (ENet-Wert im Server-Fenster) teilweise über 12 %. Der Server hing dabei selbst per WLAN am Router, jedes Frame lief also zweimal durch die Luft. **Wichtig ist Geschwindigkeit, nicht Vollständigkeit:** Verlorene Frames sind egal, langsame Übertragung ist das Problem.

Heute: Der Server sendet jedes Frame einzeln an jede Brille (ENet, zuverlässig, ein Frame in der Luft bis zum Ack). Ein 281-KB-Frame (GoL 1500², 1 Bit pro Zelle) besteht aus rund 200 ENet-Fragmenten. Bei Verlust wird wiederholt, alles dahinter wartet. `demo2` sendet jeden Schritt doppelt (`C2s2` und `C2s3`).

Reihenfolge:

- [ ] **1. Hardware:** Server und MATLAB-PC per Kabel. Router: 5 GHz, breiter Kanal, Client-Isolation aus, am besten ein eigener Access Point nur für die Brillen. Router-Modell notieren (Multicast-Rate und "multicast to unicast" einstellbar?).
- [ ] **2. Messen mit Kabel:** GoL 500² und `demo2` mit 1, 3 und 7 Brillen. Pro Brille Verlust, RTT, ack, Frames/s, am Server "Out to clients". Wenn Verlust unter etwa 2 % und flüssig: nichts weiter nötig.
- [ ] **3. Schnelle Maßnahmen:** einstellbare Maximalrate am Server (`sim/max_hz`), Kugel und Torus aus einem Datensatz (einmal senden, zweimal darstellen).
- [ ] **4. Alternative ohne Empfangsbestätigung (am wenigsten Aufwand):** Das Ack und das "ein Frame gleichzeitig" fallen weg. Frames gehen unzuverlässig an alle (ENet unreliable oder UDP), der Server begrenzt nur die Rate. Pakete von etwa 1400 Byte, jedes trägt Frame-ID und Position. Zwei Varianten: (a) unvollständige Frames verwerfen, (b) fehlende Pakete als alte Streifen stehen lassen und nur Angekommenes in die Textur schreiben (kein Frame geht verloren, dafür kurz sichtbare Streifen). Bei 200 Fragmenten pro Frame und 12 % Verlust ist (a) ohne kleine Pakete chancenlos.
- [ ] **5. Änderungen statt Vollbild (Game of Life):** Pro Schritt ändern sich wenige Zellen. Unterschied zum letzten Frame (XOR) komprimiert viel besser, ab und zu ein komplettes Frame als Neustart. Hilft jedem Weg (Einzelstreams, Stream an alle).
- [ ] **6. Stream an alle (Broadcast oder Multicast):** Der Server sendet einmal, alle hören mit. Der Empfang mit Chunks existiert (`udp_receiver.gd`, Direktmodus). Der Server muss auf etwa 1400 Byte neu zerlegen (MATLAB sendet 65 KB). Steuerung (Freeze, Ansicht, Farben) und Late Join bleiben auf ENet. Einstellbar neben dem bisherigen Weg (`enet` oder `broadcast`), zuerst mit 2 Brillen testen. Risiken: Im WLAN läuft Broadcast und Multicast oft mit 6 Mbit/s ohne Wiederholung (bei 281 KB etwa 0,4 s pro Frame, schlechter als Einzelstreams). Sinnvoll nur, wenn der Router die Multicast-Rate erhöhen lässt oder Multicast in Einzelstreams mit Wiederholung umwandelt. Android filtert Multicast ohne Multicast-Lock (kleines Plugin), Broadcast kommt wahrscheinlich ohne durch (ungetestet).
- [ ] **7. Entscheidung** nach den Messungen aus 2 bis 5: Einzelstreams mit Kabel reichen, oder Punkt 4 (unzuverlässig) oder Punkt 6 (Stream an alle).

### 1. PC-Test mit echtem MATLAB

- [x] Server in Godot starten (F5, *Als Server starten*), in MATLAB `udpTest`: Volumen erscheint, Overlay (F3) zeigt Frames.
- [x] Zweite Instanz als Client (`127.0.0.1`): sieht dieselben Daten, Late Join nach laufendem Stream.
- [ ] MATLAB neu starten (neue Session-ID): Server und Client setzen sich zurück, kein Hängen.
- [ ] Mausnavigation auf der Serveransicht prüfen (Drehen, Verschieben, Zoomen).

### 2. Eine Brille

- [x] Setup-Skript auf dem Export-Rechner laufen lassen (`tools/setup_android.ps1`), APK mit Preset `Vive_LBE` exportieren und installieren.
- [x] Server-IP gesetzt, Firewall UDP 7777 (und 4242 bei MATLAB auf anderem Rechner) offen.
- [x] Brille verbindet sich, Avatar erscheint auf dem Server.
- [x] Volumen kommt über WLAN an. Kennzahlen notieren: Daten-Hz, verworfene Frames, RTT.
- [ ] **Rotation prüfen:** `room/rotation_deg = -90` entspricht der alten Content-Drehung `90`. Stimmt die Ausrichtung nicht, Vorzeichen umkehren.
- [ ] Optional: Android-Override für die Server-IP (*Override For… → android*) testen.
- [ ] GPU-Zeit des Raymarchings im Compatibility-Renderer messen.

### 3. Mehrere Brillen

- [ ] 2, dann 4, dann 8 Brillen. Je Stufe: Daten-Hz, verworfene Frames, RTT und GPU-Zeit je Brille.
- [ ] Zielwerte aus der Messcheckliste: 32³ bei 20 Hz und 64³ bei 10 Hz (mit Kompression) stabil auf allen Brillen.
- [ ] Brille zur Laufzeit beitreten und verlassen (Late Join, Reconnect).
- [ ] Alle Brillen zeigen nahezu dasselbe Bild (Sichtprüfung nebeneinander).
- [ ] WLAN-Setup dokumentieren (eigenes 5/6-GHz-Netz, Energiesparmodus aus).

### 4. Verbesserungen nach den Messungen

- [ ] Bei Bedarf Jitter-Puffer von einem Frame (Serverzeit liegt schon im Frame).
- [ ] Bei Bedarf Bandbreite senken: Auflösung, Sende-Hz, Kompression, später Delta oder ROI.
- [ ] Verhalten großer reliable Frames bei WLAN-Verlusten beobachten, ggf. Frame-Timeout anpassen (`ACK_TIMEOUT_MS`).
- [ ] Partikel und Automaten (Magic P und C) gesondert auf Datenmenge prüfen.

### 5. Aufräumen und Veröffentlichen

- [ ] Entscheiden, ob die geänderte `godot/export_presets.cfg` committet wird.
- [x] Branch `feature/situs-core` nach `main` gemergt (2026-10-30, Fast-Forward) und gelöscht.
- [ ] Tags `v1.0.0` und `v1.1.0` im Situs-Repo setzen und `dist` neu bauen (nach den Tests).
- [ ] MATLAB-Simulationen als `demo/`-Ordner ins Repo holen (bisher in der HTW-Cloud, `matlab/` wurde aus dem Repo entfernt).

### 6. Situs-Seite (siehe `situs-core/docs/plan.md`)

- [ ] `modul_data_channel` als Modul ins Situs-Repo übernehmen.
- [ ] `sim/*`-Einstellungen im Editor sichtbar machen.

### 7. Neue Module für Situs, hier einzubinden

Die Module entstehen im Repo Situs-Core (`docs/plan.md` dort) und werden hier als Funktion für die Simulationsdaten eingebunden.

- [x] Avatar-Paket aus Situs übernommen (per Subtree von `dist`): Kopfkugel mit Brillen-Würfel, Controller als Quader in Spielerfarbe, lineare Schleppe, Farbverlauf, Boost-Sprung. Offen: Explodierender Ring (Situs-Plan).
- [ ] **Simulationskörper greifen, skalieren, rotieren und repositionieren.** Transformation muss für alle Brillen synchron sein und darf den Datenstrom von MATLAB nicht stören.
- [ ] **Kollaboratives Sketching** im selben Raum, Striche an alle Brillen.
- [ ] Danach: `git subtree pull` auf den neuen Situs-Stand.

### 8. Branches

- [x] `main` ist auf dem Stand von Situs Core. Stephans Altstand (`godot-stephan/`) ist entfernt und nur noch in der Git-Historie.

### 9. Zwei Varianten: VR-Multiplayer und PC-Singleplayer

> Ausgearbeitet in [docs/plan_pc_versionen.md](plan_pc_versionen.md): drei PC-Einstiege (Client mit FPS, Single Player als Host, Server only), Avatar wie VR, Sprung auf Leertaste, Reihenfolge und offene Entscheidungen. Die Punkte hier gelten weiter, sind dort aber konkretisiert.

Entscheidung (2026-10-30): **ein Projekt, ein `main`, zwei Einstiege.** Keine getrennten Branches oder Kopien, damit Bugfixes nicht doppelt nötig sind.

- Gemeinsamer Kern: `simulation_scene.tscn`, `simulation_relay.gd`, `scene_view.gd` und Shader.
- VR-Multiplayer: Hauptszene `main.tscn` von Situs (Server, Brillen, Datenkanal). Aktueller Stand.
- PC-Singleplayer: neue schlanke Szene `desktop_main.tscn`. Sie startet die Simulationsszene im Modus DIRECT (UDP von MATLAB, Orbit-Kamera, kein Menü, kein Netzwerk).

- [x] Ersetzt durch den Einzelspieler als zwei Instanzen (siehe `docs/plan_pc_versionen.md`), `desktop_main.tscn` entfällt.
- [x] Ein Windows-Export-Preset `PC` mit Startmenü statt eigener Hauptszene. Android bleibt unverändert. Ungetestet.
- [ ] Windows-Export-Vorlagen installieren (siehe `docs/INSTALL.md`). Der PC-Start ist in `docs/INSTALL.md` beschrieben.
- [ ] Erst bei starker Abweichung (anderer Renderer, kein OpenXR) in ein getrenntes Projekt `godot_pc/` auslagern. Der Kern müsste dann geteilt werden.

### 10. Umbenennung in Spatial Insights

- [x] GitHub-Repo umbenannt (`Spatial_Insights`), `origin` angepasst.
- [x] Godot-Projektname, App-Name, APK-Namen, `package/unique_name` (`org.spatialinsights.viewer`, `.lbe`), README, INSTALL, Setup-Skript.
- [ ] **Auf allen Brillen die alte App deinstallieren** (`org.matlabcommtest.viewer*`), weil Android die neue `unique_name` als andere App behandelt.
- [x] Notion-Seite *Spatial Insights* (Repo-Links, Namen, MATLAB statt Python) angepasst.
- [ ] Lokale Klone: `git remote set-url origin https://github.com/FutureRealitiesLab/Spatial_Insights.git`.

### 11. Neue Funktionen

- [ ] **Buffer-File (Offline-Playmode):** MATLAB-Frames aufzeichnen und ohne MATLAB abspielen. Ablauf in der Server-UI:
  - Record-Button am Server, beim Stoppen ein Speichern-Dialog.
  - Quellenauswahl: *Livestream* oder *Buffer-File*. Bei *Buffer-File* öffnet ein Datei-Dialog die Auswahl.
  - Das Abspielen speist wie ein UDP-Empfang in `simulation_relay` ein, die Brillen merken keinen Unterschied (Late Join, Datenkanal wie gehabt).
  - Muss auch im PC-Solo-Modus laufen. Idee: PC-Solo = lokaler Server mit lokalem Spieler, dann gibt es nur einen Einspeisepunkt.
- [x] **Freeze:** Leertaste oder Button am Server hält die Simulation für alle gemeinsam an (`SimulationRelay.set_frozen()`). Der Server verteilt keine neuen Frames, der Zustand geht per RPC an alle Brillen, ein Schild „EINGEFROREN“ schwebt über dem Raum, Late Joiner bekommen Zustand und letzten Frame. Am Server getestet, läuft. Auf den Brillen noch zu prüfen. Bekannte Grenze: Ein Frame, der beim Einfrieren noch unterwegs ist, kann auf einzelnen Brillen um einen Frame abweichen.
- [ ] **PC-Solo als lokaler Server mit First-Person-Ansicht** prüfen (statt eigener `desktop_main.tscn`): Situs bringt den FPS-Spieler (`player/fps_player.gd`, Startmodus *Als Spieler starten*) schon mit. Es fehlt die Verknüpfung mit Server-Rolle und Orbit-Ansicht. Siehe auch Punkt 9.
