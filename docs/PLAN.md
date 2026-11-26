# Xool OS – Bauplan

Ein schneller, nativer macOS-Browser mit KI-Agents (lokal zuerst, Cloud per API-Key optional), Second Brain, Sprachsteuerung mit Duplex-Mechanik und einer Design-Fläche mit Notion-artigen `/`-Blöcken.

Stand: 2026-11-26 · Status: Plan, noch kein Code im Repo.

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

### Phase 6 – Canvas + Blöcke
- `web/canvas` (TipTap + Slash-Menü + Canvas-Engine), Host in WKWebView, Speichern im Brain, Agent-Befehle.
- **Fertig, wenn:** Frame anlegen, Text mit `/` in Blöcke verwandeln, Bild einfügen, speichern, nach Neustart wieder da.

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
- Lizenz der Voice-Modelle (Piper-Stimmen) für die Weitergabe im Bundle prüfen.

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

