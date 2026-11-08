# Testplan BlueSkyship

Hier steht nur noch, was ich wirklich nicht selbst prüfen kann:

- Menüs und Dialoge, die auf dem echten Bildschirm aufgehen
- Drag & Drop
- die Antwort des echten Bluesky-Servers
- iCloud zwischen zwei Macs
- die Notarisierung

Alles andere läuft automatisch in `Tests/UIDriveTests.swift` und `Tests/UIDriveMoreTests.swift`. Zusätzlich prüft `scripts/validate-records.py`, ob die verschickten Datensätze den offiziellen Bluesky-Definitionen entsprechen.

**Priorität:** 🔴 hohes Risiko, 🟡 mittel, ⚪ gering. Mit wenig Zeit nimm nur die 🔴-Punkte. Schick mir Fehler mit Punktnummer und, falls vorhanden, Screenshot.

## 1. Fenster und Menüs

- [ ] 🔴 **1.1** Spalte über `…` → „In Favoriten verschieben“. *Erwartet: Die Person steht mit Name und Bild in der Liste, die Stecknadel bringt dieselbe Spalte zurück.* Falls noch immer etwas Falsches auftaucht: Welche Spalte war es, und was erschien stattdessen?
- [ ] 🔴 **1.2** Rechtsklick auf den Text eines Posts, einmal mit markiertem Text. *Erwartet: Das Menü geht auf, bei Markierung steht „Kopieren“ oben. Der Inhalt ist getestet, nur das Aufgehen nicht.*
- [ ] 🟡 **1.3** Hilfe öffnen (`⌘?`). *Erwartet: Die Überschrift „TL;DR“ ist gut lesbar. In meiner Aufnahme lag sie verschwommen unter der Titelleiste, das kann am Testfenster liegen.*
- [ ] 🟡 **1.4** Menü `…` im Spaltenkopf. *Erwartet: Es reagiert auch knapp neben den Punkten.*
- [ ] 🟡 **1.5** Favorit innerhalb seiner Gruppe ziehen.
- [ ] 🟡 **1.6** Stapel-Symbol: Deck umbenennen. `⌘1` und `⌘2` wechseln. Sprache umstellen und in der Menüleiste nachsehen. *Erwartet: „Neuer Post“ usw. wechseln mit, Standardmenüs dürfen der Systemsprache folgen.*

## 2. Echter Bluesky-Server

Ablauf und Datenformat sind geprüft. Offen ist nur, ob der echte Server alles genauso annimmt. Das ist öffentlich sichtbar, lösche Testposts danach per Rechtsklick → „Post löschen …“.

- [ ] 🔴 **2.1** Konto-Bild → „Direktnachrichten anzeigen“. *Erwartet: Deine Unterhaltungen oder der Hinweis auf die fehlende Freigabe. Dann unter https://bsky.app/settings/app-passwords ein Passwort mit „Allow access to your direct messages“ erstellen und neu anmelden.*
- [ ] 🔴 **2.2** Thread aus zwei Posts, im zweiten ein Bild und im ersten Link, @Erwähnung und #Hashtag. *Erwartet: Auf bsky.app stimmt alles. Danach beide löschen.*
- [ ] 🔴 **2.3** MP4-Video hochladen. *Am unsichersten von allem, weil es über Blueskys eigenen Video-Dienst läuft. Erwartet: Nach etwas Wartezeit auf bsky.app abspielbar.*
- [ ] 🟡 **2.4** Mit jemandem, der einverstanden ist: Nachricht senden und über „Nachricht“ im Profil eine neue Unterhaltung starten.
- [ ] ⚪ **2.5** Antwort-Regel „Niemand“ an einem Testpost. *Erwartet: Auf bsky.app ist Antworten gesperrt.*
- [ ] ⚪ **2.6** Liken, Reposten, Lesezeichen, Stummschalten und Folgen, jeweils rückgängig.
- [ ] ⚪ **2.7** Nur falls du stummgeschaltete Wörter nutzt: Unter https://bsky.app/settings/moderation/muted-words eines eintragen, das gerade in deiner Home-Spalte steht, App neu starten. *Erwartet: Solche Posts fehlen.* Danach wieder entfernen.

## 3. Systemfunktionen

- [ ] ⚪ **3.1** Einstellungen → „macOS-Hinweise anzeigen“. *Erwartet: macOS fragt nach Erlaubnis, danach erscheint ein Hinweis bei neuer Mitteilung.*
- [ ] ⚪ **3.2** Rechtsklick auf einen Post → „Übersetzen“. *Erwartet: Apples Übersetzungsfenster.*
- [ ] ⚪ **3.3** Ein Bild aus dem Finder in den Composer ziehen und eines mit `⌘V` einfügen.

## 4. Braucht Vorbereitung

- [ ] 🔴 **4.1 iCloud:** Auf einem zweiten Mac mit derselben Apple-ID das Projekt in Xcode bauen, anmelden und starten. Favorit auf Mac 1 anlegen. *Erwartet: Er erscheint nach einigen Minuten auf Mac 2, dann umgekehrt. Decks und Entwurfstext ebenso.*
- [ ] 🟡 **4.2 Notarisierung:** Zertifikat und Zugangsdaten einrichten, wie am Anfang von `scripts/release.sh` beschrieben, dann `scripts/release.sh 1.0.0`. *Erwartet: Ein DMG, das sich auf einem anderen Mac ohne Warnung öffnet.*
