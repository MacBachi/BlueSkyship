# Testplan BlueSkyship

Hier steht nur noch, was ich nicht selbst prüfen kann. Alles andere läuft automatisch in `Tests/UIDriveTests.swift`: echte Klicks und Tasten im unsichtbaren Fenster gegen einen simulierten Server.

**Ich kann nicht prüfen:** Menüs und Dialoge, die auf dem Bildschirm aufgehen, Drag & Drop, das Aussehen und alles, was den echten Bluesky-Server oder iCloud braucht.

**Priorität:** 🔴 hohes Risiko, 🟡 mittel, ⚪ gering. Mit wenig Zeit nimm nur die 🔴-Punkte. Schick mir Fehler mit Punktnummer und, falls vorhanden, Screenshot.

## 1. Kurz nachprüfen, gerade geändert

- [ ] 🔴 **1.1** Spalte über `…` → „In Favoriten verschieben“. *Erwartet: Personen stehen mit Name und Bild in der Liste, und dieselbe Spalte kommt per Stecknadel mit Filter und Breite zurück.* Falls noch immer etwas Falsches auftaucht: Welche Spalte war es, und was erschien stattdessen?
- [ ] 🔴 **1.2** Neues, leeres Deck über das Stapel-Symbol. *Erwartet: Die linke Leiste bleibt am Rand, nichts ist verschoben.*
- [ ] 🔴 **1.3** Rechtsklick auf den Text eines Posts, einmal mit markiertem Text. *Erwartet: Unser Menü, bei Markierung zusätzlich „Kopieren“ oben. Der Inhalt ist getestet, nur das Aufgehen nicht.*
- [ ] 🟡 **1.4** Menü `…` im Spaltenkopf. *Erwartet: Es reagiert auch knapp neben den Punkten.*

## 2. Nur lesen

- [ ] 🟡 **2.1** Rechtsklick auf ein Zitat und auf den Text einer Mitteilung. *Erwartet: Das Personen-Menü.*
- [ ] 🟡 **2.2** Favorit innerhalb seiner Gruppe ziehen. *Drag & Drop kann ich nicht auslösen.*
- [ ] 🟡 **2.3** Stapel-Symbol: Deck umbenennen und löschen. `⌘1` und `⌘2` wechseln. *Der Namensdialog und die Menüleiste sind nur hier prüfbar.*
- [ ] 🟡 **2.4** `⌘,` → Sprache auf English und zurück. *Erwartet: Wirkt sofort, auch in „Neuer Post“ usw. in der Menüleiste.*
- [ ] 🟡 **2.5** Einstellungen und Hilfe (`⌘?`) ansehen. *Beim Rendern war die Zeile „TL;DR“ schwarz und die Registerkarte „Allgemein“ leer. Vermutlich kam das nur vom Rendern, sag Bescheid, falls du es auch siehst.*
- [ ] ⚪ **2.6** Stummgeschaltete Wörter, nur falls du welche nutzt: Unter https://bsky.app/settings/moderation/muted-words ein Wort eintragen, das gerade in deiner Home-Spalte steht, App neu starten. *Erwartet: Solche Posts fehlen, deine eigenen nicht.* Danach wieder entfernen.
- [ ] ⚪ **2.7** Das Dock zeigt dein Logo.

## 3. Direktnachrichten

- [ ] 🔴 **3.1** Konto-Bild → „Direktnachrichten anzeigen“. *Erwartet: Deine Unterhaltungen oder ein Hinweis auf die fehlende Freigabe. Falls der Hinweis kommt: unter https://bsky.app/settings/app-passwords ein Passwort mit „Allow access to your direct messages“ erstellen und neu anmelden.*
- [ ] 🟡 **3.2** Unterhaltung öffnen. *Erwartet: Nachrichten in richtiger Reihenfolge, die Ungelesen-Zahl geht zurück.*
- [ ] 🟡 **3.3** Mit jemandem, der einverstanden ist: Nachricht mit Link senden, und über „Nachricht“ im Profil eine neue Unterhaltung starten.

## 4. Mit dem echten Server, öffentlich sichtbar

Ablauf und Daten sind gegen den simulierten Server getestet. Offen ist nur, ob der echte Bluesky-Server alles genauso annimmt. Lösche Testposts danach per Rechtsklick → „Post löschen …“.

- [ ] 🔴 **4.1** Testpost mit Link, @Erwähnung und #Hashtag, dann löschen. *Erwartet: Auf bsky.app korrekt verlinkt, danach weg.*
- [ ] 🔴 **4.2** Thread mit drei Posts und einem Bild im zweiten. *Erwartet: Auf bsky.app eine zusammenhängende Kette, das Bild am richtigen Post.*
- [ ] 🔴 **4.3** MP4-Video hochladen. *Am unsichersten von allem. Erwartet: Nach etwas Wartezeit auf bsky.app abspielbar.*
- [ ] 🟡 **4.4** „Wer darf antworten“ auf „Niemand“. *Erwartet: Auf bsky.app ist Antworten gesperrt.*
- [ ] 🟡 **4.5** Liken, Reposten, Lesezeichen und Stummschalten, jeweils wieder rückgängig. Folgen und Entfolgen.
- [ ] ⚪ **4.6** Einen Post zitieren, einmal mit Bild.
- [ ] ⚪ **4.7** Eine Person blockieren und im Profil wieder freigeben. *Öffentlich einsehbar, nimm am besten ein Zweitkonto.*

## 5. Systemfunktionen

- [ ] 🟡 **5.1** Dock-Zahl: Stimmt sie mit den ungelesenen Mitteilungen überein? „Alle als gelesen markieren“ im Menü `…` der Mitteilungen-Spalte setzt sie zurück.
- [ ] ⚪ **5.2** Einstellungen → „macOS-Hinweise anzeigen“. *Erwartet: macOS fragt nach Erlaubnis, danach erscheint ein Hinweis bei neuer Mitteilung.*
- [ ] ⚪ **5.3** Rechtsklick auf einen Post → „Übersetzen“. *Erwartet: Apples Übersetzungsfenster.*
- [ ] ⚪ **5.4** Bild im Composer per Drag & Drop und mit `⌘V` einfügen.

## 6. Braucht Vorbereitung

- [ ] 🔴 **6.1 iCloud:** Auf einem zweiten Mac mit derselben Apple-ID das Projekt in Xcode bauen, anmelden und starten. Favorit auf Mac 1 anlegen. *Erwartet: Er erscheint nach einigen Minuten auf Mac 2, dann umgekehrt. Decks und Entwurfstext ebenso.*
- [ ] 🟡 **6.2 Zweites Konto:** Über das Personen-Symbol anmelden. *Erwartet: Im Composer wählbar, Spalten gehören zum jeweiligen Konto.*
- [ ] 🟡 **6.3 Notarisierung:** Zertifikat und Zugangsdaten einrichten, wie am Anfang von `scripts/release.sh` beschrieben, dann `scripts/release.sh 1.0.0`. *Erwartet: Ein DMG, das sich auf einem anderen Mac ohne Warnung öffnet.*
- [ ] ⚪ **6.4 Passwort-Seite:** Letztes Konto abmelden, Login öffnen. *Erwartet: Die App-Passwort-Seite öffnet sich automatisch, einmal pro Start.*
