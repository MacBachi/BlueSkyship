# BlueSkyship

Native macOS-App (SwiftUI, ohne Fremdabhängigkeiten) mit einem Spalten-Deck für Bluesky, im Stil von TweetDeck.

## Starten

Voraussetzung: Xcode und [XcodeGen](https://github.com/yonaskolb/XcodeGen). Das Xcode-Projekt wird aus `project.yml` erzeugt und nicht eingecheckt.

```bash
xcodegen generate
open BlueSkyship.xcodeproj
```

Tests:

```bash
xcodebuild test -project BlueSkyship.xcodeproj -scheme BlueSkyship -destination 'platform=macOS' -allowProvisioningUpdates
```

## App-Symbol

Das Symbol entsteht aus `Branding/logo.png`:

```bash
swift scripts/make-icon.swift Branding/logo.png Sources/Resources/Assets.xcassets/AppIcon.appiconset
```

## Tests

`Tests/UIDriveTests.swift` und `Tests/UIDriveMoreTests.swift` steuern das echte Fenster unsichtbar mit Maus- und Tastenereignissen gegen einen simulierten Server. Sie benutzen weder deine Maus noch dein Konto.

Der Test `writeAllRecordsForValidation` schreibt die verschickten Datensätze in eine Datei. `scripts/validate-records.py <Lexikon-Ordner> <Datei>` prüft sie gegen die offiziellen Bluesky-Definitionen.

## Aufbau

| Ordner | Inhalt |
| --- | --- |
| `Sources/ATProto` | XRPC-Client mit Token-Refresh, Datenmodelle, API-Aufrufe, Facets (UTF-8-Byte-Offsets) |
| `Sources/Deck` | Spalten und deren Ladezustand, Konten (Tokens im Schlüsselbund), Aktionen |
| `Sources/Views` | Deck-Fenster, Spalten, Posts, Einbettungen, Composer, Dialoge |
| `Tests` | Unit-Tests mit gestubbtem Netzwerk |

## Tastenkürzel

| Kürzel | Aktion |
| --- | --- |
| ⌘N | Neuer Post |
| ⌘↩ | Post absenden |
| ⌘T | Spalte hinzufügen |
| ⌘R | Alle Spalten aktualisieren |

## Personen, Medien und Einstellungen

- **Meine Posts:** Klick auf dein Konto-Bild unten links. Zeigt alles, was du gepostet hast, mit genauem Datum und Zählern. Ein Klick auf die Zähler zeigt, wer geliked, repostet oder zitiert hat. Per Rechtsklick geht das bei jedem Post.
- **Rechtsklick auf eine Person** (Post, Avatar, Repost-Hinweis, Zitat, Mitteilung): alle Posts der Person in einer neuen Spalte, oder ihr Profil.
- **Klick auf den Avatar oder eine @Erwähnung** öffnet das Profil in derselben Spalte, mit Posts, Antworten, Medien und Folgen.
- **Bilder und Videos** öffnen im Fenster. Esc schließt, die Pfeiltasten blättern.
- **Composer:** bis zu vier Bilder per Button oder Drag & Drop. Sie werden verkleinert, Metadaten wie der GPS-Standort werden entfernt.
- **Einstellungen (⌘,):** Aktualisierungsintervall, Breite neuer Spalten, Medienanzeige, Sprache neuer Posts, Konten.

## Sprache und Hilfe

Die App zeigt sich auf Deutsch oder Englisch. Standard ist die Systemsprache (alles außer Deutsch wird Englisch), umstellen lässt sie sich unter Einstellungen (⌘,), ohne Neustart. Texte stehen als Paar im Code: `tr("Deutsch", "English")`. Die Hilfe (⌘?) enthält ein TL;DR, eine geführte Tour und Themen.

## Favoriten

Der Stern in der linken Leiste (⌘D) öffnet eine Liste mit Personen, Hashtags, Suchen, Feeds und Listen, die keine Spalte belegen. Ein Klick zeigt den Inhalt vorübergehend daneben, die Stecknadel heftet ihn dauerhaft als Spalte an. Hinzufügen geht per Eingabe (`@name`, `#tag`, Suchbegriff oder Bluesky-Link), per Rechtsklick auf eine Person oder über das Spaltenmenü. Favoriten liegen nur lokal auf diesem Mac.

## Suchen

Ganz Bluesky: Lupe links oder `⌘⇧F`. Eine Spalte: Lupe im Spaltenkopf oder `⌘F`.

## Weitere Funktionen

- **Threads, Entwürfe, Planen:** im Composer. Entwürfe sichern den Text beim Tippen. Geplante Posts sendet die App nur, solange sie läuft und der Mac wach ist.
- **Mehrere Decks:** Stapel-Symbol links, `⌘1` bis `⌘9`.
- **Tastatursteuerung:** `j` `k` `l` `t` `r` `q` `n` `a`, `1`–`9`, `←` `→`, `↩`, `Esc`. Lässt sich in den Einstellungen abschalten.
- **Mitteilungen:** Zahl am Dock-Symbol, optional macOS-Hinweise. Gelesen wird nur auf ausdrücklichen Wunsch markiert.
- **Direktnachrichten:** brauchen ein App-Passwort mit der Option „Allow access to your direct messages“.
- **Moderation:** Stummschalten und Blockieren per Rechtsklick, eigene Posts löschen, Lesezeichen, Übersetzen.

## iCloud

Favoriten, Decks und Entwurfstexte werden über den iCloud-Schlüsselspeicher synchronisiert, Anmeldungen und Bilder nicht. Bei gleichzeitigen Änderungen auf zwei Macs gilt die spätere für die ganze Liste. Die Berechtigung steht in `BlueSkyship.entitlements`. Deshalb braucht jeder Build auf der Kommandozeile `-allowProvisioningUpdates`, damit Xcode das Profil holen kann.

## Weitergabe

`scripts/release.sh` baut, signiert, notarisiert und packt ein DMG. Voraussetzungen und Schritte stehen am Anfang des Skripts.

## Spaltenfilter

Jede Spalte lässt sich über das Filter-Symbol im Spaltenkopf einschränken: nur mit bestimmten Wörtern, Wörter oder `@handle` ausblenden, nur Posts mit Bild oder Video, ohne Reposts, ohne Antworten. Der Filter läuft nur lokal und wird mit der Spalte gespeichert.

## Anmeldung

Die Anmeldung läuft über ein App-Passwort aus den [Bluesky-Einstellungen](https://bsky.app/settings/app-passwords). Der Login-Dialog öffnet diese Seite beim ersten Aufruf nach dem App-Start automatisch im Browser, solange noch kein Konto angemeldet ist. Das Passwort wird nicht gespeichert, nur die Sitzungstoken im Schlüsselbund.
