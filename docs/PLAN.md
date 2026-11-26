# Xool OS – Bauplan

Ein schneller, nativer macOS-Browser mit KI-Agents (lokal zuerst, Cloud per API-Key optional), Second Brain, Sprachsteuerung mit Duplex-Mechanik und einer Design-Fläche mit Notion-artigen `/`-Blöcken.

Stand: 2026-11-26 · Status: Phasen 0–9 umgesetzt.

---

## 1. Entscheidung: Fork von `driceroland/Search` als Fundament

**Empfehlung: Search mit Git-Historie ins Repo importieren und als Basis umbauen**, nicht neu schreiben.

Warum:

- Search ist ein fertiger, schneller WebKit-Browser (AppKit, Swift 6 Toolchain, macOS 14+, ~14 MB, MIT-Lizenz). Tabs links/oben, `⌘K`-Tab-Switcher, Split View, Adblock vor dem Laden, Reader, Passwörter im Keychain, Bookmarks, History, Spaces.
- Es bringt bereits genau die Bausteine mit, die wir sonst selbst bauen müssten:
  - `AI.swift` / `AIClient.swift`: Provider **Anthropic, OpenAI, Gemini, OpenRouter, Ollama, LM Studio** und ein eingebautes Modell, Keys im Keychain, Streaming per SSE, Key wird nur an den eigenen Host geschickt.
  - `AgentControl.swift` / `AgentBanner.swift` / `AgentTrust.swift`: Ein Agent steuert **eigene Tabs** des offenen Fensters (read_page, click, type, wait_for), mit Erlaubnis-Dialog, sichtbarem Banner und Stop-Knopf. Das ist die Grundlage für „man sieht live, wie der Agent im Web sucht“.
  - `search-mcp`: MCP-Server, damit Claude Code/Codex den Browser benutzen können.

Vorgehen:

```bash
git remote add upstream https://github.com/driceroland/Search.git
git fetch upstream
git merge upstream/main --allow-unrelated-histories
```

Danach umbenennen (Target `Search` → `XoolOS`, Bundle-ID, App-Support-Ordner `~/Library/Application Support/Xool/`), `LICENSE` + `THIRD_PARTY_NOTICES.md` behalten und um einen Abschnitt „Basiert auf Search von Office Commun (MIT)“ ergänzen. `upstream` bleibt als Remote, damit Fixes aus Search übernommen werden können.

### Was aus Search bleibt / rausfliegt

| Bleibt | Fliegt raus (vorerst) |
|---|---|
| Browser, Tab, TabBar, Side, TabSwitcher, Omnibox, Address, Split, Spaces, Pins | `DevToolsFull`, `DevToolsLite`, `DevToolsShared` (großer Ballast) |
| Shield (Adblock), Reader, Hidden, Float/PiP | `Updater`, `UpdateNotice`, `publish.sh`, `tap.sh` (signiert auf Office Commun) |
| Passwords, Passkeys, Keychain-Vault | `ICloudSync`, `Sync*`, `Handoff` (später neu, eigener Container) |
| Bookmarks, History, Downloads | `Welcome`, `WhatsNew`, `IPhoneAsk`, alles, was an searchbrowser.app sendet |
| AI*, Agent* | `HomeStickers`, `HomeWalls`, `Import*` für Arc/Zen (später optional) |
| Settings, Prefs, Store, Shortcuts | Tests, die rausgeflogene Teile prüfen |

Ziel von Phase 0: `./build.sh` baut `Xool OS.app`, startet, lädt Seiten, keine Netzwerkanfrage an Office-Commun-Server.

---

## 2. Was aus `Paulito12209/jarvis-on-nod` übernommen wird

Jarvis besteht aus zwei Teilen: einer **Einrichtungs-Anleitung** (Ollama + Modell + 64k Kontext + Nod) und **Jarvis Stimme** (Python, ~2.700 Zeilen): Whisper (mlx) → Ollama (Streaming) → Piper TTS, mit Silero-VAD, Barge-in, Brückenphrasen, kleinem Entscheidungsmodell und Vorausdenken.

Übernommen wird nur, was die Fähigkeiten **mit einem Befehl** in Xool OS bringt:

| Jarvis-Teil | In Xool OS |
|---|---|
| `scripts/jarvis-mac.sh` (RAM prüfen, Modell wählen, Ollama installieren, `OLLAMA_CONTEXT_LENGTH=65536`, Modell laden, Tool-Test) | `scripts/xool-setup.sh`, angepasst. Zusätzlich in der App: **Einstellungen › Modelle › „Lokale KI einrichten“** startet dasselbe Skript mit sichtbarem Fortschritt. |
| `stimme/jarvis_stimme/*` (Stimme, Duplex) | **Phase A:** als Sidecar im App-Bundle (`Resources/voice/`), per `uv` in eine venv unter `~/Library/Application Support/Xool/voice` installiert, spricht mit der App über einen lokalen WebSocket. **Phase B:** nativ in Swift ersetzt (siehe 6.4). |
| `llm.py` `MODEL_PREFERENCE` (schnelle MoE-Modelle zuerst) | Standard-Reihenfolge im `ModelRouter`. |
| `app.py` „winziges Modell entscheidet, ob du Jarvis meinst“ | `DecisionModel` (siehe 6.3). |
| `bruecken.py` (Brückenphrasen, vorab vertont) | Duplex: Antwort-Lücke füllen. |
| `vorausdenken.py` (Thinker) | Hintergrund-Notizen pro Thread, „Übrigens …“-Vorschlag. |
| `werkzeuge.py` `web_suche` (DDGS / SearXNG) | Agent-Tool `web_search`, zusätzlich echter Browser-Tab statt nur API. |
| Nod (Browser, Dateien, Mail, Kalender, Erinnerungen) | Nod wird **nicht** eingebettet. Die Werkzeuge werden nativ: Browser = Xool selbst, Dateien = Second Brain + FileManager, Kalender/Erinnerungen = EventKit, Mail = `mailto:`/Mail.app per AppleScript. Optional: Nod über MCP anbinden. |

Ein-Befehl-Weg für Nutzer:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/xool-os/main/scripts/xool-setup.sh | bash
```

Prüft den Mac, installiert/konfiguriert Ollama, lädt das passende Modell (48 GB+ → `qwen3.6:35b`, darunter `gpt-oss:20b`), richtet die Stimme ein und testet Tool-Calling. Löscht nichts, kein Admin-Passwort.

---

## 3. Design-System „Xool“ (Linear-clean)

Grundlage: Frontend-Design-Skill (eigene Haltung statt Template) + UI/UX-Pro-Max-Skill (`--design-system`, Dichte 8, Varianz 3, Motion 3).

**Abgleich mit UI/UX Pro Max:** Das Tool empfahl *Minimalism & Swiss Style* und *Inter* (passt), aber eine helle Teal/Orange-Palette. Die verwerfen wir, weil der Auftrag ausdrücklich das ruhige, dunkle Linear-Bild verlangt und Orange als zweite Akzentfarbe mit den Agent-Farben konkurrieren würde. Übernommen werden die Prüfliste (Kontrast 4.5:1, sichtbarer Fokus, `reduce motion`, SVG/SF-Symbol-Icons statt Emoji, Hover 150–250 ms) und die dichte Abstandsskala.

### Die eine mutige Stelle

Alles am Fenster ist grau, leise und gleichmäßig. **Farbe gibt es nur an den Agents**: jeder Agent hat eine eigene Farbe und ein kleines Gesicht (Blob mit zwei Augen, wie im Referenzbild). Diese Farbe taucht überall auf, wo der Agent etwas tut: in der Agent-Leiste unten, als Ring um „seinen“ Tab, als Rand seines Threads, als Cursor auf der Webseite, die er gerade bedient. So sieht man auf einen Blick, *wer* gerade *was* macht.

### Tokens

Farben (Dark, Standard):

| Token | Hex | Rolle |
|---|---|---|
| `canvas` | `#0E0F11` | Fensterhintergrund, Sidebar |
| `surface` | `#16171A` | Inhaltsfläche, Listen |
| `raised` | `#1E1F23` | Popover, Thread-Fenster, Hover-Zeilen |
| `line` | `#2A2B30` | Haarlinien 1 px |
| `text` | `#E8E8EA` | Primärtext (Kontrast > 12:1) |
| `text-muted` | `#8D919A` | Sekundärtext, Metadaten (≥ 4.6:1 auf `surface`) |
| `focus` | `#7C86E8` | Fokusring, Auswahl, Links in der Chrome |

Light-Modus spiegelt die Stufen (`canvas #F7F7F8`, `surface #FFFFFF`, `raised #F1F1F3`, `line #E4E4E7`, `text #1B1C1F`, `text-muted #6B6F78`). Die Seitenfarbe folgt dem Mac.

Agent-Farben (Startset, frei wählbar): Grün `#7BC47F`, Orange `#E07B45`, Blau `#5B7FE6`, Violett `#8B6CEB`, Teal `#6FB8A6`, Rosa `#D9719A`. Jede Farbe hat eine 12%-Fläche (`agent.bg`) und volle Farbe für Ring/Avatar.

Typografie: **Inter Variable** (im Bundle, wie Linear), eine Familie. Skala 11 / 12 / 13 (Basis) / 15 / 20 px; Gewichte 450 Text, 550 Labels/Navigation, 650 Überschriften. Ziffern tabellarisch (`tnum`) in Listen. Keine Großbuchstaben-Labels, keine Mono-Schrift für Metadaten.

Form: Radien nach Hierarchie: 4 px Chips/Pills, 6 px Zeilen und Buttons, 10 px Popover und Thread-Fenster, 14 px Agent-Avatare (Squircle). Schatten nur bei schwebenden Elementen (Thread-Fenster, Command-Palette), sonst Haarlinien. Abstände: 4 / 8 / 12 / 16 / 24 / 32.

Bewegung: nur als Antwort auf eine Aktion. Thread-Fenster wächst aus der angeklickten Agent-Pill (180 ms, ease-out); Wechsel Schwebefenster ↔ Seitenleiste als ein Morph (220 ms). Ein „denkt“-Zustand: Augen des Avatars blinzeln. Bei `reduce motion` alles sofort.

Klickflächen: mindestens 28×28 pt (macOS-Zeiger), Pills 28 pt hoch.

---

## 4. Fenster-Layout

```
┌───────────────┬─────────────────────────────────────────────────────────────┐
│ ● ● ●  Xool ▾ │  ‹  ›  ⟳   [ Adresse oder Frage an einen Agent …      ]  ⌘K │
│               ├─────────────────────────────────────────────────────────────┤
│  ⌕ Suchen     │                                                             │
│  ◫ Inbox    1 │                                                             │
│  ◉ Brain      │                  Webseite / Brain / Canvas                  │
│  ▢ Canvas     │                                                             │
│               │                                           ┌───────────────┐ │
│ Gepinnt       │                                           │ ● Launch Bot ⤢×│ │
│  ▣ ▣ ▣ ▣      │                                           │ Öffnet hn…  ↗ │ │
│ Agents        │                                           │ Liest Artikel │ │
│  ● Launch: hn │                                           │               │ │
│  ● Inbox: gm… │                                           │ [Nachricht…] 🎙│ │
│ Heute         │                                           └───────────────┘ │
│  ▢ linear.app │                                                             │
│  ▢ github.com │                                                             │
├───────────────┴─────────────────────────────────────────────────────────────┤
│ ◐ qwen3.6:35b · lokal ▾      ● Launch  ● Inbox  ● Mktg  ● Chief  +   ⌂ Agents│
└─────────────────────────────────────────────────────────────────────────────┘
```

Links ausgerichtet, eine durchgehende Grundlinie für Sidebar und Inhalt. Die untere Leiste gehört dem ganzen Fenster, nicht nur dem Inhalt.

### 4.1 Untere Leiste: „Agent-Leiste“

- **Links: Modell-Chip.** Zeigt das aktive Modell und ob es lokal (gefüllter Punkt) oder in der Cloud (Ring) läuft. Klick öffnet den Modell-Picker (4.4).
- **Mitte/rechts: Agent-Pills.** Jeder erstellte Agent als Pill in seiner Farbe: Mini-Avatar + Name. Reihenfolge per Drag änderbar, max. 7 sichtbar, Rest unter `…`. `⌥1`–`⌥9` ruft Agent 1–9.
  - **Klick auf eine Pill → öffnet sofort einen Thread mit diesem Agent** (neuer Thread oder letzter offener, einstellbar). Der Agent bringt seine Skills, sein Modell und seinen System-Prompt mit.
  - Zustand an der Pill: ruhig / denkt (blinzelt) / arbeitet im Browser (kleiner Tab-Zähler) / wartet auf dich (Punkt).
  - Rechtsklick: Neuer Thread, Letzte Threads, Agent bearbeiten, Aus Leiste entfernen.
- **`+`**: neuen Agent anlegen (Name, Farbe, Modell, Skills, Anweisungen).
- **Ganz rechts: „Agents“-Knopf.** Öffnet die Übersicht aller Agents (4.3).
- Gedrückt halten von `fn` (oder `⌥Leertaste`, einstellbar): Push-to-Talk an den zuletzt benutzten Agent.

### 4.2 Thread-Fenster

- **Standard: kleines Schwebefenster unten rechts** (380 × 520 pt, über dem Inhalt, verschiebbar, mehrere stapelbar als Tabs im Fensterkopf).
- Kopf: Avatar + Agent-Name, Modell-Chip, `–` minimieren (zurück in die Pill), `⤢` als Seitenleiste andocken, `⛶` groß, `×` schließen.
- **Einstellungen › Agents › „Threads öffnen als“: Schwebefenster unten rechts (Standard) / Seitenleiste rechts.** Seitenleiste: 400 pt, in der Breite ziehbar, schiebt die Webseite zur Seite statt sie zu verdecken.
- Inhalt: Nachrichten, darunter **Schritt-Protokoll** des Agents („Öffnet booking.com“, „Füllt Suche aus“, „Liest 3 Ergebnisse“). Jeder Browser-Schritt ist anklickbar und springt in den Tab, in dem er passiert.
- Eingabe: Textfeld mit `@` (Tab, Brain-Eintrag, Datei erwähnen), `/` (Skill aufrufen), Mikrofon-Knopf, Dateien per Drag.
- Leerer Thread: drei Skill-Vorschläge des Agents als Knöpfe, sonst nichts.

### 4.3 Agents-Übersicht (Knopf ganz rechts)

Wie der rechte Bereich im Referenzbild, als Panel von rechts (oder eigenes Fenster per `⇧⌘A`):

```
┌──────────────────────────────────────┐
│  Agents                     ⌕   +    │
│                                      │
│  ( •• )    ( •• )    ( •• )          │
│  Launch    Inbox     Mktg            │
│  Bot       Manager   Data            │
│                                      │
│  ( •• ) New Hires                    │
│         3 Intros in deinem Ton …     │
│  ( •• ) Expense Manager              │
│         Bericht eingereicht, 9 Bel…  │
│  ( •• ) Chief of Staff               │
│         Flug auf Freitag verschoben  │
│                                      │
│  ◐ Du · lokal: qwen3.6:35b           │
└──────────────────────────────────────┘
```

Oben: angepinnte Agents groß. Darunter: alle Agents nach letzter Aktivität, mit letzter Nachricht. Klick öffnet den Thread (gleiches Verhalten wie die Pill). Unten: eigenes Profil und aktives Standardmodell.

### 4.4 Modell-Auswahl und -Übersicht

- **Picker (Klick auf Modell-Chip):** Liste gruppiert nach *Lokal* (Ollama, LM Studio, eingebautes Modell; mit Größe und RAM-Ampel aus Jarvis) und *Cloud* (Anthropic, OpenAI, Gemini, OpenRouter; nur wenn ein Key hinterlegt ist). Suchfeld. Haken am aktiven Modell.
- **Einstellungen › Modelle:** pro Anbieter eine Zeile mit Status (verbunden / kein Key / läuft nicht), **API-Key-Feld** (Keychain, wird nur an den Host des Anbieters gesendet), „Verbindung testen“. Darunter Rollen-Zuordnung:
  - Chat (Standard), Agent & Werkzeuge, Entscheidung (klein, schnell), Embeddings (Brain), Stimme.
- Pro Agent kann das Modell überschrieben werden.
- Knopf „Lokale KI einrichten“ (startet `xool-setup.sh`, Fortschritt im Panel).

### 4.5 Tabs-Übersicht

- **Sidebar (Standard links):** Abschnitte *Gepinnt* (Icons), *Agents* (Tabs, die ein Agent gerade bedient, mit Ring in seiner Farbe und seinem Avatar), *Heute*, *Früher* (eingeklappt). Ziehen zwischen Abschnitten. `⌘S` blendet die Sidebar aus.
- **`⌘K` Tab-Switcher** (aus Search) erweitert um Agents, Threads, Brain-Einträge und Befehle.
- **Übersicht `⇧⌘\`:** Rasteransicht aller Tabs mit Vorschaubild, gruppiert nach Space und Agent; tippen filtert; Mehrfachauswahl zum Schließen/Verschieben.
- Agent-Tabs zeigen live, was passiert: Ring in Agent-Farbe, farbiger Zeiger auf der Seite, Banner oben mit „Stop“ (AgentBanner aus Search).

---

## 5. Architektur

```
Sources/
  XoolOS/                (bisher Sources/Search – Browser-Kern, umbenannt)
  XoolUI/                Design-Tokens, Agent-Leiste, Thread-Fenster, Übersichten
    Theme.swift          Tokens (Farben, Typo, Radien) – einzige Quelle für Werte
    AgentDock.swift      untere Leiste
    ThreadWindow.swift   Schwebefenster / Seitenleiste
    AgentsOverview.swift
    ModelPicker.swift
    TabsOverview.swift
  XoolAgents/
    Agent.swift          Name, Farbe, Avatar, Modell, Anweisungen, Skills
    AgentStore.swift     JSON in Application Support/Xool/agents
    Thread.swift         Nachrichten + Schritte, persistiert
    AgentRuntime.swift   Tool-Loop (streaming), Abbruch, Erlaubnisse
    Tools/               browser.*, web_search, brain.*, calendar.*, reminders.*, files.*
    Skills.swift         SKILL.md-Format (kompatibel zu Claude-Skills)
  XoolModels/
    ModelRouter.swift    Rollen → Provider/Modell, Fallback lokal → Cloud
    DecisionModel.swift  kleines Modell: Absicht, Tool ja/nein, lokal/Cloud
    OllamaCatalog.swift  /api/tags, /api/ps, Pull mit Fortschritt
  XoolVoice/
    VoiceBridge.swift    Phase A: WebSocket zum Python-Sidecar
    Duplex/              Phase B: nativ (VAD, STT, TTS, Barge-in, Brücken)
  XoolBrain/
    BrainStore.swift     SQLite (System-SQLite3) + FTS5, Dateien im Ordner
    Ingest.swift         PDFKit, Vision-OCR, QuickLook-Vorschau, Text
    Embeddings.swift     über Ollama (z. B. nomic-embed-text)
  XoolCanvas/            WKWebView-Host für die Design-Fläche
web/canvas/              Canvas + Block-Editor (TypeScript, gebündelt ins App-Bundle)
scripts/xool-setup.sh    Ein-Befehl-Einrichtung (aus jarvis-mac.sh)
Resources/voice/         jarvis_stimme (Phase A)
```

Keine neuen Swift-Abhängigkeiten (wie Search: nur Systemframeworks). UI in AppKit, wo Search AppKit nutzt; neue Panels dürfen SwiftUI in `NSHostingView` sein.

### 5.1 Agent-Runtime

1. Eingabe (Text oder Sprache) → `DecisionModel` (lokal, <300 ms): Ist das an den Agent gerichtet? Braucht es Werkzeuge? Reicht lokal oder Cloud (nur wenn erlaubt und Key da)?
2. `AgentRuntime` streamt die Antwort vom gewählten Modell, führt Tool-Calls aus, schreibt jeden Schritt ins Thread-Protokoll.
3. Browser-Tools rufen **intern** dieselben Funktionen wie `AgentControl` (eigene Agent-Tabs, Erlaubnis pro Agent und Domain, keine Passwörter/Karten/Codes, nie private Tabs). Kein Socket-Umweg innerhalb der App.
4. Agent-Tabs sind sichtbar und jederzeit mit „Stop“ beendbar.

### 5.2 Duplex-Mechanik

Aus Jarvis übernommen, auf Agents erweitert: Mikrofon hört weiter, während der Agent spricht (Barge-in stoppt Sprache und Generierung sofort); Brückenphrase nur, wenn die erste Antwort-Satz noch nicht da ist; Satz-für-Satz-TTS, während das Modell weiterschreibt; in Pausen bereitet der Thinker Notizen vor. Sprachbefehle können auch Browser-Aktionen sein („öffne meine Mails“, „such günstige Flüge nach Lissabon“), die man dann live im Agent-Tab sieht.

### 5.3 Second Brain

Ein Ort für alles: Dokumente, beliebige Dateien (Original bleibt als Datei, Text/OCR wird indiziert), Skills, Lesezeichen (verknüpft mit Search-Bookmarks), Notizen, gespeicherte Seiten (Reader-Text). Volltextsuche (FTS5) + semantische Suche (Embeddings lokal). Agents lesen/schreiben über `brain.search`, `brain.save`, `brain.read`. Alles unter `~/Library/Application Support/Xool/Brain`, nichts in einer Cloud.

### 5.4 Design-Fläche (Canvas + Blöcke)

Unendliche Fläche (Rahmen, Formen, Text, Bilder, Verbindungen, Zoom/Pan) wie Figma; jedes Text-Element ist ein Block-Dokument mit `/`-Menü wie Notion (Überschrift, Liste, Todo, Bild, Code, Tabelle, Brain-Verweis, Agent fragen). Umsetzung als lokale Web-App im WKWebView: Block-Editor auf **TipTap** (MIT) mit eigenem Slash-Menü, Canvas als eigene schlanke Engine (Canvas2D/SVG). Speichert in den Brain-Store. Agents können Blöcke und Frames erzeugen.

---

## 6. Phasen mit Abnahmekriterien

### Phase 0 – Fundament
- Search mit Historie importieren, `upstream`-Remote, umbenennen zu Xool OS, Streichliste aus Abschnitt 1 umsetzen.
- **Fertig, wenn:** `./build.sh` baut, App startet, Tabs/Seiten/`⌘K` funktionieren, `swift test` grün für verbleibende Tests, keine Anfragen an Office-Commun-Hosts (per `grep` und Netzwerk-Log geprüft).

### Phase 1 – UI-Hülle (Fokus dieses Plans)
- `Theme.swift` mit allen Tokens aus Abschnitt 3; Sidebar, Adressfeld und Settings auf Tokens umstellen; Inter einbinden.
- Agent-Leiste mit Modell-Chip, Pills, `+`, Agents-Knopf.
- Thread-Fenster (Schwebefenster + Seitenleiste) inkl. Einstellung „Threads öffnen als“.
- Agents-Übersicht, Modell-Picker, Tabs-Übersicht (`⇧⌘\`), Sidebar-Abschnitt „Agents“.
- Zunächst mit echtem Chat über `AIClient` (noch ohne Tools), damit die UI von Anfang an funktioniert.
- **Fertig, wenn:** Agent anlegen → erscheint als Pill → Klick öffnet Thread unten rechts → Nachricht bekommt gestreamte Antwort vom gewählten Modell; Umschalten auf Seitenleiste in den Einstellungen wirkt sofort; Modellwechsel im Chip wirkt auf den nächsten Turn; Fokus per Tastatur überall sichtbar; Light und Dark geprüft per Screenshot.

### Phase 2 – Modelle & API-Keys
- Settings › Modelle wie 4.4; Anthropic/OpenAI/Gemini/OpenRouter per Key, Ollama/LM Studio automatisch erkannt; Rollen; `OllamaCatalog` mit Pull-Fortschritt; `DecisionModel`.
- **Fertig, wenn:** Mit einem Claude-Key antwortet ein Agent über Anthropic; ohne Key und mit Ollama komplett lokal; Key liegt nur im Keychain.

### Phase 3 – Agents mit Werkzeugen, live im Browser
- AgentRuntime + Tool-Loop; Browser-Tools intern über AgentControl; `web_search`; Skills (SKILL.md); Schritt-Protokoll mit Sprung zum Tab; Ring/Zeiger in Agent-Farbe.
- **Fertig, wenn:** „Suche die drei neuesten Artikel zu X und fasse sie zusammen“ öffnet sichtbar einen Agent-Tab, man sieht Klicks und Navigation, Stop bricht sofort ab.

### Phase 4 – Jarvis: Ein-Befehl-Einrichtung & Stimme
- `scripts/xool-setup.sh` aus `jarvis-mac.sh`; Knopf in den Einstellungen; Voice-Sidecar (Phase A) mit Push-to-Talk und Duplex; danach nativer Ersatz (SpeechAnalyzer/SFSpeechRecognizer, AVSpeechSynthesizer oder Piper, VAD, Barge-in).
- **Fertig, wenn:** Ein Befehl richtet auf einem frischen Mac Ollama + Modell + Stimme ein; man kann einem Agent per Sprache einen Browser-Auftrag geben und ihn unterbrechen.

### Phase 5 – Second Brain
- BrainStore, Ingest aller Dateitypen, Bookmarks/Skills/Docs, Brain-Ansicht in der Sidebar, Brain-Tools für Agents.
- **Fertig, wenn:** PDF/Bild/Markdown reinziehen → in Sekunden über Volltext und Bedeutung auffindbar, Agent zitiert daraus.

### Phase 6 – UI-Korrekturen nach Review (vor allem anderen)

Feedback aus dem ersten echten Test (Screenshots hell/dunkel, 2026-11-26). Diese Phase **ersetzt** die Abschnitte 4.1, 4.3 und 4.5 dort, wo sie widersprechen. Was hier steht, ist ab jetzt der **Layout-Vertrag** (siehe 6.1) und gilt für alle späteren Phasen.

**A. Kontrast in der Sidebar**
- Zurück / Vor / Neu laden oben neben den Ampeln sind kaum sichtbar. Aktiv: `text-muted` (≥ 4.5:1 gegen `canvas`), Hover: `text`, deaktiviert: `text-muted` mit 45 % Deckkraft (nicht unsichtbar). Hell und dunkel prüfen.
- Die Zeile „+ New tab“ unter dem aktiven Tab ist zu schwach: auch `text-muted`, Hover `text` mit `raised`-Fläche.

**B. Untere Leiste neu: nur Agents, rechts ausgerichtet**
- Die durchgehende Fensterleiste unten (über Sidebar und Inhalt) entfällt. Die Sidebar reicht bis ganz nach unten.
- Unter der Inhaltsfläche bleibt ein schmaler Streifen (gleiche Höhe wie heute, **ohne** Trennlinie und ohne eigene Fläche, `canvas`-Hintergrund). Er enthält **nur** die Agent-Pills und den „Agents“-Knopf, **rechts ausgerichtet**:
  `…  [● Chief] [● Mktg] [● Inbox] [● Launch Bot]  [⌗ Agents]|` – der Agents-Knopf liegt bündig am rechten Rand (gleicher Abstand wie die Inhaltsfläche), der **erste Agent sitzt direkt links daneben**, weitere Agents reihen sich nach links an. `+` (Agent anlegen) steht ganz links in der Pill-Reihe.
- Der Modell-Chip zieht aus der Leiste ins Eingabefeld (siehe D) und in den Kopf des Thread-Fensters (gibt es schon).
- Thread-Schwebefenster sitzt weiterhin unten rechts, jetzt direkt über diesem Streifen.

**C. Agents-Übersicht rechts statt Sidebar-Abschnitt**
- Den Sidebar-Abschnitt „Agents“ entfernen. Agent-Tabs bleiben in der normalen Tab-Liste, erkennbar am Ring in Agent-Farbe.
- Der Agents-Knopf öffnet die Übersicht als **rechtes Seitenpanel** (schiebt den Inhalt, verdeckt ihn nicht), genau wie Referenz-Screenshot: oben angepinnte Agents groß als Blob-Avatar mit Namen darunter (der aktive mit `raised`-Fläche hinterlegt), darunter Liste aller Agents mit Blob, Name und letzter Nachricht (eine Zeile, abgeschnitten). **Keine** Profilzeile unten. Esc oder erneuter Klick schließt.

**D. Eingabefeld (Neuer Tab und Adressfeld) überarbeiten**
- Höher und ruhiger: 52 pt, Radius 12, `surface`-Fläche mit 1 px `line`, kein Schlagschatten, im Dunkeln keine sichtbare Kastenkante außer der Haarlinie. Platzhalter: „Adresse eingeben oder Agent fragen“.
- Rechts im Feld: **Modell-Chip** (klein, `text-muted`), dann **Diktat-Knopf** mit Wellenform-Icon (`waveform`). Klick startet Diktat über die VoiceBridge aus Phase 4 (Text landet im Feld, Wellenform animiert während der Aufnahme, Esc bricht ab). Gleiches Diktat auch im Thread-Eingabefeld (das Mikrofon dort wird auf `waveform` vereinheitlicht).
- Kein Composer mit Anhängen/Werkzeugen in diesem Feld.

**E. Neuer-Tab-Visual (nur Code, dezent)**
- Referenz: Logo in der Mitte, dahinter Lichtstreifen, unten flüssiges Metall. Umsetzung **zurückhaltender**:
  - Mitte: das Xool-Zeichen (geschwungenes „Λ“, als Vektorpfad nachgezeichnet, metallischer Verlauf `text` → `text-muted`), ~56 pt, über dem Eingabefeld.
  - Dahinter **Sternschnuppen / Warp**: wenige (12–20) feine Lichtstriche, die aus der Mitte hinter dem Logo nach außen beschleunigen und verblassen, wie ein Sprung auf Lichtgeschwindigkeit. Farbe kühles Weiß/Blau mit niedriger Deckkraft (≤ 35 %). Kein Bokeh-Teppich.
  - Unten: **sehr flache, langsame Metallwelle** (eine Fläche, ein Glanzlicht), maximal unteres Fünftel, Deckkraft niedrig, keine klassischen Sinuswellen-Linien.
  - Hell-Modus: dieselbe Szene mit grauem Metall auf `canvas`, Striche in Grau.
  - Technik: Core Animation oder Metal-Layer, kein Video, kein Bild. Läuft nur, solange der Neue Tab sichtbar ist (pausiert sonst), < 3 % CPU. Bei `reduce motion` statisches Standbild.
  - Abschaltbar in Einstellungen › Erscheinungsbild („Bewegter Hintergrund im neuen Tab“).

**F. Sidebar-Gruppen neu**
- Gruppe **„Ressourcen“** (Abschnittstitel wie heute „Agents“, Satzschreibung) mit drei Einträgen, alle mit Icon **und** ausgeschriebenem Namen:
  - **Brain** – alles Schriftliche: Docs, Notizen, Skills, gespeicherte Seiten, Dateien mit Text.
  - **Lesezeichen** – die Bookmarks (heute nur ein Icon ohne Text).
  - **Medien** – Bilder, Videos, Audio (Brain-Einträge mit Bild/Video/Audio-Typ, eigene Rasteransicht mit Vorschaubildern).
- Brain-Ansicht filtert Medien künftig aus; Medien-Ansicht zeigt nur diese. Gleicher BrainStore, nur ein anderer Filter.

**G. Sidebar-Fuß**
- Ganz unten in der Sidebar **eine** Zeile: links `⚙ Einstellungen` (Icon + Text, `text-muted`, Hover `text`), rechts zwei Icon-Knöpfe ohne Text: **Tastatur** (`keyboard`) und **Hell/Dunkel-Umschalter** (`sun.max` / `moon`, schaltet zwischen hell, dunkel; Rechtsklick „Wie der Mac“). Kein Profilbild.
- Icon-Hierarchie: Navigationseinträge `text` (aktiv) / `text-muted` (ruhig); Fuß-Icons `text-muted`, Hover `text` auf `raised`; nichts davon in Akzent- oder Agent-Farbe.
- Tastatur-Knopf öffnet ein **Popover innerhalb der Sidebar direkt über der Einstellungen-Zeile** (gleiche Breite wie die Sidebar minus Rand, Radius 10, `raised`): Titel „Tastenkürzel“, gruppierte Liste (Navigation, Tabs, Agents, Brain, Stimme) mit den echten Kürzeln aus `ShortcutsPage`/Menüs, Kürzel rechts als Tastenkappen. Esc oder Klick daneben schließt. Später (nicht jetzt) kann hier ein Kennenlern-Rundgang dazukommen.

**Fertig, wenn:** alle Punkte A–G in hell und dunkel per Screenshot belegt sind (Neuer Tab mit Visual, Thread offen, Agents-Panel offen, Tastenkürzel-Popover offen, Medien-Ansicht); Kontraste der Sidebar-Icons gemessen ≥ 4.5:1 (aktiv) bzw. ≥ 3:1 (Icons); Visual pausiert im Hintergrund und respektiert `reduce motion`; Release-Build grün; committet und gepusht.

#### 6.1 Layout-Vertrag (gilt für Phase 6–7, ersetzt durch 8.1)
- Sidebar von oben nach unten: Ampeln + Zurück/Vor/Neu laden · Tabs (Gepinnt, Heute …) · Gruppe „Ressourcen“ (Brain, Lesezeichen, Medien) · Fuß (Einstellungen | Tastatur, Hell/Dunkel). Keine Agents-Liste in der Sidebar.
- Unten rechts unter dem Inhalt: Agent-Pills + Agents-Knopf, rechtsbündig. Sonst nichts in dieser Zeile.
- Agents-Übersicht und Threads (als Seitenleiste) erscheinen **rechts**.
- Modell-Wahl lebt im Eingabefeld und im Thread-Kopf.
- Neue Funktionen (z. B. Canvas) bekommen einen Eintrag in der Sidebar (Tabs-Bereich oder „Ressourcen“) und öffnen im Inhaltsbereich; sie ändern diese Struktur nicht. Abweichungen nur nach Rückfrage.

### Phase 7 – Canvas + Blöcke
- `web/canvas` (TipTap + Slash-Menü + Canvas-Engine), Host in WKWebView, Speichern im Brain, Agent-Befehle.
- Einstieg: Canvas-Dokumente erscheinen als eigene Einträge in der Tab-Liste bzw. unter „Ressourcen › Brain“; der Layout-Vertrag 6.1 bleibt unverändert, Design-Tokens aus `Theme.swift`.
- **Fertig, wenn:** Frame anlegen, Text mit `/` in Blöcke verwandeln, Bild einfügen, speichern, nach Neustart wieder da; Screenshots zeigen, dass Sidebar, untere Agent-Zeile und Eingabefeld exakt wie nach Phase 6 aussehen.

### Phase 8 – Zweites Review: Logo, Jarvis-Hierarchie, Panel aus der Inhaltsfläche

Feedback aus dem Test nach Phase 7 (2026-11-26). Referenzbilder: `docs/review/p8-*`. Diese Phase **ändert den Layout-Vertrag** (vom Nutzer so gewünscht). Die neue Fassung steht unter 8.1 und ersetzt 6.1.

**A. Neues Xool-Zeichen (ersetzt das „Λ“)**
- Form (siehe `p8-logo-skizze.png`): ein abgerundetes Quadrat, aufgeteilt in **vier abgerundete Dreiecke** (oben, rechts, unten, links). Die Grundseiten liegen an den Außenkanten, die Spitzen zeigen zur Mitte. Die **Zwischenräume bilden ein X**. Alle Ecken stark gerundet, die Spitzen weich.
- Dreiecke: hellsilber/grau, leicht weichgezeichnet (feiner innerer Verlauf, minimaler Blur am Rand), matt-metallisch, kein harter Glanz.
- **Hinter den Dreiecken, sichtbar nur im X-Zwischenraum:** ein Liquid-Glass-Hintergrund, also ein lebendiger, sanft vibrierender Verlauf mit Welle. Er wirkt wie Licht hinter Glas und hat einen hellen Lichtsaum an den Kanten der Dreiecke (siehe `p8-liquid-glass-kante.png`). **Radiale Deckkraft:** 100 % in der Mitte, zu den vier Ausgängen des X hin auf 0 %.
- Technik: Core Animation (CAShapeLayer-Maske für die Dreiecke, CAGradientLayer/CAEmitter oder ein kleiner Metal-Shader für die Glas-Welle). Ruhig: Welle mit ≤ 0.3 Hz, Pause im Hintergrund, `reduce motion` = Standbild. Hell- und Dunkel-Variante.
- Das Zeichen ersetzt das „Λ“ überall: Neuer Tab (die Warp-Sternschnuppen bleiben dahinter), App-Icon (`Icon/`), Jarvis-Avatar (siehe C) und About.

**B. Sidebar-Feinschliff**
- Gruppe „Resources“ heißt jetzt **„Sources“**.
- Der Gruppentitel ist **ruhiger** als seine Einträge: 11 pt, Gewicht 550, Farbe `text-muted` mit 70 % Deckkraft. Brain, Bookmarks und Media bleiben 13 pt in `text-muted` (aktiv `text`). „Settings“ bleibt, wie es ist.
- **Abstand** zwischen dem letzten Eintrag (Media) und der Settings-Zeile: 20 pt (zwischen 16 und 24), damit der Fuß als eigener Bereich erkennbar ist.

**C. Jarvis als Haupt-Agent, Hierarchie**
- Es gibt immer einen **Haupt-Agent „Jarvis“** (nicht löschbar, umbenennbar). Farbe: „Jarvis-Silber“, also der Liquid-Glass-Look des neuen Zeichens. Sein Avatar ist das animierte Zeichen in klein, nicht ein Blob.
- Jarvis hat **drei Assistenten** („rechte Hände“, frei wählbar aus den vorhandenen Agents, Standard: die ersten drei). Alle übrigen sind **weitere Agents**.
- Jarvis delegiert: AgentRuntime bekommt ein Tool `delegate(agent, task)`, mit dem Jarvis Aufgaben an einen Assistenten oder Agent gibt. Der Schritt erscheint im Protokoll und öffnet auf Wunsch dessen Thread.
- **Agents-Panel (rechts), neu gegliedert:**
  1. Oben **Jarvis' „Büro“**: als Einziger in einem eigenen Container (`raised`-Fläche, Radius 12). Darin großes animiertes Zeichen, Name, letzte Nachricht und eine Zeile „Mit Jarvis sprechen“ (Diktat-Knopf + Eingabe).
  2. Darunter die **drei Assistenten** groß nebeneinander (Blob-Avatar, Name).
  3. Darunter die **Liste der weiteren Agents** (Blob, Name, letzte Nachricht).
  Keine Profilzeile.

**D. Untere Agent-Zeile**
- Rechtsbündig von rechts nach links: `[Agents]` · **Jarvis** · Assistent 1 · Assistent 2 · Assistent 3 · **Mehr-Chip** · `+`.
- **Mehr-Chip** (z. B. „+4“ bzw. `ellipsis` mit Zahl, gleiche Pill-Form, neutral grau): Klick öffnet ein Popover nach oben mit der Liste der weiteren Agents (Blob, Name). Klick auf einen öffnet seinen Thread. Ohne weitere Agents ist der Chip ausgeblendet.

**E. Panel wächst aus der Inhaltsfläche (ohne Trennlinie)**
- Die senkrechte Trennlinie zwischen Inhalt und rechtem Panel entfällt (`p8-panel-ohne-trennlinie.png`, rot).
- Inhalt und Panel liegen in **einer gemeinsamen abgerundeten Inhaltskarte** (grüne Markierung). Beim Öffnen wächst die Karte nach rechts und das Panel erscheint im Hintergrund der Karte, rechts neben der Seite. Abgegrenzt wird es nur durch eine minimal andere Fläche (`surface` vs. `canvas`-nahe Tönung) und Abstand, nicht durch eine Linie. Die untere Agent-Zeile bleibt unter der Karte. Der Agents-Knopf liegt bündig mit der rechten Kartenkante.
- Gilt genauso für den Thread als Seitenleiste.

**F. Animation: Agents-Knopf → Panel**
- Klick auf „Agents“: Das Panel entsteht aus der unteren Zeile. Die Pills (Jarvis, Assistenten) **fliegen in das Panel und steigen an ihre Plätze** (Jarvis ins Büro, Assistenten in die Dreierreihe). Gleichzeitig wächst die Karte nach rechts. Matched-Geometry-Übergang, ca. 320 ms, ease-out, leichte Staffelung (30 ms pro Pill). Schließen spielt das Ganze rückwärts.
- `reduce motion`: einfaches Überblenden ohne Flug.

**G. Kürzel und Sprache auslösen**
- **`⌘T` öffnet zuverlässig einen Neuen Tab** (mit Fokus im Eingabefeld). Prüfen, ob ein Agent-, Canvas- oder Brain-Kürzel `⌘T` überlagert, und das beheben.
- **Sprache direkt auslösen, nativ.** Vorschlag, alle drei umsetzen:
  1. **Globales Kürzel** (Standard `⌥⌘J`, einstellbar über `HotKey.swift`, funktioniert auch, wenn Xool im Hintergrund ist): startet sofort Zuhören bei Jarvis. Halten = Push-to-Talk, kurz drücken = bis Stille.
  2. **Menüleisten-Symbol** (NSStatusItem mit dem neuen Zeichen): Klick startet Zuhören, das Symbol pulsiert dabei. Rechtsklick öffnet Menü (Letzte Threads, Xool öffnen, Stimme aus).
  3. **App Intent „Mit Jarvis sprechen“** (AppIntents-Framework): erscheint in Kurzbefehlen und Spotlight, lässt sich auf die Action-Taste, per Siri oder als Tastaturkurzbefehl in Systemeinstellungen legen.
  In der App selbst bleibt der Wellenform-Knopf im Eingabefeld. Zusätzlich startet ein Klick auf Jarvis' Pill mit gedrückter `⌥`-Taste sofort das Zuhören.

**Fertig, wenn:** neues Zeichen im Neuen Tab, Agents-Panel und Menüleiste in hell und dunkel per Screenshot belegt; Animation Agents-Knopf → Panel als kurze Bildschirmaufnahme oder Bildfolge (`docs/shots/p8-*`); `⌘T` öffnet einen Tab; globales Kürzel und Menüleisten-Symbol starten das Zuhören (mit WAV-Eingabe testbar); App Intent erscheint in Kurzbefehlen; Release-Build grün; committet und gepusht.

#### 8.1 Layout-Vertrag (ersetzt 6.1, gilt ab Phase 8)
- Sidebar von oben nach unten: Ampeln + Zurück/Vor/Neu laden · Tabs · Gruppe „Sources“ (Brain, Bookmarks, Media) · 20 pt Abstand · Fuß (Settings | Tastatur, Hell/Dunkel). Keine Agents-Liste in der Sidebar.
- Inhalt und rechte Panels (Agents-Übersicht, Thread als Seitenleiste) teilen sich **eine** abgerundete Inhaltskarte, ohne Trennlinie.
- Unter der Karte, rechtsbündig: `+` · Mehr-Chip · Assistenten 3–1 · Jarvis · Agents-Knopf (bündig mit der Kartenkante). Sonst nichts in dieser Zeile.
- Agents-Panel: Jarvis-Büro oben, drei Assistenten, Liste weiterer Agents.
- Modell-Wahl lebt im Eingabefeld und im Thread-Kopf.
- Neue Funktionen bekommen einen Eintrag in der Sidebar und öffnen im Inhaltsbereich. Sie ändern diese Struktur nicht. Abweichungen nur nach Rückfrage.

### Phase 9 – Jarvis spricht: echte Duplex-Stimme, einsatzbereit

Anlass: Test nach Phase 8. Diktat kommt als Text im Jarvis-Thread an, Jarvis antwortet aber nur schriftlich und behauptet sogar, er könne keine Sprache empfangen. Ursachen laut Befund: Der Voice-Sidecar ist im echten Profil **nicht installiert** (`~/Library/Application Support/Xool/voice` fehlt), deshalb läuft nur Apple-Diktat ohne Sprachausgabe. Außerdem weiß Jarvis' System-Prompt nicht, dass er ein Sprachassistent ist. Ziel: Man spricht mit Jarvis wie mit `jarvis_stimme` im Terminal (jarvis-on-nod), nur in der App.

**A. Einsatzbereit ohne Handarbeit**
- Beim ersten Gespräch mit Jarvis, falls die Stimme fehlt: Karte im Jarvis-Büro „Stimme einrichten (ca. X GB)“. Ein Klick startet `xool-setup.sh --only-voice` mit Fortschritt (venv, mlx-whisper, Silero-VAD, Piper-Stimme `de_DE` hoher Qualität). Danach startet der Sidecar automatisch mit der App und bleibt warm (Modelle vorgeladen).
- Statusanzeige im Büro und in der Menüleiste: bereit / hört zu / denkt / spricht / Stimme fehlt (mit Knopf).
- Fallback, wenn der Sidecar nicht läuft: **native Kette** (SpeechAnalyzer bzw. SFSpeechRecognizer + AVSpeechSynthesizer mit der besten deutschen Premium-Stimme), aber **immer mit Sprachausgabe**. Jarvis antwortet nie stumm auf gesprochene Eingaben.

**B. Jarvis weiß, dass er spricht**
- System-Prompt für Sprach-Turns: „Du bist Jarvis, ein Sprachassistent. Der Nutzer spricht mit dir, deine Antwort wird vorgelesen.“ Kurze, natürliche Sätze, kein Markdown, keine Listen, Zahlen und Links sprechbar (`clean_for_speech`). Im Thread steht der Text trotzdem formatiert.
- Antwort im Thread und gleichzeitig gesprochen. Satz für Satz, während das Modell weiterschreibt.

**C. Duplex wie im Terminal**
- **Gesprächsmodus** (Knopf im Büro, Menüleiste, `⌥⌘J` kurz drücken): Mikrofon bleibt offen, VAD erkennt Satzende (Silero, Pausenlänge einstellbar), kein Knopfdrücken pro Satz. Halten von `⌥⌘J` bzw. `fn` = Push-to-Talk wie bisher.
- **Barge-in:** Spricht man dazwischen, verstummt Jarvis sofort und die Generierung bricht ab. **Echo-Unterdrückung** über `AVAudioEngine` Voice Processing (`setVoiceProcessingEnabled(true)`) bzw. im Sidecar, damit Jarvis sich nicht selbst unterbricht.
- **Vorausdenken** (`vorausdenken.py`/Thinker): In Pausen bereitet Jarvis Notizen vor, optional ein kurzes „Übrigens …“.

**D. Weiß, dass ich ihn meine (Session-Modell)**
- **Gesprächssitzung:** Nach „Jarvis …“ oder nach einer Antwort bleibt eine Sitzung offen (Standard 20 s, einstellbar). Folgefragen gehen ohne Weckwort an ihn.
- **Adressaten-Entscheidung:** Das kleine `DecisionModel` bekommt den Satz plus die letzten Turns und entscheidet: „an Jarvis“ / „nicht an Jarvis“ (Gespräch mit jemand anderem, Selbstgespräch, Fernseher). Nicht gemeint → ignorieren, nichts sagen.
- Optional **Weckwort „Jarvis“** lokal (openWakeWord, Apache-2.0, eigenes Modell oder generisch), standardmäßig aus, in den Einstellungen an.

**E. Brückenphrasen-Bibliothek (200–300) und Sofort-Einschätzung**
- `bruecken.py` auf **250+ deutsche Gesprächsanfänge** ausbauen, nach Situation gruppiert. Zum Beispiel: Verstanden („Okay, verstehe.“, „Alles klar.“), Nachdenken („Hm, lass mich kurz überlegen.“), Lob/Idee („Das ist eine richtig gute Idee.“, „Spannender Punkt.“, „Großartiger Gedanke.“), Überraschung („Oh, das hatte ich nicht bedacht.“), Befehl („Mach ich.“, „Bin dran.“), **Websuche** („Moment, ich schau kurz im Netz nach.“), **Browser** („Ich öffne das mal.“), **Brain** („Ich schau in deine Notizen.“), Rückfrage, Entschuldigung, Abschied. Alle beim Start einmal vertont und auf Platte gecacht, Abspielen kostet 0 ms. Keine Wiederholung derselben Phrase in kurzer Folge.
- Das `DecisionModel` schätzt **sofort** (< 300 ms) ein: Reicht das Wissen des Modells, oder braucht es `web_search`, Browser oder Brain? Daraus folgen die Kategorie der Brückenphrase (z. B. „Ich schau kurz nach“) und die Tools für den Lauf. Die Phrase wird nur gespielt, wenn der erste echte Satz nicht schneller da ist.
- Ziel-Latenzen: Brückenphrase < 300 ms nach Sprechende, erster echter Satz < 1.5 s (schnelles MoE-Modell zuerst, `MODEL_PREFERENCE` aus jarvis-on-nod), Abbruch bei Barge-in < 150 ms.

**F. Open-Source-Stack** (alles lokal): mlx-whisper (Apple Silicon) bzw. whisper.cpp, Silero-VAD, Piper (de_DE, hohe Qualität), openWakeWord (optional), Ollama für LLM und Entscheider. Lizenzen in `THIRD_PARTY_NOTICES.md`. Später prüfen (nicht in dieser Phase): ein echtes Full-Duplex-Sprachmodell (z. B. Kyutai Moshi) als Alternative.

**Fertig, wenn:** auf dem echten Profil einmal „Stimme einrichten“ durchläuft und der Sidecar danach mit der App startet. Jarvis antwortet auf gesprochene Fragen hörbar auf Deutsch, Satz für Satz, ohne Markdown-Vorlesen. Gesprächsmodus ohne Knopf pro Satz. Barge-in stoppt ihn. Nicht an ihn gerichtete Sätze ignoriert er. Brückenphrasen passen zur Situation (Websuche angekündigt). Latenzen gemessen und in der Status-Notiz. Automatisiert belegt mit WAV-Eingaben (inkl. Barge-in und „nicht gemeint“), **echter Mikrofon-Test als Checkliste für den Nutzer** in der Status-Notiz. Release-Build grün, committet und gepusht. Layout-Vertrag 8.1 bleibt unverändert.

---

## 7. Qualitätsboden (gilt für jede Phase)

- Kontrast ≥ 4.5:1 für Text, Fokusring immer sichtbar, alle Icon-Knöpfe mit Accessibility-Label.
- `reduce motion` und `increase contrast` respektiert.
- Keine Emojis als Icons, nur SF Symbols bzw. eigene SVG-Avatare.
- Fehlertexte sagen, was passiert ist und was man tun kann („Ollama läuft nicht. Ollama starten“), Leerzustände laden zum Handeln ein.
- Nichts verlässt den Mac außer Seiten, die man öffnet, Suchanfragen von `web_search` und Anfragen an einen Cloud-Anbieter, für den man selbst einen Key hinterlegt hat.

## 8. Offene Punkte

- Name/Bundle-ID final (`com.xool.os`?) und Signier-Team.
- Ob Search-Sync (iCloud) später mit eigenem Container zurückkommt.
- Lizenz der Voice-Modelle (Piper-Stimmen) für die Weitergabe im Bundle prüfen. Piper selbst ist GPL-3.0 (siehe `THIRD_PARTY_NOTICES.md`), das Weckwort-Modell `hey_jarvis` nur nichtkommerziell.
- Echtes Echo-Löschen (Voice Processing) für den Gesprächsmodus mit Lautsprechern (Stand Phase 9).

---

## Stand Phase 3 (2026-11-26)

Umgesetzt: `AgentRuntime` (Tool-Loop, Streaming, Stop), Tool-Calls im OpenAI-Format (Ollama, LM Studio, OpenAI, OpenRouter) und als Anthropic `tool_use`; Browser-Tools intern über `AgentControl` (`AgentControl.call`, kein Socket); `web_search` (DuckDuckGo-HTML oder `XOOL_SEARXNG`); Skills (`~/Library/Application Support/Xool/skills/<name>/SKILL.md`, `/` im Thread); Schritt-Protokoll mit Sprung zum Tab; Ring und Sidebar-Abschnitt „Agents“; Domain-Erlaubnis pro Agent (`AgentDomainTrust`); Pill-Zustände. Belege: `docs/shots/p3-*.png` (echter Lauf gegen Ollama).

Nicht getestet: Anthropic-/OpenAI-Tools ohne echten Key, LM Studio, Gemini (läuft als Chat ohne Tools), XCTest. Offen: farbiger Zeiger auf der Webseite, Tool-Calls für Gemini.

---

## Stand Phase 4 (2026-11-26)

Umgesetzt: `scripts/xool-setup.sh` (aus `jarvis-mac.sh`; `--check`, `--model`, `--yes`, `--no-voice`; kein Admin-Passwort, löscht nichts); Knopf „Set up local AI“ in Einstellungen › Modelle (`LocalSetup`: Schritte, Download-Balken, Fehler mit „Next:“); Voice-Sidecar `Resources/voice/xool_voice` (VAD, Whisper/mlx, Piper, Brückenphrasen; JSON-Zeilen über stdin/stdout statt WebSocket) mit `VoiceBridge` (Sprache → aktiver Agent-Thread über `ChatRuntime`/`AgentRuntime`, Antwort satzweise gesprochen, Barge-in, Brückenphrase nur ohne ersten Satz, Thinker in Pausen mit Notizen und „Übrigens“ im Freisprech-Modus); Push-to-Talk `fn` oder `⌥Leertaste`, Mikrofon-Knopf im Thread (Rechtsklick: Freisprechen), Pill „listening“, Avatar blinzelt beim Verstehen; Mikrofon-Anfrage über `AVCaptureDevice`; Fallback `NativeEngine` (SFSpeechRecognizer + AVSpeechSynthesizer, nur Push-to-Talk).

Geprüft (ohne echtes Mikrofon): `--check`; Sidecar-Installation per `uv` in frischer venv; Piper → WAV → Whisper (Rundlauf); Server mit `--null-audio` (Bridge, Sprechen, Stop, WAV als Eingabe); ganze Kette mit WAV als Eingabe im echten Lauf (`XOOL_UI=voicewav:…`): Whisper → Thread → Agent öffnet `example.com` im Agent-Tab, liest, antwortet auf Deutsch → Sätze beim Sidecar; Stimme per `voiceinterrupt` zum Schweigen gebracht.

Nicht geprüft: echtes Mikrofon und Lautsprecher (fn halten, Barge-in per Stimme, Echo), die Mikrofon-/Spracherkennungs-Abfragen von macOS, Input-Monitoring für `fn` bei anderer App im Vordergrund, `NativeEngine`, das Skript als frischer Lauf mit Installation von Ollama und Modell-Download (der Lauf auf dieser Maschine wurde nicht freigegeben; nur `--check`, die Stimm-Installation und die Schritte einzeln), Screenshots (Fenster war nicht abgreifbar), XCTest. Piper hat auf macOS Mühe mit langen Pfaden zu `espeak-ng-data` (über ~160 Zeichen): `tts.py` legt dann einen kurzen Symlink an.

Offen: Englisch spricht Piper mit der deutschen Stimme (Sprachwahl pro Satz nur im nativen Weg); Phase B (alles in Swift); Lizenz der Piper-Stimmen für die Weitergabe im Bundle.


---

## Stand Phase 5 (2026-11-26)

Umgesetzt: `Xool/Brain/` — `BrainDB` (System-SQLite3, FTS5, Vektoren als BLOB), `BrainStore` (Daten unter `Xool/Brain`: `files/<id>/<Original>`, `thumbs/`, `brain.sqlite`; Typen Notiz, Datei, gespeicherte Seite, Lesezeichen, Skill — Lesezeichen und Skills werden aus Search-Bookmarks bzw. `Xool/skills` gelistet, nicht kopiert), `Ingest` (Text/Code, PDF über PDFKit mit OCR für Scans, Bilder über Vision, docx/xlsx/pptx/odt aus dem XML, rtf/doc über NSAttributedString, sonst QuickLook-Vorschau + OCR; Vorschaubilder per QuickLookThumbnailing; alles im Hintergrund), `BrainEmbedder` (Rolle „Embeddings“, Ollama `/api/embed`, Standard `nomic-embed-text`; fehlt das Modell: Hinweis + Download-Knopf über `OllamaCatalog`), kombinierte Suche (FTS5 + Cosinus in Swift, Rangfusion). Brain-Ansicht (Sidebar-Eintrag „Brain“, ⌥⌘B; Typ-Filter, Suche, Vorschau, Drag & Drop auf Ansicht und Sidebar-Eintrag, Leerzustand, neue Notiz, Bearbeiten). „Save Page to Brain“ (Rechtsklick auf der Seite, Menü Ansicht, ⌥⇧⌘S, ⌘K-Befehlsleiste). Agent-Tools `brain_search`, `brain_read`, `brain_save` (Unterstriche statt Punkte, wie die anderen Tools); `@` im Thread-Eingabefeld erwähnt Einträge; Antworten zitieren als Link `xool-brain://<id>`, der den Eintrag im Brain öffnet; Schritte im Protokoll springen dorthin; ⌘K zeigt Brain-Treffer (Volltext). Belege: `docs/shots/p5-*.png`, `scripts/snap-state.sh` (Fenster zeichnet sich selbst, geht auch bei gesperrtem Bildschirm).

Geprüft (echter Lauf, Debug- und Release-Build): Markdown, PDF, PNG (OCR) und docx hineingezogen → Volltext in 0 ms, Bedeutungssuche mit `nomic-embed-text` in ca. 10 ms, Treffer zeigen Vorschau und Text; Agent (qwen3.5:27b) ruft `brain_search` und `brain_read` und zitiert die Notiz mit Link. Erste OCR nach App-Start braucht ca. 30 s (ANE-Kompilierung), danach schnell; Text ist sofort suchbar.

Nicht geprüft / bekannt: XCTest; Drag & Drop mit der Maus (nur per Startverb `brainadd` und Code-Pfad `onDrop`); Download-Knopf: Fehler „lädt kurz und springt zurück“ behoben (Status wurde nach dem Pull nicht neu gelesen), aber nicht mit frischem Download wiederholt (Modell war schon da); Speichern einer Webseite und Rechtsklick-Eintrag nur gebaut, nicht per Klick getestet; ⌘K-Treffer nicht im Bild geprüft; Lesezeichen-Sync und Skill-Einträge nicht im Bild. Qualität der Bedeutungssuche: `nomic-embed-text` trennt deutsche Kurztexte schwach (Kosinus 0.5–0.7 für alles); ein mehrsprachiges Modell (z. B. `bge-m3`) in Einstellungen › Modelle › Embeddings ist besser — Wechsel verwirft und erneuert die Vektoren. Spracheingabe liest Markdown-Links als Text vor.

Referenzbilder zu Phase 6: `docs/review/p6-*.png|jpg` (annotierter Screenshot, Sidebar-Fuß, Agents-Panel, Neuer-Tab-Referenz).


---

## Stand Phase 6 (2026-11-26)

Umgesetzt (A–G, Layout-Vertrag 6.1 eingehalten): **A** Zurück/Vor/Neu laden, „+ New tab“ und alle Sidebar-Knöpfe in `text-muted` (Hover `text` auf `raised`, deaktiviert 45 %). **B** Keine Fensterleiste mehr; die Sidebar läuft bis unten. Unter der Seite nur `+`, Agent-Pills, Agents-Knopf, rechtsbündig (Knopf bündig mit dem Seitenrand, erster Agent daneben, weitere nach links); die Seite lässt dafür 40 pt (`AgentDock.height`, `ContentView.dockRoom`). Modell-Chip ist im Eingabefeld und im Thread-Kopf. **C** Sidebar-Abschnitt „Agents“ entfernt (Dateien gelöscht); Agents-Knopf öffnet das Panel rechts neben der Seite (schiebt sie, Esc/Knopf schließt, keine Profilzeile, aktiver Agent auf `raised`). **D** Eingabefeld 52 pt, Radius 12, `surface` + 1 px `line`, kein Schatten/Atem; rechts Modell-Chip und Diktat-Knopf (`waveform`) über `VoiceBridge.toggleDictation` (Klick start/Klick fertig/Esc verwirft; Text landet im Feld); im Thread-Feld dasselbe (Rechtsklick: freisprechen). **E** `NewTabScene` (nur Core-Animation-Ebenen): Xool-Zeichen, 16 Streifen, flache Metallwelle, Hell-Variante; pausiert bei verdecktem Fenster/inaktiver App/Mini/Hide, Standbild bei Reduce Motion oder Schalter aus (Einstellungen › Erscheinungsbild › „Moving background on a new tab“). **F** Gruppe „Resources“: Brain (nur Schriftliches), Bookmarks (Popover wie bisher), Media (Rasteransicht, Typfilter Bilder/Video/Audio, Vorschau rechts); gleicher `BrainStore`, `BrainItem.mediaType` per UTType. **G** Fußzeile `⚙ Settings` links, rechts Tastatur und Hell/Dunkel (Rechtsklick „Like the Mac“); Tastenkürzel-Popover in der Sidebar über dem Fuß, Kürzel aus `ShortcutStore`/Commands (Navigation, Tabs, Agents, Brain, Voice).

Entscheidungen (ruhigere Variante gewählt): UI-Texte bleiben englisch wie die App (Resources, Bookmarks, Media, Settings, Keyboard shortcuts). Brain/Media/Tabs-Ansichten liegen jetzt genau auf der Seitenkarte (`XoolUI.page`, `PageFrame`) statt über dem ganzen Fenster; Sidebar und Agent-Zeile bleiben bedienbar. Das Agents-Panel schließt Brain/Media nicht mehr. Schalter aus = Standbild (nicht leer). Die Option „Türen oben“ und die alten Fuß-Türen (Erweiterungen, Spaces, Profil) sind in der Spalte mit Titeln nicht mehr sichtbar, nur der Download-Knopf erscheint im Fuß, solange geladen wird; Icon-Spalte (nur Symbole) unverändert. Platzhalter im Feld jetzt `text-muted` (vorher 2,5:1).

Belege: `docs/shots/p6-*.png` (Neuer Tab, Thread, Agents-Panel, Tastenkürzel, Medien je hell und dunkel, Brain ohne Medien, Einstellungen-Schalter). Kontraste gemessen (WCAG, Token gegen Hintergrund): `text-muted` auf `canvas` 4,70:1 hell / 6,07:1 dunkel, auf `surface` 5,04 / 5,68, auf `raised` 4,46 / 5,21 (dort wird beim Hover `text` 15,1 / 13,5 gezeigt); `text` auf `canvas` 15,9 / 15,7; deaktiviert (45 %) 1,8 / 2,1 laut Plan; Icons ≥ 3:1 erfüllt. Szene: Prozess 0,0–0,1 % CPU im Dauerlauf (Release, `XOOL_SCENE=force`), WindowServer +≈0,3 %; ohne Aktivierung 0 %.

Nicht geprüft: Klick-Bedienung mit Maus (Bildschirm war schlafend/gesperrt, nur Selbst-Schnappschüsse): Hell/Dunkel-Umschalter, Diktat mit echtem Mikrofon, Esc im Panel/Popover, Bookmarks-Popover aus der Sidebar, Drag & Drop in Media; Pause/`reduce motion` der Szene nur über Code-Pfad und Log, nicht live im Bild; Video/Audio in Media (nur Bilder getestet); Sidebar rechts (`sidePosition == .right`): Agent-Zeile bleibt rechts unter der Seite, aber die Karte reserviert dort die Spalte rechts — nicht angesehen; mehrere Fenster teilen `XoolUI.page` (zuletzt geändertes Fenster gewinnt); XCTest. Offen: AddressLine (optionale Zeile in der Sidebar) hat weiter ihr altes Feld ohne Chip/Diktat; Logo ist von Hand als Pfad nachgezeichnet, kein Original-Vektor; Erweiterungs-Puzzle nur noch über das Menü erreichbar.


---

## Stand Phase 7 (2026-11-26)

Umgesetzt: **`web/canvas`** (TypeScript, esbuild; TipTap 3 mit eigenem `/`-Menü: Text, Überschrift 1–3, Listen, Todo, Zitat, Code, Trenner, Bild, Tabelle, Brain-Verweis mit Suche, „Ask agent“; Flächen-Engine in HTML/SVG: Frames, Rechteck, Ellipse, Linie, Pfeil, Text-Elemente = Block-Dokumente, Bilder per Drag & Drop/Einfügen/Auswahl, Verbinder, Zoom/Pan (Pinch, ⌘±, ⇧1), Auswahl/Marquee, Verschieben (Frames nehmen ihre Inhalte mit), Größe ändern, ⌘D, Reihenfolge, Pfeiltasten, Rückgängig/Wiederholen). **Bundle ist eingecheckt** (`Resources/canvas`, ~500 kB), `./build.sh` kopiert es und braucht kein Node; neu erzeugen mit `web/canvas/build.sh` (Node 20+, `package-lock.json` pinnt alles; Lizenzen in `THIRD_PARTY_NOTICES.md`). **Host** `Xool/Canvas/`: eigener WKWebView pro Dokument mit Schema `xool-canvas://` (Bundle und Bilder; CSP ohne Netz, Links öffnen als Browser-Tab), Brücke `xool` (ready/save/asset/title/ask/brainSearch/openBrain/openURL), Design-Tokens aus `Theme.NS` als CSS-Variablen, Hell/Dunkel live per KVO. **Speichern**: BrainStore-Typ „Canvas“ (`Brain/files/<id>/canvas.json`, Bilder in `assets/`), Text (Titel, Frame-Namen, Blöcke) in FTS5 und Embeddings; Autosave 0,5 s, Flush beim Verlassen. **Einstieg im Layout-Vertrag**: Canvas ist eine `InternalPage` (Tab pro Dokument, Neustart stellt ihn wieder her), Brain-Eintrag „Open“, ⌘K-Treffer, ⌘K „New Canvas“ und Datei › New Canvas; keine neue Struktur. **Agent-Tools** `canvas_create`, `canvas_add_frame` (optional mit Markdown-Blöcken), `canvas_add_block`, `canvas_read` (Unterstriche wie die anderen Tools); Änderungen gehen auch in eine offene Seite (Undo bleibt). „Ask agent“ öffnet einen neuen Thread mit Kontext (Canvas-Id, Blocktext) und stellt die Frage.

Geprüft (echter Lauf, Debug-Build, Profil „shots“): Agent-Pfad (`canvasagent`: Frame mit Überschrift, To-dos, Zitat, Code, Tabelle) → Seite zeigt es; Skript erzeugt Frame, Text-Block und Bild, speichert; nach App-Neustart per `canvasopen` wieder da (Bild lädt, 120 px), Text steht in der Brain-Datenbank. `/`-Menü, Frame-/Text-Werkzeug, Todo-Umwandlung per echter Tipp-Eingabe im eingebauten Browser (Seite ohne App). Screenshots `docs/shots/p7-canvas-{light,dark}.png`; `p7-newtab-*` sind **bytegleich** zu `p6-newtab-*` (Sidebar, Agent-Zeile, Eingabefeld unverändert, `cmp`).

Nicht geprüft / bekannt: Maus-Bedienung in der App (Bildschirm gesperrt; Interaktion nur im eingebauten Browser und per Skript); Bild-Drop aus dem Finder in den WKWebView; Verbinder, Größen-Griffe und Marquee nur Code-Pfad; „Ask agent“ und Brain-Verweis-Suche nur gebaut, nicht ausgelöst; Agent-Tools nicht mit einem echten Modell-Lauf, nur über dieselben Funktionen; Brain-Liste mit Canvas-Eintrag nicht im Bild (Selbst-Schnappschuss legt den WebView über Overlays); ob das Brain-/Media-Overlay über der Canvas-Seite liegt (NSView über SwiftUI) nicht gesehen; ⌘Z im Canvas hängt am Menü-/Responder-Verhalten des WKWebView (Taste kommt als keydown an, wenn das Menü sie nicht schluckt); XCTest. Offen: Farben/Füllung der Formen, Gruppieren, Ausrichten/Raster-Einrasten, Ebenen-Liste, Export als Bild/PDF, Mehrfach-Größenänderung, Textformat-Leiste (Fett/Kursiv nur per Tastenkürzel von TipTap), Canvas-Vorschaubild im Brain.


---

## Stand Phase 8 (2026-11-26)

Umgesetzt (A–G, Layout-Vertrag 8.1 eingehalten): **A** `XoolMark.swift`: vier abgerundete Dreiecke (Pfad per CGPath-Boolesche Operationen aus Platte ∩ Dreieck, Ecken durch Erosion/Aufweitung gerundet), mattes Silber, feiner Lichtsaum innen am Rand; dahinter nur im X sichtbar ein Liquid-Glass-Verlauf (radiale Deckkraft 100 % Mitte → 0 % Ausgänge, Konus-Welle dreht in 18 s = 0,055 Hz, Atmen ≈ 0,16 Hz, Anschwellen ≈ 0,11 Hz), Hell- und Dunkel-Variante, Standbild bei Reduce Motion oder verdecktem Fenster. Ersetzt das „Λ“ im Neuen Tab (Warp-Streifen bleiben), im App-Icon (`Icon/icon.swift`, gleiche Geometrie; auch das Icon-Composer-Dokument), im Jarvis-Avatar, in Einstellungen › About und in der Menüleiste (Template-Bild der Dreiecke). **B** „Sources“, Titel 11 pt / 550 / `text-muted` 70 %, 20 pt zur Settings-Zeile. **C** `Agent.main`/`assistantIDs`: Jarvis (Jarvis-Silber, animiertes Zeichen, nicht löschbar, umbenennbar) wird beim Start angelegt, drei Assistenten frei wählbar (Rechtsklick „Make assistant of Jarvis“ / „Remove from assistants“, Standard die ersten drei), Tool `delegate(agent, task)` nur für Jarvis (neuer Thread beim Ziel-Agent, wartet auf dessen Antwort, Schritt im Protokoll öffnet den Thread); Agents-Panel: Jarvis-Büro in eigenem `raised`-Container (großes Zeichen, Name, letzte Zeile, Diktat + Eingabe), drei Assistenten, Liste weiterer Agents, keine Profilzeile. **D** Zeile unter der Karte: `+` · Mehr-Chip (Popover mit weiteren Agents) · Assistenten 3–1 · Jarvis · Agents, bündig mit der Kartenkante; ⌥1–⌥9 = Jarvis, Assistenten, übrige. **E** `PanelShell.swift`: Seite und rechtes Panel (Agents, Thread-Seitenleiste) in einer Karte, ohne Trennlinie: Kartenboden (`surface`) hinter beiden, `CardJoin` füllt die Kerben an den runden Ecken der Seitenkarte, das Panel steht fest an der rechten Kartenkante und wird von der weichenden Seite freigelegt. **F** Flug: Jarvis und die Assistenten fliegen als Avatare aus der Zeile an ihre Plätze (320 ms, ease-out, 30 ms Staffel), Karte wächst gleichzeitig; Schließen rückwärts; Reduce Motion = Überblenden. Solange das Panel offen ist, sind diese Pills im Panel, nicht in der Zeile (Zeile: `+`, Mehr-Chip, Agents). **G** `⌘T`: Brain/Media/Tabs-Ansicht liegen über der Seitenkarte, ein Tab dahinter sah aus wie „tut nichts“, jetzt schließt `launch()` diese Ansichten; mit einem leeren Tab vorne bleibt es beim Wiederverwenden (Fokus im Feld), sonst neuer Tab. Globales Kürzel `⌥⌘J` (`VoiceHotKey` in `HotKey.swift`, Carbon, drückt/loslassen, einstellbar in Einstellungen › Models › Voice, aus mit ⌫): halten = Push-to-Talk, kurz = Zuhören bis zum nächsten Druck. Menüleisten-Symbol (NSStatusItem, pulsiert beim Zuhören; Rechtsklick: Zuhören, letzte Threads, Xool öffnen, Kürzel aus/an; Schalter in den Einstellungen). App Intent „Talk to Jarvis“ (`JarvisIntent.swift`) samt App-Shortcut-Phrasen; `build.sh` erzeugt `Metadata.appintents` mit `appintentsmetadataprocessor` aus den vom Build geschriebenen `*.swiftconstvalues`. ⌥-Klick auf Jarvis' Pill startet das Zuhören.

Geprüft (echter Lauf, Debug- und Release-Build): Screenshots hell und dunkel (`docs/shots/p8-newtab-*`, `p8-agents-*`, `p8-thread-sidebar-*`; Mehr-Chip `p8-more-popover-dark.png` und Menüleisten-Menü `p8-menubar-menu.png` nur dunkel, das Menüleisten-Symbol ist ein Template-Bild und folgt dem System, das ich nicht umgeschaltet habe), Bildfolge der Panel-Animation aus dem echten Fenster mit 8-fach verlangsamtem Flug (`p8-flight-open.png`/`p8-flight-close.png` als Bogen, Einzelbilder `p8-flight-open-NN.png`; `scripts/shoot-seq.sh`, `XOOL_FLIGHT_SLOW`; die Bilder zeigen den Flug verlangsamt, in echter Geschwindigkeit dauert er 320 ms und wurde nicht mit einer Aufnahme belegt). `⌘T` über den Menüpfad (`XOOL_UI=keyevent`). Globales Kürzel: ein echtes `⌥⌘J` (per CGEvent) bei Finder im Vordergrund erreicht `VoiceBridge.jarvisKey` und startet das Zuhören bei Jarvis (Log `XOOL_VOICE_LOG`). Menüleiste: echter Mausklick auf das Symbol startet das Zuhören bei Jarvis. Zuhören mit WAV: `jarvisfeed:<wav>` → Whisper → Jarvis-Thread → Antwort. `Metadata.appintents` im Bundle, Eintrag `TalkToJarvisIntent` und die drei Phrasen darin geprüft.

Nicht geprüft / bekannt: Die Kurzbefehle-App selbst (ob die Aktion dort in der Liste steht, brauchte Klicks in einer fremden App; die Metadaten sind erzeugt und gültig, die Registrierung beim System nicht gesehen); echtes Mikrofon und Lautsprecher bei Taste/Symbol (die Mikrofon-Erlaubnis und der Rundlauf mit gesprochener Stimme); Halten ≥ 0,4 s als Push-to-Talk und das „kurz drücken, bis zum nächsten Druck“ nur im Code und im Log, nicht mit Stimme; Verhalten der Taste, wenn eine andere App ⌥⌘J belegt (Meldung in den Einstellungen, nicht ausgelöst); Jarvis delegiert mit einem echten Modell (nur der Code-Pfad und die Tool-Beschreibung, kein Lauf); Seitenleiste rechts (`sidePosition == .right`) mit offenem Panel; mehrere Fenster teilen `PanelFlight`/`XoolUI` (zuletzt geändertes gewinnt); XCTest. Entscheidungen: Der Flug lässt die Pills im Panel „wohnen“ (Zeile ohne Jarvis/Assistenten, solange es offen ist). Kerbenfüllung statt eckiger Seitenkarte, damit die Webseite ihre Rundung behält. Das alte `Logomark` (Search) steht noch in `Design.swift`, ungenutzt.


---

## Stand Phase 9 (2026-11-26)

**Befund bestätigt.** Im echten Profil fehlte `~/Library/Application Support/Xool/voice`. Das „Diktat“ im Jarvis-Büro war ein Text-Diktat in ein Eingabefeld (also eine getippte Nachricht), und Jarvis' Prompt kannte weder Ohren noch Stimme. Jetzt: Stimme per `scripts/xool-setup.sh --only-voice` im echten Profil installiert (1,4 GB venv, Piper `de_DE-thorsten-high`, Whisper-Cache, 323 vertonte Phrasen unter `voice/cache/bridges`). Der Büro-Knopf ist ein Gesprächsknopf, kein Text-Diktat mehr.

Umgesetzt (A–F, Layout-Vertrag 8.1 unverändert; UI-Texte englisch wie die App):

- **A Einsatzbereit.** `VoiceOffice.swift`: Statuszeile im Büro (Ready / Listening / Thinking / Speaking / Installing / Waking up / Voice not set up) und Karte „Set up the voice (about 3 GB)“ mit Fortschritt, Stop und „Try again“ (`xool-setup.sh --only-voice`; das Skript holt jetzt auch Whisper und macht die 323 Phrasen: `python -m xool_voice --prepare`). Nach der Einrichtung startet der Sidecar sofort. Er startet auch mit der App (`VoiceBridge.install → autostart`), lädt Ohren und Phrasen vor und bleibt warm; bei Absturz bis zu drei Neustarts in fünf Minuten; die Ollama-Modelle werden warm gehalten (`keep_alive 60m`). Menüleiste: Statuszeile und „Set up the voice…“. Native Kette: ohne Sidecar `NativeEngine` (SFSpeechRecognizer + `AVSpeechSynthesizer` mit der besten installierten deutschen Stimme, Premium vor Enhanced) und Sofort-Urteil (`QuickJudge.swift`). Scheitert eine Antwort, wird eine Entschuldigung gesprochen, nie Stille. Nur ein vom Nutzer gestoppter Lauf bleibt still.
- **B Sprach-Prompt.** Jarvis' System-Prompt sagt jetzt immer, dass er hört und spricht und was installiert ist (`VoiceBridge.abilities`). Sprach-Turns bekommen `spokenStyle`: Sprachassistent, kurze natürliche Sätze, kein Markdown, keine Listen, keine Links, sprechbare Zahlen, Datum und Uhrzeit, „Werkzeuge sofort aufrufen, nie nur ankündigen“. `clean_for_speech` spricht Zahlen und Einheiten („3 Komma 5 Grad Celsius“, „12 Euro“, „beziehungsweise“). Satz für Satz, während das Modell schreibt (`SpeechChunker`, unverändert). Schutz im `AgentRuntime`: kündigt ein Modell nur an („Ich suche jetzt …“) und ruft nichts auf, obwohl das Urteil Werkzeuge verlangte, wird es einmal angestoßen.
- **C Duplex.** Gesprächsmodus (Wellenform im Büro, `⌥⌘J` kurz, Menüleisten-Symbol, Einstellungen › Models › Voice › Conversation): Das Mikrofon bleibt offen, Silero-VAD, Pause einstellbar (0,35 / 0,5 / 0,8 s, Standard 0,5). Halten von `⌥⌘J` oder `fn` bleibt Push-to-Talk. **Frühes Verstehen:** Whisper startet schon in den ersten 220 ms der Pause. Bleibt die Pause bestehen, steht der Text 0–1 ms nach dem Satzende da, sonst wird er verworfen. **Barge-in:** 5 von 12 Blöcken (0,4 s) klar lauter als das eigene Echo → Wiedergabe sofort stumm, Generierung abgebrochen, das Gesagte wird als nächster Satz verstanden. **Echo-Unterdrückung im Sidecar:** Er führt den Pegel der eigenen Ausgabe mit, lernt in den ersten 0,45 s jeder Sprechphase, wie viel davon das Mikrofon hört (Lautsprecher oder Kopfhörer), und verlangt danach eine Stimme deutlich über diesem Echo. Das ist ein Tor, kein echtes Echo-Löschen. `AVAudioEngine` Voice Processing ist **nicht** eingebaut (siehe unten). Vorausdenken (Thinker, „Übrigens …“) ist unverändert aus Phase 4 und läuft in den Pausen des Gesprächsmodus.
- **D Gemeint?** Sitzung (Standard 20 s; 10, 20 oder 40 s in den Einstellungen). Sie öffnet mit dem Start des Gesprächs, mit „Jarvis …“ (Name unscharf erkannt: Jarvis, Jarwis, Travis …), mit „Hey Jarvis“ und nach jeder Antwort. „Tschüss“ schließt sie. Ohne Taste und ohne Namen entscheidet das schnelle lokale Modell (`DecisionModel.addressed`, bevorzugt `gemma4:12b`, sonst das kleinste installierte; JSON `to_assistant`, mit Beispielen im Prompt), in der Sitzung und außerhalb. Ohne Modell gilt: in der Sitzung ja, sonst nein. Nicht gemeint → nichts gesagt, nichts im Thread (Log „ignored“). **Weckwort** „Hey Jarvis“ (openWakeWord, lokal, Standard aus, Schalter in den Einstellungen; das Modell wird beim Einrichten mitgeladen).
- **E Brücken und Sofort-Urteil.** `phrasen.py`: **323 Phrasen in 21 Situationen** (Frage, Befehl, Erzählung, Gefühl, Freude, Meinung, **Websuche (30), Browser (25), Brain (20)**, Delegieren, Rechnen, Erklären, Lob, Überraschung, Rückfrage, Entschuldigung, Abschied, Hallo, Warten, Unklar, Danke). Alle werden beim ersten Start vertont und als `.npy` gecacht (Start danach: 323 aus dem Cache). Keine Wiederholung: nicht in den letzten 60 Wahlen und nicht innerhalb von 4 Minuten. `urteil.py` (kein Modell, Mikrosekunden) liefert mit jedem Transkript `route` (wissen / web / browser / brain / delegate / calc), `kind` (Phrasengruppe), `tools` und `named`. „Wissen“ → Lauf ohne Werkzeuge über das schnelle Sprachmodell (Rolle Voice, sonst `OllamaCatalog.quickVoice`, Reihenfolge aus jarvis-on-nod). Alles andere → Agent mit Werkzeugen. Die Brücke läuft sofort. Bei „wissen“ und einem Modell, das im Schnitt unter 0,6 s zum ersten Satz braucht, kommt sie nach 250 ms Karenz und nur, wenn dann noch kein Satz da ist. Nach 9 s und 21 s ohne Satz kommt eine „Warten“-Phrase.
- **F Lizenzen** in `THIRD_PARTY_NOTICES.md`. Wichtig: **Piper (`piper-tts` 1.x) ist GPL-3.0**, läuft als getrennter Prozess im venv und wird nicht gebündelt. Das **`hey_jarvis`-Modell von openWakeWord ist nur nichtkommerziell** (CC BY-NC-SA 4.0), das Weckwort ist deshalb standardmäßig aus.

**Belege, automatisiert** (WAV statt Mikrofon und Lautsprecher; Eingaben mit macOS-Stimmen wie „Anna“, nicht mit Piper):

1. `scripts/voice-e2e.py` (Sidecar mit `--fake-mic --record`, ein lokales Ollama antwortet im Sprachstil): 11 von 11 Prüfungen grün. Bericht und Ausgangs-WAVs liegen in `docs/voice-e2e/` (`report.json`, `1-wissen-out.wav`, `2-web-out.wav`, `3b-bargein-out.wav`).
   - Normale Frage → verstanden, Antwort als WAV-Aufnahme des Ausgangs, die Whisper wieder als „… Hauptstadt von Frankreich ist Paris …“ versteht, kein Markdown gesprochen.
   - Websuche-Frage → Route `web`, Brücke aus der Websuche-Gruppe („Ich schau schnell nach.“).
   - Lange Antwort mit 15 % Echo im Mikrofon → keine Selbstunterbrechung.
   - Barge-in → erkannt, Jarvis verstummt, „… ich habe eine andere Frage.“ wird verstanden.
   - Satz an jemand anderen → `named: false`.
2. Ganze App (Release-Build, Profil „shots“; `jarvisfeed`, `jarvisfree`, `voicemic` aus `XOOL_UI`; Protokolle `docs/voice-e2e/app-*.log`, Ausgangs-WAVs `app-wissen-out.wav` und `app-barge-out.wav`):
   - Wissensfrage → Brücke, erster Satz nach 0,67 s, gesprochen.
   - Websuche-Frage → Brücke („Moment, ich such das raus.“), der Agent ruft `web_search`, die Antwort wird gesprochen.
   - Gesprächsmodus mit offenem (simuliertem) Mikrofon → Frage per VAD erkannt, Antwort gesprochen, Zwischenruf → `barge_in` → Wiedergabe und Lauf abgebrochen, Zwischenruf verstanden und beantwortet.
   - „Schatz, kannst du bitte den Tisch decken …“ ohne Namen → **ignoriert** (nichts im Thread, nichts gesagt). Eine Folgefrage ohne Namen in offener Sitzung → beantwortet.
   - Native Kette (Sidecar-Ordner absichtlich leer): Apple-Erkennung versteht die WAV, Jarvis antwortet, `AVSpeechSynthesizer` spricht (Ereignisse speaking an und aus).
   - Einrichtungs-Karte: frische Installation in einen leeren Ordner über den Knopf-Pfad (`voicesetup`), Fortschritt im Büro, danach startet der Sidecar von selbst und meldet „warm“.
   - Screenshots: `docs/shots/p9-office-{ready-dark,ready-light,missing-dark,installing-light}.png`.

**Latenzen** (M5 Pro, 64 GB, Whisper large-v3-turbo über MLX, `gemma4:12b` warm). „Satzende“ ist der Endpunkt nach der Pause. Die Pause selbst kommt dazu (Standard 0,5 s).

| Messung | Ergebnis | Ziel |
|---|---|---|
| Satzende → Text da (frühes Verstehen) | 0–1 ms (Whisper selbst 200–220 ms, läuft in der Pause) | – |
| Satzende → Brückenphrase hörbar | 0–16 ms (App 11–33 ms) | < 300 ms ✓ |
| Modell: erster Satz fertig (Wissensfrage) | 195–290 ms im Sidecar-Test, 0,24–0,70 s in der App | < 1,5 s ✓ |
| Satzende → erster echter Satz **hörbar** (nach der Brücke, die erst ausgespielt wird) | 1,1–1,3 s | < 1,5 s ✓ |
| Adressaten-Entscheidung (warm / erster Aufruf) | 160–360 ms / ≈ 730 ms | – |
| Barge-in: Stimme setzt ein → Jarvis still | ≈ 160 ms (5 Blöcke); bei lautem Echo und leiser Stimme bis ≈ 700 ms | – |
| Barge-in: Entscheidung → Wiedergabe stumm | 0,1 ms (App-Abbruch im selben Ereignis) | < 150 ms ✓ |
| **Werkzeug-Route** (Websuche) mit Jarvis' `qwen3.5:27b` | erster Satz nach ≈ 7 s (der dichte 27B liest den Werkzeug-Prompt; in der Zeit spricht die Brücke) | < 1,5 s **nicht erreicht** |

Das Tool-Ziel scheitert am gewählten Modell, nicht an der Stimme. Ein schnelles MoE (z. B. `qwen3.6:35b-a3b`, in `voicePreference` vorn) als Jarvis- oder Agent-Modell bringt es in die Nähe. Jarvis' eigenes Modell überschreibe ich nicht (das Wort des Nutzers).

**Nicht geprüft / bekannt:**
- Echtes Mikrofon und echte Lautsprecher: die Mikrofon-Abfrage von macOS für den Sidecar (er läuft als Kindprozess der App), Echo im echten Raum, Wirkung des Echo-Tors bei lauten Lautsprechern, Kopfhörer, Stimmen echter Menschen, Dialekt, Hintergrundgeräusche. Die Eingaben waren synthetische macOS-Stimmen.
- **Kein echtes Echo-Löschen** (`setVoiceProcessingEnabled`, Voice Processing). Es bräuchte Mikrofon **und** Ausgabe in derselben `AVAudioEngine`, der Sidecar spielt aber selbst ab. Nächster Schritt wäre, die Audio-Ein- und -Ausgabe nach Swift zu holen und PCM zwischen App und Sidecar zu schicken. Bis dahin sind Kopfhörer sicher. Mit Lautsprechern kann die Stimme bei sehr lautem Echo nicht oder zu spät unterbrechen, selten auch sich selbst. Gegenmittel: „Talk over the voice“ aus.
- Weckwort nur in Python mit synthetischem „Hey Jarvis“ geprüft (erkannt), nicht in der App mit echtem Mikrofon. Das Modell ist nichtkommerziell.
- SpeechAnalyzer (macOS 26) nicht benutzt. Die native Kette ist `SFSpeechRecognizer` (nur Push-to-Talk, kein Gesprächsmodus ohne Sidecar).
- Menüleisten-Statuszeile und Menüeintrag nur gebaut, nicht im Bild. Schalter „Hey Jarvis“ sowie Sitzungs- und Pausen-Auswahl nur gebaut.
- Der Thread zeigt den gesprochenen Text so, wie das Modell ihn schreibt (ohne Markdown, weil der Sprach-Prompt es verbietet). Eine formatierte Fassung neben der gesprochenen gibt es nicht.
- Der Zweitversuch „kündigt nur an“ kostet bei Tool-Fragen eine zusätzliche Modellrunde (≈ 3 s mit dem 27B).
- Die erste Einrichtung dauert je nach Leitung ein bis vier Minuten (Whisper 1,6 GB). Die Karte sagt „about 3 GB“ (venv 1,4 + Whisper 1,6 + Phrasen 0,1).
- XCTest.

### Checkliste für den echten Mikrofon-Test (Nutzer)

Vorher: ältere Kopie aus `/Applications` beenden und die App aus `build/Xool OS.app` starten. Beim ersten Sprechen fragt macOS nach dem Mikrofon: **Erlauben**. Fragt macOS nach Spracherkennung (nur der Apple-Weg), ebenfalls erlauben.

1. **Bereit?** Agents-Knopf → das Jarvis-Büro zeigt neben dem Namen „Ready“ (nach 5–10 s, vorher „Waking up“). Kein Kasten „Set up the voice“. Menüleiste: oben „Voice: Ready“.
2. **Push-to-Talk:** `⌥⌘J` halten, „Wie heißt die Hauptstadt von Frankreich?“, loslassen. Erwartet: kurze Brückenphrase (unter einer halben Sekunde), dann die Antwort auf Deutsch, Satz für Satz, kein „Sternchen“, kein vorgelesener Link. Der Thread zeigt dasselbe als Text.
3. **Gesprächsmodus:** `⌥⌘J` kurz drücken (oder die Wellenform im Büro). Das Symbol pulsiert, kein Tastendruck pro Satz. Frage stellen, kurz Pause machen, Antwort abwarten.
4. **Folgefrage ohne Namen** innerhalb von 20 s („Und wie viele Einwohner hat sie?“) → er antwortet. Nach über 20 s Stille und ohne „Jarvis“ antwortet er nur, wenn es klar an ihn geht.
5. **Nicht gemeint:** mit jemandem im Raum sprechen, laut zu dir selbst reden, den Fernseher laufen lassen → er sagt nichts, im Thread entsteht nichts. Dann „Jarvis, …“ → er antwortet.
6. **Websuche:** „Jarvis, such im Internet die neuesten Nachrichten zu Apple.“ → passende Brückenphrase („ich schau kurz im Netz nach“), der Agent-Tab öffnet sich sichtbar, die Antwort wird gesprochen. Dauert es lange, kommt nach etwa 9 s eine „Ich bin noch dran“-Phrase. Mit einem langsamen Modell kann der erste echte Satz einige Sekunden brauchen.
7. **Browser und Brain:** „Öffne github.com“ → „Ich öffne das mal“-Phrase. „Was steht in meinen Notizen zu …?“ → „Ich schau in deine Notizen“.
8. **Barge-in:** Jarvis eine lange Antwort geben lassen („Erzähl mir ausführlich von Paris“) und dazwischenreden → er verstummt sofort, das Gesagte wird als nächste Frage verstanden. **Zweimal prüfen: mit Kopfhörern und mit den Lautsprechern.** Unterbricht er sich bei Lautsprechern selbst, oder lässt er sich nicht unterbrechen: Lautstärke senken oder Kopfhörer; Einstellungen › Models › Voice › „Talk over the voice“ aus. Bitte notieren, wie laut es war.
9. **Weckwort:** Einstellungen › Voice › „Say Hey Jarvis“ an, den Gesprächsmodus aus lassen, „Hey Jarvis, wie spät ist es?“ → er antwortet. Das Modell ist nur nichtkommerziell.
10. **Abschied:** „Tschüss“ → kurze Abschiedsphrase, die Sitzung schließt (danach braucht er wieder seinen Namen).
11. **Stimme fehlt (optional):** `~/Library/Application Support/Xool/voice` umbenennen, App neu starten → das Büro zeigt „Voice not set up“ und die Karte. Jarvis antwortet auf Sprache trotzdem hörbar mit der Mac-Stimme (Push-to-Talk). Danach den Ordner zurückbenennen.
12. **Gefühl:** Die Brücke wirkt sofort, Antworten brechen nicht mitten im Wort ab, nichts wird doppelt gesagt, keine Phrase wiederholt sich in kurzer Folge. Auffälliges bitte mit Uhrzeit notieren.
