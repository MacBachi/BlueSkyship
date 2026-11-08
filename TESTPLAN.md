# Testplan BlueSkyship

Das hier konnte ich nicht selbst prüfen: Die automatischen Tests laufen gegen simulierte Server, und mit deinem echten Konto habe ich nur gelesen. Die Reihenfolge geht von harmlos nach öffentlich.

**Priorität:** 🔴 hohes Risiko, 🟡 mittel, ⚪ gering. Mit wenig Zeit nimm nur die 🔴-Punkte.

Fehler schickst du mir am besten mit Punktnummer und, falls vorhanden, Screenshot oder Fehlertext. Abstürze stehen in `~/Library/Logs/DiagnosticReports` unter `BlueSkyship-…`.

## A. Nur lesen, ändert nichts

### Text und Klicks
- [ ] 🔴 **A1** Text in einem Post mit der Maus markieren und mit `⌘C` kopieren. *Erwartet: Der Text landet in der Zwischenablage.*
- [ ] 🔴 **A2** Einmal auf den Text eines Posts klicken. *Erwartet: Der Thread öffnet sich. Das könnte durch das Markieren kaputt sein.*
- [ ] 🔴 **A3** Einen Link, eine @Erwähnung und einen #Hashtag im Text anklicken. *Erwartet: Browser, Profil und Suchspalte öffnen sich.*
- [ ] 🔴 **A4** Rechtsklick auf den Text eines Posts und auf eine freie Stelle im Post. *Erwartet: Beide Male erscheint unser Menü mit „Alle Posts von …“.*

### Spalten
- [ ] 🟡 **A5** Spalte am Kopf auf eine andere ziehen. *Erwartet: Die Reihenfolge ändert sich und bleibt nach einem Neustart.*
- [ ] ⚪ **A6** Menü `…` einer Spalte: Breite ändern, nach links und rechts schieben.
- [ ] ⚪ **A7** Fenster schmal ziehen, dann in der Leiste unten auf einen Spaltennamen klicken. *Erwartet: Die Spalte kommt in den sichtbaren Bereich.*

### Filter
- [ ] 🟡 **A8** Filter-Symbol in der Home-Spalte, „Reposts ausblenden“ einschalten. *Erwartet: Reposts verschwinden sofort, die Statuszeile zählt mit.*
- [ ] 🟡 **A9** Einen Begriff bei „Ausblenden“ eintippen, danach „Zurücksetzen“.
- [ ] 🟡 **A10** Prüfe einen deiner in Bluesky stummgeschalteten Begriffe. *Erwartet: Posts damit fehlen in den Spalten. Fehlt etwas, das du sehen möchtest, sag Bescheid.*

### Personen
- [ ] 🔴 **A11** Rechtsklick auf eine Person → „Alle Posts von … in neuer Spalte“. Das gleiche bei „… hat repostet“, in einem Zitat und in Mitteilungen.
- [ ] 🟡 **A12** Klick auf ein Bild: Das Profil öffnet sich mit Posts, Antworten und Medien, „Zurück“ führt zurück.
- [ ] 🟡 **A13** Im Profil auf „Follower“ und „Folgt“ klicken. *Erwartet: Die Listen laden beim Scrollen weiter.*
- [ ] ⚪ **A14** Unter `⌘T` → Profil einen Namen tippen. *Erwartet: Vorschläge erscheinen.*

### Eigene Inhalte
- [ ] 🔴 **A15** Konto-Bild unten links → „Meine Posts anzeigen“. *Erwartet: Deine Posts mit genauem Datum und Zählern.*
- [ ] 🟡 **A16** Dort auf die Zähler klicken. *Erwartet: Likes, Reposts und Zitate mit Namen.*
- [ ] 🟡 **A17** Konto-Bild → „Meine Likes anzeigen“ und „Lesezeichen anzeigen“.
- [ ] 🟡 **A18** Suchspalte mit einem Begriff anlegen, mit deinem Konto.

### Bilder und Videos
- [ ] 🔴 **A19** Video **mit Ton** abspielen. *Erwartet: Bedienleiste und Ton. Bisher lief nur ein stummer GIF-Clip.*
- [ ] 🟡 **A20** Mehrere Bilder öffnen, mit `←` `→` blättern, mit `Esc` schließen.
- [ ] ⚪ **A21** Post mit eingebettetem Starter Pack, Feed oder Liste. *Erwartet: Eine Karte, die im Browser öffnet.*

### Favoriten und Decks
- [ ] 🔴 **A22** `⌘D`, dann `@name`, `#tag` und einen Suchbegriff hinzufügen. Klick zeigt die Vorschau, die Stecknadel macht eine Spalte daraus.
- [ ] 🟡 **A23** Favorit innerhalb seiner Gruppe ziehen. Rechtsklick auf einen Post mit Hashtag → „#… zu Favoriten hinzufügen“.
- [ ] 🟡 **A24** Spalte über `…` → „In Favoriten verschieben“.
- [ ] 🔴 **A25** Stapel-Symbol links: neues Deck anlegen, wechseln, umbenennen, löschen. `⌘1` und `⌘2` testen. *Erwartet: Jedes Deck behält seine Spalten.*

### Tastatur
- [ ] 🟡 **A26** `j` und `k` wandern durch Posts mit sichtbarer Markierung, `←` `→` und `1`–`9` wählen Spalten, `↩` öffnet den Thread, `Esc` geht zurück.
- [ ] 🔴 **A27** Im Composer und in Suchfeldern `j` oder `l` tippen. *Erwartet: Es erscheint nur der Buchstabe, und nichts wird geliked.*

### Sprache, Hilfe, Einstellungen
- [ ] 🟡 **A28** `⌘,` → Sprache auf English und zurück. *Erwartet: Der Wechsel wirkt sofort, auch in den eigenen Menüs wie „Neuer Post“. Standardmenüs wie „Bearbeiten“ dürfen der Systemsprache folgen.*
- [ ] 🟡 **A29** `⌘?` öffnet die Hilfe. *Beim unsichtbaren Rendern war die Zeile „TL;DR“ schwarz und die Registerkarte „Allgemein“ der Einstellungen leer. Vermutlich kam das nur vom Rendern, sag Bescheid, falls du es auch siehst.*
- [ ] ⚪ **A30** Tour durchklicken, die Knöpfe „… zeigen“ ausprobieren.
- [ ] ⚪ **A31** Textgröße und „Bilder und Videos direkt anzeigen“ umstellen.
- [ ] ⚪ **A32** Dock zeigt dein Logo als App-Symbol.

## B. Privat, ändert etwas auf deinem Konto

Für andere nicht sichtbar, und alles lässt sich rückgängig machen.

- [ ] 🟡 **B1** Rechtsklick auf einen Post → „Als Lesezeichen speichern“, dann in der Lesezeichen-Spalte prüfen und wieder entfernen.
- [ ] 🟡 **B2** Eine Person stummschalten. *Erwartet: Nachfrage, danach verschwinden ihre Posts.* Im Profil über `…` aufheben.
- [ ] 🟡 **B3** Dock-Zahl: Stimmt sie mit den ungelesenen Mitteilungen überein? „Alle als gelesen markieren“ im Menü `…` der Mitteilungen-Spalte setzt sie zurück, auch in anderen Bluesky-Apps.
- [ ] ⚪ **B4** Einstellungen → „macOS-Hinweise anzeigen“. *Erwartet: macOS fragt nach Erlaubnis, danach erscheint ein Hinweis bei neuer Mitteilung.*
- [ ] ⚪ **B5** Rechtsklick auf einen Post → „Übersetzen“. *Erwartet: Apples Übersetzungsfenster.*

## C. Direktnachrichten

Am unsichersten bei Lesen und Antworten. Dein aktuelles App-Passwort hat vermutlich keine Freigabe dafür.

- [ ] 🔴 **C1** Konto-Bild → „Direktnachrichten anzeigen“. *Erwartet: Entweder deine Unterhaltungen oder ein Hinweis auf die fehlende Freigabe.*
- [ ] 🔴 **C2** Falls nötig: unter https://bsky.app/settings/app-passwords ein neues Passwort mit „Allow access to your direct messages“ erstellen und neu anmelden. Danach C1 wiederholen.
- [ ] 🟡 **C3** Eine Unterhaltung öffnen. *Erwartet: Nachrichten in richtiger Reihenfolge, Ungelesen-Zahl geht zurück.*
- [ ] 🟡 **C4** Mit jemandem, der einverstanden ist: Nachricht mit Link senden, und über „Nachricht“ im Profil eine neue Unterhaltung starten.

## D. Öffentlich sichtbar

Andere können das sehen. Lösche Testposts danach mit Rechtsklick → „Post löschen …“.

- [ ] 🔴 **D1** Testpost mit Link, @Erwähnung und #Hashtag. *Erwartet: Alles ist auch auf bsky.app verlinkt.*
- [ ] 🔴 **D2** Diesen Post in der App löschen. *Erwartet: Nachfrage, danach ist er auch auf bsky.app weg.*
- [ ] 🔴 **D3** Testpost mit Bild und Bildbeschreibung, per Knopf, Drag & Drop und `⌘V`.
- [ ] 🔴 **D4** Thread mit drei Posts und einem Bild im zweiten. *Erwartet: Auf bsky.app eine zusammenhängende Kette, das Bild am richtigen Post.*
- [ ] 🔴 **D5** MP4-Video hochladen. *Am unsichersten von allem. Erwartet: Nach etwas Wartezeit ist das Video auf bsky.app abspielbar.*
- [ ] 🟡 **D6** „Wer darf antworten“ auf „Niemand“ stellen. *Erwartet: Auf bsky.app ist Antworten gesperrt.*
- [ ] 🟡 **D7** Liken und Reposten, jeweils wieder rückgängig, einmal auch mit `l` und `t`.
- [ ] 🟡 **D8** Auf einen Post antworten und einen zitieren, einmal mit Bild im Zitat.
- [ ] 🟡 **D9** Einer Person folgen und wieder entfolgen.
- [ ] ⚪ **D10** Eine Person blockieren und im Profil wieder freigeben. *Blockieren ist öffentlich einsehbar, nimm am besten ein eigenes Zweitkonto.*

## E. Entwürfe und geplante Posts

- [ ] 🟡 **E1** Text und Bild im Composer eintippen, schließen, über das Menü „Entwürfe“ im nächsten Composer zurückholen. *Das Menü erscheint nur, wenn ein anderer Entwurf existiert.*
- [ ] 🟡 **E2** App beenden, während ein Entwurf offen ist, und neu starten.
- [ ] 🟡 **E3** Testpost für in zwei Minuten planen, App offen lassen. *Erwartet: Er geht pünktlich raus.* Danach löschen.
- [ ] 🟡 **E4** Testpost für in 20 Minuten planen, App schließen und erst über 15 Minuten nach dem geplanten Zeitpunkt starten. *Erwartet: Er geht nicht von selbst raus, das Kalender-Symbol fragt nach.*

## F. Braucht besondere Vorbereitung

- [ ] 🔴 **F1 iCloud:** Auf einem zweiten Mac mit derselben Apple-ID das Projekt in Xcode bauen, anmelden und starten. Favorit auf Mac 1 anlegen. *Erwartet: Er erscheint nach einigen Minuten auf Mac 2, dann umgekehrt. Decks und Entwurfstext ebenso.*
- [ ] 🟡 **F2 Zweites Konto:** Über das Personen-Symbol ein weiteres Konto anmelden. *Erwartet: Im Composer wählbar, Spalten gehören zum jeweiligen Konto.* Abmelden entfernt die kontogebundenen Spalten.
- [ ] 🟡 **F3 Passwort-Seite:** Das letzte Konto abmelden und den Login öffnen. *Erwartet: Die App-Passwort-Seite öffnet sich automatisch im Browser, einmal pro Start.*
- [ ] 🟡 **F4 Notarisierung:** Developer-ID-Zertifikat und Zugangsdaten einrichten, wie am Anfang von `scripts/release.sh` beschrieben, dann `scripts/release.sh 1.0.0`. *Erwartet: Ein DMG, das sich auf einem anderen Mac ohne Warnung öffnet. Dieser Ablauf ist noch nie gelaufen.*
