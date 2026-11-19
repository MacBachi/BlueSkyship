import Foundation

/// Help texts. They use light Markdown: **bold** for names, `code` for keys. Computed, so they follow the language.
struct HelpTopic: Identifiable {
    let id: String
    let icon: String
    let title: String
    let bullets: [String]
}

struct TourStep: Identifiable {
    enum Demo {
        case addColumn, favorites, compose, settings
    }

    let id: Int
    let icon: String
    let title: String
    let text: String
    var demo: Demo?
}

enum HelpContent {
    /// Deliberately one line per feature. Anything longer belongs in the topics.
    static var tldr: [String] {
        [
            tr("**Suchen:** `⌘⇧F` in ganz Bluesky, `⌘F` in einer Spalte, oder die Lupen.", "**Search:** `⌘⇧F` all of Bluesky, `⌘F` one column, or the magnifying glasses."),
            tr("**Spalten:** `⌘T` fügt hinzu, auch RSS und Feedly. Am Kopf ziehen sortiert.", "**Columns:** `⌘T` adds one, RSS and Feedly too. Drag the header to reorder."),
            tr("**Verdeckte Spalten:** Die Leiste unten nennt sie. Klick springt hin.", "**Hidden columns:** The bottom bar names them. Click to jump."),
            tr("**Person:** Rechtsklick zeigt alle Posts in neuer Spalte. Klick aufs Bild zeigt das Profil.", "**People:** Right-click for all posts in a new column. Click the picture for the profile."),
            tr("**Favoriten:** `⌘D`. Griffbereit, ohne eine Spalte zu belegen.", "**Favorites:** `⌘D`. Close at hand, without taking up a column."),
            tr("**Filter:** Symbol im Spaltenkopf. Ausblenden, immer zeigen, unter Namen speichern.", "**Filters:** Icon in the column header. Hide, always show, save under a name."),
            tr("**Meine Posts:** Dein Konto-Bild unten links. Mit Datum und Reaktionen.", "**My Posts:** Your account picture, bottom left. With dates and reactions."),
            tr("**Wer hat reagiert:** Rechtsklick auf einen Post, dann „Reaktionen anzeigen“.", "**Who reacted:** Right-click a post, then “Show Reactions”."),
            tr("**Posten:** `⌘N`, absenden mit `⌘↩`. Bis zu 4 Bilder.", "**Posting:** `⌘N`, send with `⌘↩`. Up to 4 pictures."),
            tr("**IOCs:** Hashes, IPs, CVEs, Domains orange. Hovern zeigt Live-Infos und Bewertung.", "**IOCs:** Hashes, IPs, CVEs, domains in orange. Hover shows live info and ratings."),
            tr("**Tasten:** `j` `k` wandern, `l` liken, `r` antworten, `1`–`9` Spalte.", "**Keys:** `j` `k` move, `l` like, `r` reply, `1`–`9` column."),
            tr("**Einstellungen:** `⌘,`. Sprache, Aktualisierung, Konten, auch Mastodon.", "**Settings:** `⌘,`. Language, refresh, accounts, Mastodon too."),
        ]
    }

    static var tour: [TourStep] {
        [
            TourStep(
                id: 0, icon: "rectangle.split.3x1",
                title: tr("Dein Deck", "Your deck"),
                text: tr(
                    "Alles läuft in Spalten nebeneinander: Home, Mitteilungen, Suchen, Personen, Feeds. Füge eine hinzu, die du im Blick behalten willst.",
                    "Everything runs in columns side by side: Home, notifications, searches, people, feeds. Add one you want to keep an eye on."
                ),
                demo: .addColumn
            ),
            TourStep(
                id: 1, icon: "chevron.right.2",
                title: tr("Nichts geht verloren", "Nothing gets lost"),
                text: tr(
                    "Passen nicht alle Spalten ins Fenster, nennt die Leiste unten die verdeckten beim Namen. Ein Klick springt hin. Neue Posts warten hinter dem Knopf „neu“, solange du weiter unten liest.",
                    "When not all columns fit the window, the bar at the bottom names the hidden ones. One click jumps there. While you read further down, new posts wait behind the “new” button."
                )
            ),
            TourStep(
                id: 2, icon: "person.crop.circle",
                title: tr("Personen", "People"),
                text: tr(
                    "Klicke mit der rechten Maustaste auf eine Person und wähle „Alle Posts in neuer Spalte“. Ein normaler Klick auf ihr Bild oder eine @Erwähnung zeigt das Profil direkt in der Spalte.",
                    "Right-click a person and choose “All posts in new column”. A normal click on their picture or an @mention shows the profile right inside the column."
                )
            ),
            TourStep(
                id: 3, icon: "star",
                title: tr("Favoriten", "Favorites"),
                text: tr(
                    "Personen, Hashtags, Suchen und Feeds, die du nur ab und zu brauchst. Ein Klick zeigt sie vorübergehend an, die Stecknadel macht sie zur festen Spalte.",
                    "People, hashtags, searches and feeds you only need now and then. One click shows them temporarily, the pin makes them a permanent column."
                ),
                demo: .favorites
            ),
            TourStep(
                id: 4, icon: "line.3.horizontal.decrease.circle",
                title: tr("Filter", "Filters"),
                text: tr(
                    "Jede Spalte hat oben ein Filter-Symbol. Zeige nur bestimmte Wörter, blende Wörter oder Autoren aus, oder beschränke dich auf Bilder und Videos. Der Filter gilt nur in dieser App.",
                    "Every column has a filter icon at the top. Show only certain words, hide words or authors, or stick to pictures and videos. Filters only apply inside this app."
                )
            ),
            TourStep(
                id: 5, icon: "text.bubble",
                title: tr("Deine eigenen Posts", "Your own posts"),
                text: tr(
                    "Klicke unten links auf dein Konto-Bild und wähle „Meine Posts anzeigen“. Du siehst alles mit genauem Datum und allen Zählern. Ein Klick auf die Zähler zeigt, wer reagiert hat.",
                    "Click your account picture at the bottom left and choose “Show My Posts”. You see everything with its exact date and all counts. Click the counts to see who reacted."
                )
            ),
            TourStep(
                id: 6, icon: "square.and.pencil",
                title: tr("Posten", "Posting"),
                text: tr(
                    "`⌘N` öffnet den Composer an der Seite, sodass du beim Schreiben weiterlesen kannst. Ziehe Bilder einfach hinein. Beim Üben passiert nichts, erst „Posten“ oder `⌘↩` sendet wirklich.",
                    "`⌘N` opens the composer at the side, so you can keep reading while you write. Just drag pictures in. Nothing goes out while you try it: only “Post” or `⌘↩` really sends."
                ),
                demo: .compose
            ),
            TourStep(
                id: 7, icon: "gearshape",
                title: tr("Einstellungen", "Settings"),
                text: tr(
                    "Unter `⌘,` oder dem Zahnrad links wählst du Sprache, Aktualisierung und Medienanzeige und verwaltest deine Konten. Diese Hilfe erreichst du jederzeit mit `⌘?`.",
                    "Under `⌘,` or the gear on the left you choose language, refresh and media display, and manage your accounts. You can reach this help at any time with `⌘?`."
                ),
                demo: .settings
            ),
        ]
    }

    static var topics: [HelpTopic] {
        [
            HelpTopic(id: "start", icon: "person.badge.key", title: tr("Anmelden", "Signing in"), bullets: [
                tr("Du meldest dich mit einem **App-Passwort** an, nicht mit deinem Hauptpasswort. Du erstellst es unter [bsky.app/settings/app-passwords](https://bsky.app/settings/app-passwords).", "You sign in with an **app password**, not your main password. Create one at [bsky.app/settings/app-passwords](https://bsky.app/settings/app-passwords)."),
                tr("Es reicht dein Name: Aus `peter` wird `peter.bsky.social`. Eigene Domains und E-Mail-Adressen gehen auch, den Server findet die App selbst.", "Your name is enough: `peter` becomes `peter.bsky.social`. Your own domain and email addresses work too, and the app finds the server by itself."),
                tr("Der Login öffnet diese Seite automatisch, solange noch kein Konto angemeldet ist.", "Sign-in opens that page automatically while no account is signed in yet."),
                tr("Ohne Konto kannst du öffentliche Feeds und Profile lesen. Home, Mitteilungen, Suche, Liken und Posten brauchen ein Konto.", "Without an account you can read public feeds and profiles. Home, notifications, search, liking and posting need an account."),
                tr("Weitere Konten fügst du über das Personen-Symbol unten links hinzu. Jede Spalte gehört zu einem Konto.", "Add more accounts with the person icon at the bottom left. Each column belongs to one account."),
            ]),
            HelpTopic(id: "mastodon", icon: "bubble.left.and.bubble.right", title: "Mastodon", bullets: [
                tr("Beim Anmelden wählst du oben **Mastodon** und gibst deinen Server ein, etwa `mastodon.social`. Die Anmeldung läuft auf der Seite deines Servers im Browser. Die App sieht dein Passwort nie.", "When signing in, choose **Mastodon** at the top and enter your server, such as `mastodon.social`. You sign in on your server's page in the browser. The app never sees your password."),
                tr("Mastodon- und Bluesky-Spalten stehen im selben Deck nebeneinander. Jede Spalte gehört zu einem Konto und damit zu einem Netzwerk.", "Mastodon and Bluesky columns share the same deck. Each column belongs to one account and so to one network."),
                tr("Zusätzlich gibt es die Spalten **Lokal** (dein Server), **Föderiert** (alle bekannten Server) und deine **Listen**. Hashtags öffnen den Hashtag-Verlauf deines Servers.", "There are also the **Local** (your server) and **Federated** (all known servers) columns, and your **lists**. Hashtags open your server's hashtag timeline."),
                tr("**Boosten** und **Favorisieren** liegen dort, wo bei Bluesky Repost und Like sind. Antworten bleiben im Netzwerk des Posts.", "**Boost** and **favorite** sit where repost and like are for Bluesky. Replies stay on the network of the post."),
                tr("Im Composer wählst du die **Sichtbarkeit** und eine optionale **Inhaltswarnung**. Eine Antwort ist nie sichtbarer als der Post, auf den sie antwortet. Die Grundeinstellung steht unter `⌘,`.", "In the composer you choose the **visibility** and an optional **content warning**. A reply is never more visible than the post it answers. Set the default under `⌘,`."),
                tr("Posts mit Inhaltswarnung bleiben verdeckt, bis du sie anklickst. Deine Filter vom Server gelten: „Ausblenden“ blendet aus, „Warnen“ verdeckt.", "Posts with a content warning stay covered until you click them. Your server filters apply: “hide” hides, “warn” covers."),
                tr("**Direktnachrichten** sind bei Mastodon Posts, die nur die Erwähnten sehen. „Nachricht“ im Profil beginnt so einen Post, die Spalte Direktnachrichten zeigt deine Unterhaltungen.", "On Mastodon, **direct messages** are posts only the mentioned people see. “Message” on a profile starts one, and the Direct Messages column shows your conversations."),
                tr("Umfragen werden mit Stimmen angezeigt. Abstimmen geht im Browser.", "Polls show with their votes. Voting works in the browser."),
                tr("**Suchen und Hashtags mischen** beide Netzwerke in einer Spalte, neueste zuerst, auch als Favorit. Beim Hinzufügen heißt das Konto dafür „Alle Netzwerke“. Liken, Antworten und Öffnen laufen über das Konto, das den Post gefunden hat.", "**Searches and hashtags mix** both networks in one column, newest first, also as a favorite. When adding, choose “All networks” as the account. Liking, replying and opening go through the account that found the post."),
                tr("Jedes Konto hat eine **Farbe**. Ein schmaler Streifen am Rand jedes Posts zeigt, woher er kommt. Die Farbe stellst du unter `⌘,` bei Konten ein.", "Each account has a **colour**. A thin strip at the edge of every post shows where it came from. Change the colour under `⌘,` in Accounts."),
            ]),
            HelpTopic(id: "feeds", icon: "dot.radiowaves.up.forward", title: tr("RSS und Feedly", "RSS and Feedly"), bullets: [
                tr("`⌘T`, dann oben **RSS & Feedly**. Gib die Adresse eines Feeds oder einfach einer Website ein; die App sucht den Feed selbst. Mehrere Adressen, eine pro Zeile, landen gemischt in einer Spalte.", "`⌘T`, then **RSS & Feedly** at the top. Enter the address of a feed, or just of a website; the app finds the feed itself. Several addresses, one per line, share one column."),
                tr("Artikel zeigen Quelle, Titel, den Anfang des Textes und ein Bild. Ein Klick öffnet den ganzen Text in der Spalte, ohne die Seite des Anbieters zu laden. Von dort geht es in den Browser oder zum Teilen auf Bluesky oder Mastodon.", "Articles show their source, title, the start of the text and a picture. A click opens the whole text inside the column, without loading the publisher's page. From there, open it in the browser or share it on Bluesky or Mastodon."),
                tr("Filter, Suchen in der Spalte, Favoriten und die Tastatur funktionieren wie bei Posts. `j` `k` wählt, `↩` öffnet, `q` teilt.", "Filters, searching a column, favorites and the keyboard work as with posts. `j` `k` select, `↩` opens, `q` shares."),
                tr("**Feeds bearbeiten** im Menü `…` der Spalte ändert Adressen und Namen.", "**Edit Feeds** in the column's `…` menu changes addresses and name."),
                tr("**Feedly:** Am einfachsten exportierst du deine Abos bei Feedly als OPML-Datei und importierst sie hier. Jeder Ordner wird eine Spalte in einem neuen Deck, und die App liest die Feeds danach selbst.", "**Feedly:** The simplest way is to export your subscriptions from Feedly as an OPML file and import it here. Every folder becomes a column in a new deck, and the app then reads the feeds itself."),
                tr("Direkt verbinden geht mit einem Feedly-Zugangsschlüssel unter `⌘,` → Feeds & Filter. Feedly gibt solche Schlüssel nur in bestimmten Abos heraus, und sie laufen ab.", "Connecting directly works with a Feedly access token under `⌘,` → Feeds & Filters. Feedly hands out such tokens only on some plans, and they expire."),
                tr("Feeds werden nur über verschlüsselte Verbindungen gelesen. Ein Feed, der nur `http://` anbietet, lässt sich nicht einbinden.", "Feeds are only read over encrypted connections. A feed that offers only `http://` cannot be added."),
            ]),
            HelpTopic(id: "iocs", icon: "shield.lefthalf.filled", title: tr("IOCs nachschlagen", "Looking up IOCs"), bullets: [
                tr("In allen Spalten, auch bei RSS, Mastodon und in der Leseansicht, markiert die App **IOCs** orange mit gepunkteter Linie: MD5-, SHA-1-, SHA-256- und SHA-512-Hashes, IPv4- und IPv6-Adressen, CVE- und EUVD-Nummern, E-Mail-Adressen, Domains und Adressen.", "In every column, RSS, Mastodon and the reading view included, the app marks **IOCs** in orange with a dotted line: MD5, SHA-1, SHA-256 and SHA-512 hashes, IPv4 and IPv6 addresses, CVE and EUVD numbers, email addresses, domains and addresses."),
                tr("Auch entschärfte Schreibweisen zählen, etwa `evil[.]com`, `1.2.3[.]4`, `hxxps://…` oder `name[@]example[.]com`.", "Defanged forms count too, such as `evil[.]com`, `1.2.3[.]4`, `hxxps://…` or `name[@]example[.]com`."),
                tr("**Hovern** über einen IOC oder Link öffnet nach einem kurzen Moment eine Karte: was es ist, bei Links Domain und volle Adresse, und Live-Infos. Bei CVEs: CVSS, Ausnutzung laut CISA KEV, EPSS, die Beschreibung von NVD und der passende Eintrag in der europäischen Schwachstellendatenbank EUVD mit Produkt und Link. Bei EUVD-Nummern: der EUVD-Eintrag und die CVE dahinter. Bei IPs: Netzbetreiber, Land, offene Ports und das Urteil von GreyNoise. Bei Domains: urlscan.io. Bei Hashes: CIRCL.", "**Hovering** over an IOC or link opens a card after a moment: what it is, for links the domain and full address, and live info. For CVEs: CVSS, exploitation per CISA KEV, EPSS, NVD's description and the matching entry in the European Vulnerability Database (EUVD) with product and link. For EUVD numbers: the EUVD entry and the CVE behind it. For IPs: network operator, country, open ports and GreyNoise's verdict. For domains: urlscan.io. For hashes: CIRCL."),
                tr("**Bewertungen** von VirusTotal und AbuseIPDB erscheinen, wenn du dort einen kostenlosen Schlüssel holst und unter `⌘,` → IOCs einträgst. Die Schlüssel bleiben im Schlüsselbund dieses Macs.", "**Ratings** from VirusTotal and AbuseIPDB appear once you get a free key there and enter it under `⌘,` → IOCs. The keys stay in this Mac's Keychain."),
                tr("Die Karte hat Knöpfe zum Weiterschauen im Browser und zum Kopieren. **Rechtsklick** auf einen IOC oder Link bietet dasselbe an. Ein **Klick** auf einen blauen Link öffnet ihn wie gewohnt, ein Klick auf einen orangen IOC öffnet ein Menü: nachsehen bei VirusTotal, AbuseIPDB, Shodan, GreyNoise, urlscan.io, crt.sh, MalwareBazaar, Hybrid Analysis, NVD, CVE.org oder CISA KEV, je nach Art. Dazu Kopieren und entschärft Kopieren.", "**Clicking** opens a menu: look it up on VirusTotal, AbuseIPDB, Shodan, GreyNoise, urlscan.io, crt.sh, MalwareBazaar, Hybrid Analysis, NVD, CVE.org or CISA KEV, depending on the kind. Plus Copy and Copy Defanged."),
                tr("Für Live-Infos erfahren die genannten Dienste den IOC, sobald die Maus darauf ruht. Private IP-Adressen werden nie gesendet. Ohne Live-Infos (`⌘,` → IOCs) bleibt alles auf deinem Mac. Entschärft geschriebene Adressen öffnet die App nie direkt im Browser.", "For live info, the services named learn the IOC as soon as the mouse rests on it. Private IP addresses are never sent. With live info off (`⌘,` → IOCs), everything stays on your Mac. Addresses written defanged are never opened directly in the browser."),
                tr("Domains ohne Klammern zählen nur mit bekannter Endung wie `.com` oder `.de`, damit Dateinamen wie `README.md` Text bleiben.", "Domains without brackets only count with a known ending such as `.com` or `.de`, so file names like `README.md` stay text."),
                tr("Der Filter **Nur Einträge mit IOCs** zeigt nur Einträge mit Hashes, IPs, CVEs oder entschärften Adressen. Gewöhnliche Links zählen dort nicht.", "The filter **Only items with IOCs** shows only items with hashes, IPs, CVEs or defanged addresses. Ordinary links do not count there."),
                tr("Das **Schild** in der Seitenleiste schaltet Live-Infos schnell ein und aus: orange heißt an, durchgestrichen heißt aus. Hervorhebung und Live-Infos gibt es auch unter `⌘,` → IOCs.", "The **shield** in the sidebar switches live info on and off quickly: orange means on, crossed out means off. Highlighting and live info are also under `⌘,` → IOCs."),
            ]),
            HelpTopic(id: "columns", icon: "rectangle.split.3x1", title: tr("Spalten", "Columns"), bullets: [
                tr("`⌘T` fügt eine Spalte hinzu: Home, Mitteilungen, Erwähnungen, Meine Posts, Suche, Profil, gespeicherter Feed oder ein Feed oder eine Liste per Link.", "`⌘T` adds a column: Home, notifications, mentions, My Posts, search, profile, saved feed, or a feed or list by link."),
                tr("Zum **Sortieren** ziehst du den Spaltenkopf auf eine andere Spalte. Das Menü `…` kann das auch.", "To **reorder**, drag a column header onto another column. The `…` menu can do it too."),
                tr("Das Menü `…` stellt außerdem die **Breite** ein, von Schmal bis Extra breit, und entfernt die Spalte.", "The `…` menu also sets the **width**, from Narrow to Widest, and removes the column."),
                tr("Passen nicht alle ins Fenster, nennt die **Leiste unten** die verdeckten mit Anzahl und Namen. Als verdeckt gilt, was zu weniger als der Hälfte sichtbar ist.", "When not all fit the window, the **bottom bar** gives the count and names of the hidden ones. A column counts as hidden when less than half of it shows."),
                tr("Spalten aktualisieren sich selbst. Während du weiter unten liest, warten neue Posts hinter dem Knopf **„neu“**, damit nichts verrutscht.", "Columns refresh on their own. While you read further down, new posts wait behind the **“new”** button, so nothing jumps."),
            ]),
            HelpTopic(id: "search", icon: "magnifyingglass", title: tr("Suchen", "Search"), bullets: [
                tr("**In ganz Bluesky:** die Lupe links oder `⌘⇧F`. `↩` sucht in Posts, Personen werden beim Tippen vorgeschlagen, und `@name` öffnet ein Profil. Dafür brauchst du ein Konto.", "**All of Bluesky:** the magnifying glass on the left or `⌘⇧F`. `↩` searches posts, people are suggested as you type, and `@name` opens a profile. You need an account for this."),
                tr("Das Ergebnis steht vorübergehend neben dem Deck. Der Stern speichert es als Favorit, die Stecknadel macht es zur Spalte.", "The result sits next to the deck for now. The star saves it as a favorite, the pin makes it a column."),
                tr("**In einer Spalte:** die Lupe im Spaltenkopf oder `⌘F`. Es zählen auch Wortteile und Autorennamen, und alle eingegebenen Wörter müssen vorkommen. `Esc` beendet die Suche.", "**In one column:** the magnifying glass in the column header or `⌘F`. Parts of words and author names count too, and all words you enter must appear. `Esc` ends the search."),
                tr("Die Spaltensuche durchsucht geladene Einträge und lädt einmalig bis zu fünf Seiten nach. „Weiter suchen“ holt ältere.", "The column search looks through loaded items and fetches up to five more pages once. “Keep Searching” gets older ones."),
            ]),
            HelpTopic(id: "filters", icon: "line.3.horizontal.decrease.circle", title: tr("Filter", "Filters"), bullets: [
                tr("Das **Filter-Symbol** im Spaltenkopf öffnet die Einstellungen der Spalte. Änderungen wirken sofort.", "The **filter icon** in the column header opens that column's filter. Changes apply at once."),
                tr("**Nur mit diesen Wörtern:** Es reicht, wenn einer der Begriffe vorkommt. Trenne sie mit Komma.", "**Only with these words:** One of the terms is enough. Separate them with commas."),
                tr("**Immer ausblenden** hat Vorrang vor „Nur mit diesen Wörtern“. `@name.bsky.social` blendet einen Autor aus.", "**Always hide** beats “Only with these words”. `@name.bsky.social` hides an author."),
                tr("**Immer zeigen** schlägt alles andere: Ein Eintrag mit einem dieser Begriffe bleibt sichtbar, auch wenn ein anderer Filter ihn ausblenden würde.", "**Always show** beats everything else: an item with one of these terms stays visible even if another filter would hide it."),
                tr("**Gespeicherte Filter:** „Als Filter speichern …“ gibt den Regeln einen Namen. Danach schaltest du sie in jeder Spalte mit einem Haken dazu. Verwalten unter `⌘,` → Feeds & Filter. Eine Änderung gilt in allen Spalten, die den Filter benutzen.", "**Saved filters:** “Save as Filter…” gives the rules a name. Then tick them in any column. Manage them under `⌘,` → Feeds & Filters. A change applies to every column that uses the filter."),
                tr("Es zählen ganze Wörter: „art“ trifft nicht „Party“. Groß- und Kleinschreibung und Akzente sind egal.", "Whole words count: “art” does not match “party”. Case and accents do not matter."),
                tr("Durchsucht werden auch Link-Adressen, Link-Karten, Zitate und Bildbeschreibungen.", "Link addresses, link cards, quotes and image descriptions are searched too."),
                tr("Außerdem gelten deine Bluesky-Einstellungen: stummgeschaltete Wörter und Regeln für gekennzeichnete Inhalte. Eigene Posts sind davon ausgenommen.", "Your Bluesky settings apply too: muted words and rules for labeled content. Your own posts are exempt."),
                tr("Bleibt zu wenig übrig, lädt die Spalte einmalig bis zu fünf Seiten nach. Danach geht es beim Scrollen oder mit **Weiter suchen** weiter.", "If too little remains, the column loads up to five more pages once. After that, continue by scrolling or with **Keep Searching**."),
            ]),
            HelpTopic(id: "people", icon: "person.crop.circle", title: tr("Personen und Profile", "People and profiles"), bullets: [
                tr("**Rechtsklick auf eine Person** geht überall: auf dem Post, dem Bild, bei „hat repostet“, in Zitaten und Mitteilungen.", "**Right-clicking a person** works everywhere: on the post, the picture, “reposted”, in quotes and notifications."),
                tr("Das Menü bietet: alle Posts in neuer Spalte, Profil anzeigen, zu Favoriten hinzufügen.", "The menu offers: all posts in a new column, show profile, add to favorites."),
                tr("Ein **Klick aufs Bild** oder auf eine @Erwähnung zeigt das Profil in derselben Spalte, mit Posts, Antworten, Medien und Folgen. **Zurück** führt zur Timeline.", "A **click on the picture** or an @mention shows the profile in the same column, with posts, replies, media and following. **Back** returns to the timeline."),
                tr("Text markierst du durch Ziehen mit der Maus und kopierst ihn mit `⌘C` oder per Rechtsklick. Ein einfacher Klick öffnet weiterhin den Thread.", "Select text by dragging with the mouse and copy it with `⌘C` or a right-click. A plain click still opens the thread."),
                tr("Ein Klick auf einen Post öffnet seinen **Thread** in der Spalte. Hashtags öffnen eine Suchspalte.", "Clicking a post opens its **thread** in the column. Hashtags open a search column."),
                tr("Im Profil zeigen Klicks auf **Follower** und **Folgt** die Listen. Beim Eintippen von Namen erscheinen Vorschläge.", "On a profile, clicking **Followers** and **Following** shows the lists. Suggestions appear as you type a name."),
                tr("**Stummschalten** und **Blockieren** gehen per Rechtsklick und wirken auf deinem Bluesky-Konto. Rückgängig machst du sie über `…` im Profil.", "**Mute** and **block** are in the right-click menu and apply to your Bluesky account. Undo them with `…` on the profile."),
            ]),
            HelpTopic(id: "ownposts", icon: "text.bubble", title: tr("Meine Posts und Reaktionen", "My posts and reactions"), bullets: [
                tr("**Meine Posts:** Klick auf dein Konto-Bild unten links, dann „Meine Posts anzeigen“. Oder als Spaltentyp unter `⌘T`.", "**My Posts:** Click your account picture at the bottom left, then “Show My Posts”. Or as a column type under `⌘T`."),
                tr("Die Spalte zeigt alles, was du gepostet und repostet hast, mit genauem Datum und Uhrzeit.", "The column shows everything you posted and reposted, with the exact date and time."),
                tr("Unter jedem Post stehen Likes, Reposts, Zitate und Antworten. Ein **Klick auf die Zahlen** zeigt, wer geliked, repostet oder zitiert hat.", "Below each post are likes, reposts, quotes and replies. A **click on the numbers** shows who liked, reposted or quoted."),
                tr("Bei allen anderen Posts geht das per Rechtsklick und „Reaktionen anzeigen“.", "For any other post, right-click and choose “Show Reactions”."),
            ]),
            HelpTopic(id: "decks", icon: "rectangle.stack", title: tr("Mehrere Decks", "Several decks"), bullets: [
                tr("Das Stapel-Symbol links wechselt zwischen eigenen Spalten-Sets, zum Beispiel „Arbeit“ und „Privat“. Dort legst du sie auch an, benennst sie um und löschst sie.", "The stack icon on the left switches between your own sets of columns, such as “Work” and “Private”. You also create, rename and delete them there."),
                tr("`⌘1` bis `⌘9` wechseln direkt.", "`⌘1` to `⌘9` switch directly."),
            ]),
            HelpTopic(id: "messages", icon: "envelope", title: tr("Direktnachrichten", "Direct messages"), bullets: [
                tr("Dein Konto-Bild unten links, dann „Direktnachrichten anzeigen“.", "Your account picture at the bottom left, then “Show Direct Messages”."),
                tr("„Neue Nachricht“ oben in der Spalte sucht eine Person und öffnet die Unterhaltung. Alternativ: „Nachricht“ in ihrem Profil. Verschickt wird erst, was du dort schreibst.", "“New Message” at the top of the column finds a person and opens the conversation. Or use “Message” on their profile. Only what you write there is sent."),
                tr("Dafür braucht dein [App-Passwort](https://bsky.app/settings/app-passwords) die Option „Allow access to your direct messages“. Fehlt sie, erstelle ein neues und melde dich damit neu an.", "Your [app password](https://bsky.app/settings/app-passwords) needs the option “Allow access to your direct messages”. If it is missing, create a new one and sign in with it."),
                tr("Eine neue Unterhaltung startest du mit „Nachricht“ im Profil einer Person.", "Start a new conversation with “Message” on a person's profile."),
                tr("Bilder lassen sich in Bluesky-Chats nicht verschicken. Links werden automatisch verlinkt.", "Bluesky chats cannot carry pictures. Links are linked automatically."),
            ]),
            HelpTopic(id: "notifications", icon: "bell.badge", title: tr("Mitteilungen", "Notifications"), bullets: [
                tr("Das Dock-Symbol und die Spalte zeigen die Zahl ungelesener Mitteilungen.", "The Dock icon and the column show the number of unread notifications."),
                tr("„Alle als gelesen markieren“ im Menü `…` der Spalte setzt sie auf deinem Konto zurück, also auch in anderen Bluesky-Apps. Von selbst passiert das nicht.", "“Mark All as Read” in the column's `…` menu resets them on your account, so also in other Bluesky apps. It does not happen by itself."),
                tr("macOS-Hinweise schaltest du in den Einstellungen ein.", "Turn on macOS alerts in Settings."),
            ]),
            HelpTopic(id: "favorites", icon: "star", title: tr("Favoriten", "Favorites"), bullets: [
                tr("`⌘D` oder der Stern links öffnet die Liste. Favoriten belegen keine Spalte.", "`⌘D` or the star on the left opens the list. Favorites do not take up a column."),
                tr("**Hinzufügen:** `@name`, `#tag`, einen Suchbegriff oder einen Bluesky-Link eintippen, per Rechtsklick auf eine Person, oder im Spaltenmenü.", "**Add:** Type `@name`, `#tag`, a search term or a Bluesky link, right-click a person, or use the column menu."),
                tr("**„In Favoriten verschieben“** im Spaltenmenü macht das Deck frei und behält den Inhalt griffbereit.", "**“Move to Favorites”** in the column menu frees up the deck and keeps the content close at hand."),
                tr("Ein **Klick** zeigt den Inhalt vorübergehend an. Die **Stecknadel** macht daraus eine feste Spalte.", "A **click** shows the content temporarily. The **pin** turns it into a permanent column."),
                tr("Zum Sortieren ziehst du sie innerhalb ihrer Gruppe. Hashtags fügst du per Rechtsklick auf einen Post hinzu.", "To sort, drag them within their group. Add hashtags with a right-click on a post."),
                tr("Mit iCloud erscheinen sie auch auf deinen anderen Macs.", "With iCloud they also appear on your other Macs."),
            ]),
            HelpTopic(id: "posting", icon: "square.and.pencil", title: tr("Posten", "Posting"), bullets: [
                tr("`⌘N` öffnet den Composer. `⌘↩` sendet. Der Zähler zeigt die verbleibenden Zeichen von 300.", "`⌘N` opens the composer. `⌘↩` sends. The counter shows how many of the 300 characters remain."),
                tr("Links, @Erwähnungen und #Hashtags werden automatisch verlinkt.", "Links, @mentions and #hashtags are linked automatically."),
                tr("**Antworten** und **Zitieren** startest du unter dem jeweiligen Post. Dort liegen auch **Liken** und **Reposten**.", "Start **replies** and **quotes** below the post in question. **Like** and **repost** are there too."),
                tr("**Bilder:** bis zu vier pro Post, per Knopf oder Drag & Drop, mit Bildbeschreibung. Sie werden verkleinert, und Metadaten wie der GPS-Standort werden entfernt. In den Einstellungen kannst du die Beschreibung verpflichtend machen.", "**Pictures:** up to four per post, by button or drag and drop, with a description. They are scaled down, and metadata such as the GPS location is removed. In Settings you can make the description mandatory."),
                tr("**Video:** ein MP4 im ersten Post, statt Bildern. Bluesky verarbeitet es, das dauert einen Moment.", "**Video:** one MP4 in the first post, instead of pictures. Bluesky processes it, which takes a moment."),
                tr("**Wer darf antworten:** Unter dem Text legst du das für einen neuen Thread fest.", "**Who can reply:** Set this for a new thread below the text."),
                tr("Mit mehreren Konten wählst du oben im Composer, wer postet.", "With several accounts, choose at the top of the composer who posts."),
                tr("**Threads:** „Weiterer Post im Thread“ fügt Posts hinzu. Sie gehen als Antwortkette raus.", "**Threads:** “Another post in thread” adds posts. They go out as a chain of replies."),
                tr("**Entwürfe:** Text und Bilder werden laufend gesichert, auch beim Schließen. Das Menü „Entwürfe“ holt sie zurück. Videos bleiben dabei nicht erhalten.", "**Drafts:** Text and pictures are saved as you go, also when you close. The “Drafts” menu brings them back. Videos are not kept."),
                tr("**Planen:** „Planen …“ sendet später. Die App muss dann laufen und der Mac wach sein. Hat sie den Zeitpunkt um mehr als 15 Minuten verpasst, fragt sie erst nach.", "**Schedule:** “Schedule…” sends later. The app must be running and the Mac awake. If it missed the time by more than 15 minutes, it asks first."),
                tr("Bilder fügst du auch mit `⌘V` ein. Eigene Posts löschst du per Rechtsklick.", "You can also paste pictures with `⌘V`. Delete your own posts with a right-click."),
            ]),
            HelpTopic(id: "media", icon: "photo.on.rectangle", title: tr("Bilder und Videos", "Pictures and videos"), bullets: [
                tr("Ein Klick öffnet Bilder und Videos im Fenster. `Esc` schließt, die Pfeiltasten blättern durch Bilder.", "A click opens pictures and videos in the window. `Esc` closes, the arrow keys page through pictures."),
                tr("Hochformate werden in der Spalte beschnitten, damit ein Post nicht alles füllt. In der Großansicht siehst du sie ganz.", "Portrait media is cropped in the column so one post does not fill it. The large view shows all of it."),
                tr("In den Einstellungen kannst du die Vorschauen abschalten. Posts zeigen dann nur einen kleinen Knopf.", "In Settings you can turn the previews off. Posts then only show a small button."),
            ]),
            HelpTopic(id: "settings", icon: "gearshape", title: tr("Einstellungen", "Settings"), bullets: [
                tr("`⌘,` oder das Zahnrad links öffnet die Einstellungen.", "`⌘,` or the gear on the left opens Settings."),
                tr("**Sprache:** Deutsch, Englisch oder wie das System. Der Wechsel wirkt sofort.", "**Language:** German, English or same as system. The change applies at once."),
                tr("**Automatisch aktualisieren:** von 30 Sekunden bis 5 Minuten, oder nie.", "**Refresh automatically:** from 30 seconds to 5 minutes, or never."),
                tr("Außerdem: Breite neuer Spalten, Medienanzeige, Textgröße, Tastatursteuerung, Mitteilungen, Sprache neuer Posts und deine Konten.", "Also: width of new columns, media display, text size, keyboard control, notifications, language of new posts, and your accounts."),
            ]),
            HelpTopic(id: "keys", icon: "keyboard", title: tr("Tastenkürzel", "Keyboard shortcuts"), bullets: [
                tr("`⌘N` Neuer Post", "`⌘N` New post"),
                tr("`⌘↩` Post absenden", "`⌘↩` Send post"),
                tr("`⌘T` Spalte hinzufügen", "`⌘T` Add column"),
                tr("`⌘⇧F` Bluesky durchsuchen, `⌘F` in Spalte suchen", "`⌘⇧F` Search Bluesky, `⌘F` Search in column"),
                tr("`⌘D` Favoriten ein- oder ausblenden", "`⌘D` Show or hide favorites"),
                tr("`⌘R` Alle Spalten aktualisieren", "`⌘R` Refresh all columns"),
                tr("`j` `k` Nächster und vorheriger Post", "`j` `k` Next and previous post"),
                tr("`←` `→` oder `1`–`9` Spalte wählen", "`←` `→` or `1`–`9` Choose column"),
                tr("`↩` Thread öffnen, `Esc` zurück", "`↩` Open thread, `Esc` back"),
                tr("`l` Liken, `t` Reposten, `r` Antworten, `q` Zitieren", "`l` Like, `t` Repost, `r` Reply, `q` Quote"),
                tr("`n` Neuer Post, `a` Spalte hinzufügen", "`n` New post, `a` Add column"),
                tr("`⌘1`–`⌘9` Deck wechseln", "`⌘1`–`⌘9` Switch deck"),
                tr("`⌘,` Einstellungen", "`⌘,` Settings"),
                tr("`⌘?` Hilfe", "`⌘?` Help"),
                tr("`Esc` Großansicht oder Composer schließen", "`Esc` Close large view or composer"),
                tr("`←` `→` In der Großansicht blättern", "`←` `→` Page in the large view"),
            ]),
            HelpTopic(id: "privacy", icon: "lock", title: tr("Daten und Datenschutz", "Data and privacy"), bullets: [
                tr("Dein Passwort wird nicht gespeichert. Die App behält nur Sitzungstoken im Schlüsselbund von macOS.", "Your password is not stored. The app only keeps session tokens in the macOS Keychain."),
                tr("Decks mit ihren Spalten und Filtern, Favoriten und Entwurfstexte liegen in deinem privaten iCloud, wenn die Synchronisierung an ist. Einstellungen bleiben auf diesem Mac. Nichts davon ändert dein Bluesky-Konto.", "Decks with their columns and filters, favorites and draft text are in your private iCloud when sync is on. Settings stay on this Mac. None of this changes your Bluesky account."),
                tr("Liken, Reposten, Folgen, Blockieren und Posten sind öffentlich sichtbar. Stummschalten, Lesezeichen und Gelesen-Markierungen liegen privat auf deinem Konto.", "Liking, reposting, following, blocking and posting are publicly visible. Mutes, bookmarks and read state are stored privately on your account."),
                tr("Geplante Posts, Entwurfsbilder und Anmeldungen bleiben auf diesem Mac.", "Scheduled posts, draft pictures and sign-ins stay on this Mac."),
                tr("Die App spricht nur mit deinem Bluesky-Server und den öffentlichen Bluesky-Diensten.", "The app only talks to your Bluesky server and the public Bluesky services."),
            ]),
        ]
    }
}
