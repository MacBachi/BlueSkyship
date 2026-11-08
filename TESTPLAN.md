# Testplan BlueSkyship

Hier steht nur noch, was ich wirklich nicht selbst prüfen kann:

- iCloud zwischen zwei Macs
- die Notarisierung

Alles andere läuft automatisch in `Tests/UIDriveTests.swift` und `Tests/UIDriveMoreTests.swift`. Zusätzlich prüft `scripts/validate-records.py`, ob die verschickten Datensätze den offiziellen Bluesky-Definitionen entsprechen.

**Priorität:** 🔴 hohes Risiko, 🟡 mittel, ⚪ gering. Mit wenig Zeit nimm nur die 🔴-Punkte. Schick mir Fehler mit Punktnummer und, falls vorhanden, Screenshot.

## 4. Braucht Vorbereitung

- [ ] 🔴 **4.1 iCloud:** Auf einem zweiten Mac mit derselben Apple-ID das Projekt in Xcode bauen, anmelden und starten. Favorit auf Mac 1 anlegen. *Erwartet: Er erscheint nach einigen Minuten auf Mac 2, dann umgekehrt. Decks und Entwurfstext ebenso.*
- [ ] 🟡 **4.2 Notarisierung:** Zertifikat und Zugangsdaten einrichten, wie am Anfang von `scripts/release.sh` beschrieben, dann `scripts/release.sh 1.0.0`. *Erwartet: Ein DMG, das sich auf einem anderen Mac ohne Warnung öffnet.*
