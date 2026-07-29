# kanshi_gui 2.0 — Sanierungs- und Neuentwurfsplan

**Stand:** 2026-07-29 · **Basis:** `main` @ `8e1eeb5` · **Branch:** `v2.0` · **Version:** 2.0.0+40

Dieses Dokument war die Arbeitsgrundlage für eine neue Major-Version und ist jetzt zugleich
ihr Protokoll. **M0–M9 sind umgesetzt** (35 Commits, 358 → 558 Tests, keine Skips,
`flutter analyze --fatal-infos` sauber, Release-Build grün). Offen ist nur M10, der
nachträglich ergänzte UI-Polish.

Zwei Dinge fehlen bewusst und können nicht von der Umsetzung erledigt werden:

- **Nicht gepusht.** Der Branch liegt lokal. Veröffentlichen ist eine Entscheidung des
  Maintainers, kein Schritt des Plans.
- **Der Reboot-Test steht aus.** Ob Anordnung und Workspaces nach einem echten Neustart und
  einem echten Dock-Wechsel sitzen, zeigt sich nur an echter Hardware. Vor jedem Schreiben
  liegt ein Backup in `~/.config/kanshi/backups/`, und „Backup wiederherstellen" funktioniert
  seit M4 tatsächlich.

---

## 0. Wie dieser Befund entstanden ist

Zehn parallele Deep-Reads über alle Subsysteme, jeder mit der Auflage, jede Aussage an
`pfad:zeile` zu belegen. Anschließend eine adversariale Prüfung, die alle als
`critical`/`high` gemeldeten Befunde **zu widerlegen versuchte** — mit ausdrücklichem
Auftrag, im Zweifel gegen den Befund zu entscheiden. Danach ein Architektur-Panel aus
drei unabhängigen Zielentwürfen sowie ein separater UX-Neuentwurf mit vier konkurrierenden
Konzepten und drei Jurys.

Mehrere Agents haben nicht nur gelesen, sondern **Probe-Tests gegen den echten Controller
geschrieben**; diese Befunde sind unten als *reproduziert* markiert.

| | |
|---|---|
| Rohbefunde | 145 |
| davon adversarial geprüft (critical/high) | 70 |
| widerlegt | **0** |
| bestätigt, Schwere unverändert | 34 |
| bestätigt, Schwere korrigiert | 36 |
| **Endstand critical** | **8** |
| **Endstand high** | **22** |

### Was ausdrücklich in Ordnung ist

Das ist kein „schlampiger Code". Wer hier aufräumt, sollte wissen, was er nicht anfassen darf:

- `flutter analyze` ist sauber (0 Issues), alle **358 Tests laufen grün**.
- Der Config-Schreibpfad ist sorgfältig gebaut: atomar über `tmp` + `rename`, Backup **vor**
  dem Schreiben, Rollback bei Fehlschlag, Skip-if-identical gegen Backup-Verschleiß
  (`config_service.dart:120–185`).
- Das Drag-Cancel-Epoch-Protokoll (`_dragCancelEpoch`) ist ein sauberes Invalidierungsmuster.
- `_reconcileChain` serialisiert die Mirror-Reconciles korrekt.
- Die Kommentardichte ist hoch und die Kommentare sind *ehrlich* — mehrere der schwersten
  Befunde stehen sinngemäß bereits als Warnung im Code.
- Die 358 Tests treiben überwiegend die **öffentliche** API von `KanshiController`. Genau das
  macht eine Strangler-Fig-Migration überhaupt erst möglich: die Tests überleben die
  Zerlegung.

---

## 1. Die Diagnose

Die Befunde wirken zunächst wie 145 Einzelprobleme. Sie sind es nicht. Fast alle sind
Ausprägungen von **zwei** Grundentscheidungen, die nicht tragen.

### 1.1 Drei Zustände, die nicht getrennt sind

Die App kennt keinen Unterschied zwischen

1. **was im Profil steht** (der gespeicherte Wunsch),
2. **was physisch angeschlossen ist** (die Hardware-Realität),
3. **was der Compositor gerade tut** (der Laufzeitzustand).

`MonitorTileData` ist ein einziges 14-Feld-DTO für alle drei Rollen — plus vierte Rolle als
Editor-Entwurf. `Profile` hat zwei **mutable** Felder. Ergebnis: Safety-Net-Closures,
Drag-Sessions und Hotplug-Handler schreiben sich gegenseitig in die Listen.

Daraus folgen unmittelbar:

- `_wouldLockOutUser` zählt Profil-Monitore statt angeschlossener → der einzige physisch
  vorhandene Bildschirm lässt sich abschalten *(reproduziert)*.
- Das auto-erzeugte Profil „Current Setup" **aliast** `_currentMonitors` → Editor-Drags
  überschreiben den Compositor-Snapshot, Drift-Erkennung wird blind.
- Safety-Net-Revert-Closures halten eine `monitors`-Liste über `await` hinweg fest; jede
  andere Mutation ersetzt das `Profile`-Objekt, die Closure schreibt danach ins Leere →
  Compositor und Config widersprechen sich dauerhaft *(reproduziert)*.
- `_rehydrateProfilesAgainst` schreibt gespeicherte Profil-IDs auf die aktuellen Portnamen um
  — und die Refresh-Rate gleich mit.

### 1.2 Instabile Identität — die Wurzel deines Reboot-/Dock-Problems

Die Profile werden mit der **instabilsten Kennung adressiert, die es gibt**: dem
Connector-Namen.

```
output 'DP-1' enable scale 1.00 mode 3440x1440@49.987Hz transform normal position 2526,0
# kanshi_gui:edid 'DP-1'='Samsung Electric Company S34J55x H4LR500240'
```

`kanshi(5)` auf diesem Rechner warnt wörtlich davor:

> *An output name (e.g. "DP-1"). Note, output names may not be stable: they may change across
> reboots (depending on kernel driver probe order) or creation order (typically for USB-C docks).*

Reboot und USB-C-Dock — exakt das gemeldete Fehlerbild. kanshi bietet die stabile Form an
(`output "Samsung Electric Company S34J55x H4LR500240"`), und **kanshi_gui kennt diese Werte
längst** — schreibt sie aber nur in einen Kommentar, den ausschließlich die GUI selbst liest.
Die stabile Identität liegt in der Datei und wird kanshi vorenthalten.

Verschärfend: `_rehydrateProfilesAgainst` (`kanshi_controller.dart:640–666`) konvertiert
selbst ein von Hand geschriebenes, identifier-basiertes Profil beim nächsten Speichern auf
Portnamen zurück.

Die zweite Hälfte, die Workspaces, hat dieselbe Wurzel plus ein Timing-Problem. Die gesamte
Kette hängt in **einem** `exec swaymsg "…"`, und `kanshi(5)` sagt dazu:

> *Commands are executed asynchronously and their order may not be preserved.*

Kennt Sway einen Portnamen zum Ausführungszeitpunkt noch nicht, verwirft es das
`output 'X'`-Target still. Die App hat dafür eine Selbstheilung
(`_verifyAndFixWorkspacePlacement`), aber sie läuft nur in `init()`, `setMirror()` und
`setWorkspaceDistribution()` — **nicht im Hotplug-Pfad**, und die GUI ist nicht autostartet.

> **Korrektur zu einer früheren Aussage:** kanshi führt die `exec`-Kette bei *jeder*
> Profilaktivierung erneut aus, auch beim Hotplug. Die Workspace-Platzierung hängt also
> nicht an der laufenden GUI. Die GUI-Reparatur ist ein Nachbessern für das dokumentierte
> Kaltstart-Rennen — ihr Fehlen im Hotplug-Pfad ist eine Lücke, nicht der Hauptmechanismus.

### 1.3 Der Grammatik-Bruch

Der Parser ist zeilen- und regexbasiert und verlangt das Schlüsselwort `enable|disable`, das
kanshis DSL **optional** macht (`kanshi_config_parser.dart:382`). Ein Profil, das dieses Wort
nicht enthält, parst als *0 Monitore*. Der Writer überspringt leere Profile
(`kanshi_config_writer.dart:87`). `saveProfiles` schreibt das Ergebnis über die Datei.

**Eine von Hand geschriebene kanshi-Config wird beim ersten Speichern der GUI gelöscht.**
*(reproduziert, CONFIRMED critical.)* Rettung ist einzig das Backup, das vor dem Schreiben
angelegt wird.

Vom kanshi-Sprachumfang modelliert der Parser nicht: geklammerte `output { … }`-Blöcke,
globale `output`-Defaults, `alias $name`, `...output` mit Wildcards, `adaptive_sync`,
`mode preferred`, `mode --custom`, unbenannte Profile, `include`. Was er *doch* liest, wird
beim Schreiben teils verfälscht: Modi werden erfunden (`1920x1080@60Hz` als Default),
Flip-Transforms fallen weg, `exec`-Zeilen und Kommentare verschwinden.

---

## 2. Zielbild 2.0

### 2.1 Produktdefinition

> kanshi_gui zeigt die Bildschirme, die an deinem Rechner hängen, so angeordnet wie sie
> physisch auf dem Tisch stehen, und lässt dich sie durch Ziehen bewegen, skalieren und
> abschalten. Es merkt sich jede Kombination von Bildschirmen, die du benutzt — nach einem
> Neustart, nach dem Andocken, auch mit geschlossenem Fenster.

Das Versprechen steht als Satz am unteren Fensterrand, **und nur dann, wenn die App es
tatsächlich geprüft hat**:

> ✓ Gespeichert. Diese Bildschirme kommen genau so wieder.

### 2.2 Leitprinzipien

Formuliert als Entscheidungsregeln, damit sie künftige Diskussionen beenden können.

1. **Der grüne Haken ist das Rendering eines Vergleichs, der gelaufen ist** — nie Deko. Wenn
   Rückvergleich oder Daemon-Prüfung nicht abgeschlossen werden konnten, wird der Satz
   schwächer und ehrlicher. Er wird nie leiser und nie weggelassen.
   *Beendet:* „Können wir nicht einfach nach dem Write ‚gespeichert' anzeigen?" — Nein.
2. **Was aus etwas ableitbar ist, das der Nutzer ohnehin ansieht, wird abgeleitet und der
   Regler gelöscht.** Workspace-Reihenfolge kommt aus der Anordnung, „Extend" ist das, was
   Ziehen ohnehin tut.
   *Beendet:* jeder Vorschlag für einen neuen Schalter — zuerst zeigen, warum die Antwort
   nicht schon auf dem Schirm steht.
3. **Jedes Wort in Prosa hat seine Zahl einen Klick entfernt, und jede Zahl, die die App
   anzeigt, ist wieder eintippbar.** Slider ist die Vordertür, das Feld ist die Wahrheit.
4. **Eine irreversible Änderung bleibt nur, wenn der Nutzer aktiv zustimmt.** Kein Klick
   anderswo, kein Fokuswechsel, kein Timeout-to-keep. Der Timeout revertiert immer.
5. **Eine neue Oberfläche darf nur erscheinen, wenn sie eine alte löscht**, und keine zwei
   Oberflächen sagen dasselbe.
6. **Was die App von selbst tut, kündigt sich durch Bewegung an und ist mit Ctrl+Z
   rückgängig** — auch Auto-Reparatur und Auto-Switch. Durch Text nur, wenn es zweimal
   fehlschlug.
7. **Die Wörter „Profil" und „kanshi" kommen in der laufenden UI nicht vor**, mit genau zwei
   auditierten Ausnahmen: die Config-Pfad-Zeile im Erweitert-Sheet und der Fehlersatz
   „kanshi läuft nicht". Durchgesetzt per CI-`grep` über `lib/`.

### 2.3 Vokabular

Ein Profil heißt künftig **Setup** — nicht „Ort": ein Laptop-Setup und ein Zug-Setup sind
keine Orte, und kanshi matcht Hardware, nicht Geografie.

| heute | künftig |
|---|---|
| profile | **Setup** |
| kanshi / kanshictl | *(nichts)* |
| output | **Bildschirm** |
| Connector-Name (DP-1) | **Port**, grau/mono, nur in der Detailzeile |
| EDID / manufacturer | der **Name** des Bildschirms („Dell U2720Q") |
| mode | **Auflösung** (Hz als Inline-Segmente) |
| scale | **Größe** — „Größer ↔ Mehr Platz" + editierbares % |
| transform | **Drehung** |
| enabled / disabled | **an / aus** (aus = liegt im Regal) |
| live apply / Apply / unapplied | *(entfällt — alles ist live)*, Ersatz: **Halten** |
| drift | *(kein Wort)* — ein Bildschirm außerhalb seines gestrichelten Umrisses, „Zurücklegen" |
| workspace management / interleaved | **„Wo Fenster aufgehen"** — gelernt, nicht konfiguriert |
| safety net | **„Kannst du das lesen?"** |
| mirror | **„Zeigt dasselbe wie …"** |

Genau **ein** neues Verb muss gelernt werden: **Halten**. Ein gehaltenes Setup friert ein —
nichts Automatisches schreibt hinein, eigene Änderungen gehen live an die Bildschirme, aber
nicht auf die Platte. Beim Loslassen: „Änderungen behalten / Zurück auf gespeichert". Das ist
gleichzeitig der Ersatz für das gestrichene `liveApply`.

---

## 3. Track A — Stabilisieren

Fehler, die heute reale Schäden verursachen. Jeder Punkt ist ein eigener Commit mit
Regressionstest. Keiner davon braucht die Architekturarbeit.

### A1 — Sofort, einzeilig, hohe Wirkung

| # | Befund | Ort | Fix |
|---|---|---|---|
| A1.1 | `safetyNetSeconds = 0` ist als „Aus" beschriftet, bewirkt aber **sofortiges** Zurücksetzen jeder Modus- und Abschaltänderung *(reproduziert)* | `safety_net.dart:64` | `guard()` kehrt ohne Timer zurück, wenn `window <= Duration.zero` |
| A1.2 | `_wouldLockOutUser` zählt abgesteckte Outputs mit *(reproduziert)* | `kanshi_controller.dart:1935` | gegen `_currentMonitors` / `monitorIsConnected` prüfen |
| A1.3 | „Current Setup" aliast `_currentMonitors` | `kanshi_controller.dart:685` | Liste kopieren |
| A1.4 | Profilnamen werden unescaped geschrieben — ein Apostroph erzeugt eine Config, die kanshi ablehnt → **komplettes Monitor-Management tot** | `kanshi_config_writer.dart:124` | Escaping + Validierung im Rename-Dialog, leere Namen ablehnen |
| A1.5 | Rotierter Output ohne Modes-Liste bekommt bei jedem Speichern einen transponierten, vom Compositor abgelehnten Modus | `kanshi_config_writer.dart:312` | unrotierte Mode-Dimension als Quelle der Wahrheit |
| A1.6 | Settings werden pro Slider-Frame über **einen gemeinsamen** `.tmp`-Pfad geschrieben — letzter Wert geht verloren, ~60 unbehandelte Exceptions pro Drag | `app_settings.dart:300` | Debounce + eindeutiger Temp-Name + `await` |

### A2 — Der Safety Net muss halten, was er verspricht

Der Safety Net ist das Feature, das dich davor bewahrt, ohne Bild dazustehen. Er hat drei
bestätigte Defekte:

- **A2.1** Revert-Closures schreiben in eine abgehängte Liste → Compositor schaltet den
  Bildschirm wieder ein, Modell und Config sagen weiterhin `disable`. Beim nächsten Reload
  geht er wieder aus. *(reproduziert)* → Reverts über ID neu auflösen, nicht über
  Referenz. `applyMode` macht es bereits richtig (`:1996–2003`) — das ist die Vorlage.
- **A2.2** Der Revert schreibt ins **falsche Profil**, wenn zwischenzeitlich gewechselt wurde
  (`:1988`).
- **A2.3** Ein fehlgeschlagener Revert ist still, nicht wiederholbar und lässt den Nutzer
  kaputt zurück (`safety_net.dart:70`).

> **Korrektur:** Der Befund „Safety Net stirbt mit dem Prozess" wurde auf *medium*
> herabgestuft. Der Fall, für den das Feature existiert — „ich habe einen Modus gesetzt, den
> der Monitor nicht kann" — ist abgedeckt, weil die App weiterläuft und der Timer feuert. Nur
> ein Absturz oder ein bewusstes Schließen des Fensters während des Countdowns verwirft die
> Absicherung. Der Watchdog (Track D) bleibt richtig, ist aber nicht die Notfallmaßnahme, als
> die er zunächst gemeldet wurde.

### A3 — Ehrlichkeit über Erfolg und Misserfolg

- **A3.1** Presets (`extendOutputs`, `mirrorAll`, `useOnlyOutput`, `rearrangeActiveLayout`)
  ändern nur `_profiles[idx]` und rufen `_scheduleSave()`. Anders als `_flushSaveAndReload()`
  ruft `_scheduleSave` **kein** `restartCompositorProfileApply()`. Trotzdem toastet die UI
  „Extended across all outputs.". Weil `liveApply` per Default `true` ist, ist
  `hasUnappliedEdits => !liveApply && _hasUnappliedEdits` **dauerhaft false** — der Hinweis
  kann nie erscheinen, der Apply-Button ist ausgeblendet (`home_page.dart:565`).

  > **Korrektur:** Die Änderung ist nicht verloren — der Debounce-Save schreibt sie in die
  > Config, kanshi wendet sie beim nächsten Reload oder Hotplug an. Und ein Apply-Pfad
  > existiert, nur nicht im Editor-Header: das GTK-Menü „Save & restart kanshi"
  > (`app_menu.dart:41`). Träge ist der *Moment des Klicks*, nicht der Vorgang insgesamt.

- **A3.2** Config-Schreibfehler werden verschluckt; `undo`/`redo`/`setMirror` melden Erfolg,
  obwohl nichts geschrieben wurde (`kanshi_controller.dart:2428`, `:837`).
- **A3.3** Zwei gleichzeitige Saves überschreiben sich und rollen die Datei auf den Stand vor
  der Bearbeitung zurück *(reproduziert)* (`config_service.dart:159`).
- **A3.4** „Restore backup" stellt die Datei wieder her und überschreibt sie unmittelbar
  danach mit den In-Memory-Profilen (`:2386`).
- **A3.5** `reapplyActiveProfile` ruft nacktes `kanshictl reload` ohne Fallback — auf diesem
  Rechner verifiziert **nicht funktionsfähig** (`:2198`).

### A4 — Hotplug

- **A4.1** Kein Debounce im gesamten Hotplug-Pfad (`sway_backend.dart:323`). Andocken erzeugt
  eine Salve von Events; jedes einzelne fährt Rehydrierung, Auto-Switch, Mirror-Reconcile und
  Drift-Berechnung gegen ein möglicherweise halb angeschlossenes Set. → *Settle-Barriere*:
  erst emittieren, wenn die Output-ID-Menge n ms stabil ist.
- **A4.2** `_verifyAndFixWorkspacePlacement` force-applied eine Kette aus einem halb
  verbundenen Set (`:426`).
- **A4.3** `ensureCurrentSetupMatches` fängt ein halb angedocktes Live-Layout als aktives
  „Current Setup" ein.
- **A4.4** `_rehydrateProfilesAgainst` überschreibt die gespeicherte Refresh-Rate jedes
  Profils mit der gerade aktiven — und der nächste Save persistiert das.

---

## 4. Track B — Persistieren

### B1 — Stabile Identität *(die wichtigste Einzeländerung des ganzen Plans)*

Umstellung der Output-Kriterien von Portname auf EDID-Beschreibung, die kanshi nativ
unterstützt:

```diff
- output 'DP-1' enable scale 1.00 mode 3440x1440@49.987Hz transform normal position 2526,0
- # kanshi_gui:edid 'DP-1'='Samsung Electric Company S34J55x H4LR500240'
+ output "Samsung Electric Company S34J55x H4LR500240" enable scale 1.00 mode 3440x1440@49.987Hz transform normal position 2526,0
+ # kanshi_gui:port "Samsung Electric Company S34J55x H4LR500240"='DP-1'
```

Der Kommentar kehrt sich um: der **Port** wird zur Notiz, die Identität zur Wahrheit.

Betrifft ebenso die Workspace-Kette. `kanshi(5)` dokumentiert die nötige Quoting-Form:

```
exec swaymsg "… move workspace to output '\"Samsung Electric Company S34J55x H4LR500240\"' …"
```

Sonderfälle, die mitgeplant werden müssen:

- **Kein Serial / identische EDIDs** (z. B. dein `InfoVision … 0x057D`): Kollision beim
  Schreiben erkennen und **nur für dieses Paar** auf Portnamen zurückfallen; der Rest des
  Setups bleibt EDID-basiert. Auf diesen Kacheln den Port dauerhaft anzeigen, weil ihre
  Identität wirklich portabhängig ist.
- **Migration bestehender Configs**: siehe offene Entscheidung O6.
- `_rehydrateProfilesAgainst` darf gespeicherte Identitäten **nicht mehr überschreiben**.

### B2 — Verlustfreies Speichern

Zwei Stufen, weil Stufe 1 sofort schützt und Stufe 2 Zeit braucht.

**Stufe 1 — Round-Trip-Verweigerung (klein, sofort).** Nach `render()` das Ergebnis
zurückparsen und den Write **verweigern**, wenn Profilanzahl, Output-Anzahl pro Profil oder
die Menge der beanspruchten Direktiven nicht übereinstimmen. Das allein verhindert das
Löschen handgeschriebener Configs, ohne den Parser anzufassen.

**Stufe 2 — echter scfg-AST (Track D).** Lexer → AST mit Source-Spans → chirurgisches
Zurückschreiben. Unbekannte Direktiven werden als opake Knoten **durchgereicht**, nicht
verworfen.

### B3 — Was heute nicht überlebt, aber muss

| Zustand | heute | 2.0 |
|---|---|---|
| Fenstergröße/-position | flüchtig | `app_state.json` |
| zuletzt aktives Setup | Marker zeigt auf ein Profil, **das gar nicht existiert** (`~/.config/kanshi/current` = „Current Setup") | konsistent oder ersatzlos |
| Workspace-Zuordnung | global konfiguriert | **pro Setup gelernt** |
| Undo-Historie | flüchtig | bleibt flüchtig (bewusst) |
| Drift-Dismissal | flüchtig | bleibt flüchtig |
| Backup-Aufbewahrung | zählt Dateien | **zusätzlich** ein gepinnter Snapshot pro App-Start |

Zum letzten Punkt: alle 10 Backups auf diesem Rechner stammen aus **einem** Fünf-Minuten-Fenster
am 28.07. Eine kurze Bearbeitungssession löscht die gesamte Historie. → Ring auf 20, plus ein
gepinnter Snapshot „Bevor du dieses Fenster geöffnet hast", der nicht rotiert.

### B4 — Settings härten

- Jeder Parse-Fehler in `settings.json` setzt heute still **alle** Einstellungen zurück und
  löst den First-Run-Wizard erneut aus (`app_settings.dart:269`). → Feldweise Fallbacks,
  defekte Datei beiseitelegen statt verwerfen.
- Kein `schemaVersion`-Feld, keine Migrationskette. → beides einführen, solange die Datei noch
  klein ist.

---

## 5. Track C — Refactor

Alle drei unabhängigen Architekturentwürfe sind auf dieselbe Zerlegung gekommen. Das Prinzip:
**pro Zustand genau ein Schreiber.**

`KanshiController` (2793 Zeilen, ~55 Methoden, ~24 Getter, 10 mutable public Felder, 5
nullable Callbacks) zerfällt in:

| neue Einheit | Verantwortung | ersetzt |
|---|---|---|
| `ProfileStore` + `HistoryStack` | Profile, aktiver Index, CRUD, Undo/Redo | `_profiles`, `_activeProfileIndex`, `_undoStack` |
| `LiveOutputs` | **einziger** Schreiber des Live-Snapshots, Hotplug-Diff, Settle-Barriere | `_currentMonitors`, `_subscribeHotplug` |
| `SaveCoordinator` | Debounce, Single-Flight-Mutex, Include-Zustand, Fremdänderungs-Erkennung, `SaveOutcome`-Stream | `_scheduleSave`, `_flushSaveAndReload`, `onConfigSaveBlocked` |
| `OperationQueue` + `ApplyService` | jede mutierende Compositor-Operation, ID-Neuauflösung nach jedem `await` | die verstreuten `await monitors.*`-Aufrufe |
| `OutputMatcher` (pure) | Normalisierung, Matching, Rehydrierung, Scoring, Suggestion | `_normalizeOutputId`, `_resolveOutputName`, `_ProfileScore` |
| `DragController` | eigenes `ValueListenable`, Sessions, Snapping, Escape-Zähler, Cancel-Epoch | `_dragSessions`, `previewSnap`, `snapAndCommit` |
| `MirrorCoordinator` | `setMirror`-Validierung, serialisierter Reconcile, Evakuierung | `_reconcileMirrors` |
| `WorkspacePlacement` | Verify/Fix, Ranks, Distribution, Chain-Bau | `_verifyAndFixWorkspacePlacement` + `kanshi_config_writer.dart:412–522` |
| `DriftMonitor` + `HotplugPolicy` | Drift-Cache, Auto-Reapply, Auto-Switch vs. Vorschlag, typisierte Events | die 5 nullable Callbacks |
| `PreferencesController` | besitzt `AppSettings` | die **elf** gespiegelten Controller-Felder |
| `KanshiDaemon` | `reload()`, `restart()`, `isRunning()` mit Fallback-Kette | `restartCompositorProfileApply` (heute **dreifach** dupliziert) |

**Wie ohne Bruch:** `KanshiController` bleibt als Fassade mit eingefrorener öffentlicher API
stehen und wird von unten ausgehöhlt, eine Kollaboration pro Commit. Jede Extraktion ist
verifiziert durch „dieselben 358 Tests laufen weiterhin" plus neue Tests, die die isolierte
Einheit direkt festnageln. Die bestehenden Tests werden bis zu den letzten Schritten **nicht
angefasst**.

Zusätzlich: `Profile.monitors` wird immutable (`List.unmodifiable` im Konstruktor). Damit
sind die Aliasing-Fehler aus 1.1 strukturell nicht mehr formulierbar.

---

## 6. Track D — Neu schreiben

Nur vier Dinge rechtfertigen einen echten Rewrite.

### D1 — Der Config-Layer (`lib/domain/kanshi/`)

Zeilen-Regexe können scfg nicht darstellen. Neu: `scfg_lexer.dart` (Atome, Quoted Strings,
Blöcke, Kommentare) → `scfg_ast.dart` mit Source-Spans → `kanshi_document.dart` als typisierte
Sicht. Nicht modellierte Direktiven bleiben als opake Knoten erhalten und werden
unverändert zurückgeschrieben. Erstklassige `OutputCriteria` (`byName` | `byDescription` |
`byAlias` | `wildcard`) statt eines nackten Strings.

### D2 — Das Domänenmodell (`lib/domain/`)

`MonitorTileData` wird in vier Typen aufgeteilt, weil es heute vier unvereinbare Jobs macht.
Besonders wichtig: es speichert `width`/`height` **bereits rotiert**, weshalb jeder Konsument
die unrotierte Mode mit eigenem `rotation % 180`-Swap zurückrechnet — an vier Stellen
(`writer:132`, `sway_backend:158`, `parser:420`, `home_page:684`). Neu: reine Dart-Typen ohne
Flutter-Import, `Mode` mit echter „unbekannt"-Repräsentation, `Transform` als Enum inklusive
Flip-Varianten, `Layout` als Invariantenhalter mit `normalize()` → Diagnostics.

### D3 — Die Snap-Engine

Bestätigt: das Snapping ist **reihenfolgeabhängig und verletzt beide Invarianten, die sein
eigener Docstring verspricht** (`layout_math.dart:121`). Dazu: `resolveOverlaps` plättet das
gesamte Layout in eine Reihe und läuft *im Serializer*. Neu als deterministischer
Zwei-Phasen-Solver in `lib/domain/ops/snap.dart`, mit Property-Tests.

### D4 — Crash-sicherer Revert

`PendingGuard`-Records als argv + Deadline nach `$XDG_RUNTIME_DIR` journalisieren, **bevor**
die riskante Operation läuft; beim Start jeden überfälligen Guard abspielen. Plus ein
losgelöster Watchdog, damit ein Fenster-Schließen mitten im Countdown nicht wie „Behalten"
wirkt.

---

## 7. Der UX-Neuentwurf

Vier unabhängige Konzepte, drei Jurys (It-just-works / Reale Aufgaben / Baubarkeit). Sieger
nach Synthese: die „Displays-Pane"-Linie als Rückgrat, mit den Reparaturen aus dem
Skeptiker-Konzept.

### 7.1 Das Fenster

Eine Spalte, vier Bänder. Kein `Stack` mit handgerechneten Offsets — heute steht dort
`top: EditorHeader.height + 10 + 96`.

```
┌────────────────────────────────────────────────────────────────────────────────┐
│  Schreibtisch  ⌄                                    ⌾ Identifizieren     ⋯     │ 56
│  2 weitere Setups gemerkt                                                      │
├────────────────────────────────────────────────────────────────────────────────┤
│                                                                                │
│                     ┌───────────────────────────────┐                          │
│     ┌────────────┐  │ ①                             │                          │
│     │ ②          │  │                               │                          │
│     │  Built-in  │  │        Dell U2720Q            │                          │
│     │  1512×982  │  │        2560 × 1440            │                          │
│     └────────────┘  │                               │                          │
│                     └───────────────────────────────┘                          │
│                    ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁                          │
│  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄  │
│    ╭──────────╮   ┌ ─ ─ ─ ─ ─ ┐                                                │ 78
│    │ Beamer   │   ╎ LG 24MK   ╎        ← das Regal, nur wenn nicht leer        │
│    │   aus    │   ╎ nicht da  ╎                                                │
│    ╰──────────╯   └ ─ ─ ─ ─ ─ ┘                                                │
├────────────────────────────────────────────────────────────────────────────────┤
│  Dell U2720Q      DP-3 · 3840×2160 nativ · bei [2560,0]           ⌾      ✕     │ 26
│  Auflösung [ 3840 × 2160, 60 Hz ⌄ ]  Drehen [▲][▶][▼][◀]  Nutzen als [ Haupt ⌄]│ 48
│  Größe  Größer ●──○──○──○ Mehr Platz  [150 %]  ⧉ Zeigt dasselbe wie… ⌄ ⏻ Aus   │ 44
├────────────────────────────────────────────────────────────────────────────────┤
│  ✓  Gespeichert. Diese Bildschirme kommen genau so wieder.       gerade geprüft │ 36
└────────────────────────────────────────────────────────────────────────────────┘
```

Die Streifen-Zeilen sind gegen 900 px Mindestbreite durchgerechnet, damit nie ein
Overflow-Menü entsteht. Im Ruhezustand ist der Streifen **0 px hoch** — es gibt keine
permanente Werkzeugleiste. Die Leiste mit den Vorschlägen („Nebeneinander legen", „Auf beiden
dasselbe zeigen") erscheint nur, wenn die Anordnung entartet ist, und verschwindet beim ersten
Drag.

**Was dabei gelöscht wird:** `profile_rail.dart` (338), `editor_header.dart` (151),
`presets_bar.dart`, `properties_inspector.dart` (247), `safety_net_banner.dart` (101), beide
Inline-Banner in `home_page.dart` (~130), `settings_page.dart` (599), `first_run_wizard.dart`
(266). Der Netto-Widget-Zuwachs ist **negativ**.

### 7.2 Ein Statussystem statt vier

Heute können Health-Banner, Drift-Banner, Safety-Net-Leiste und zwei SnackBars **gleichzeitig**
stehen. Neu: eine 36-px-Zeile, immer sichtbar, nie leer, genau eine Meldung, anklickbar für
das Nachweis-Sheet. Vier Stufen in strikter Priorität — *Entscheidung > Achtung > Arbeitet >
Ruhe*:

- **Ruhe** — der grüne Haken, **abgestuft nach dem, was tatsächlich verifiziert wurde**. Ohne
  Live-Backend: „Gespeichert. Ich kann deine Bildschirme von hier aus nicht sehen, mehr kann
  ich nicht versprechen." Kein Haken.
- **Arbeitet** — unterdrückt unterhalb von 400 ms, damit Drags nicht flackern.
- **Achtung** — genau sechs Meldungen, mehr gibt es nicht. Bernstein, eine Aktion, nie
  automatisch verschwindend.
- **Entscheidung** — der Safety Net. Verlässt die Zeile: Canvas dimmt auf 40 %, Karte in der
  Mitte, **plus `swaynag` auf jedem Output**, damit der Countdown überlebt, wenn das eigene
  Fenster gerade schwarz geworden ist. Fest 15 s, kein Regler. Nur Enter behält, nur Esc
  revertiert.

### 7.3a Die Formsprache muss durchgezogen werden — auch durch die Controls

Der bisher hässlichste Bruch war nicht die Leinwand, sondern dass **Dropdowns aus der
Formsprache herausfielen**: sie sind native Material-Widgets und bringen ihr eigenes
Aussehen mit, das mit nichts sonst im Fenster zusammenpasst. Das gilt für die ganze
Familie. Bestandsaufnahme im heutigen Code:

| Control | Vorkommen |
|---|---|
| `SnackBar` | 24 (entfallen mit M5) |
| `TextButton` | 17 |
| `FilledButton` | 11 |
| `SwitchListTile` | 9 |
| `DropdownMenu` | 9 |
| `IconButton` | 7 |
| `showDialog` / `AlertDialog` | 6 / 6 |
| `TextField` | 6 |
| `DropdownButton` | 5 |
| `MenuAnchor` | 4 |
| `SegmentedButton` | 2 |
| `Slider`, `PopupMenuButton` | je 1 |

Anforderung für M7 und M10: **kein Control bleibt auf Material-Defaults.** Jedes wird
entweder zentral aus den Tokens durchgestylt — über `ThemeData`, nicht pro Aufrufstelle —
oder durch eine eigene Komponente ersetzt. Menüs, Dropdowns, Dialoge und Popups zählen
ausdrücklich dazu: sie rendern in einem eigenen Overlay und erben deshalb *nicht*
automatisch, was an der Kachel eingestellt wurde. Genau daran ist es bisher gescheitert.

Prüfbar gemacht: ein Test, der `lib/` nach direkt konstruierten Material-Controls außerhalb
der Theme- und Komponentenschicht durchsucht und fehlschlägt, wenn eine neue Aufrufstelle
dazukommt. Sonst schleicht sich der Bruch beim nächsten Feature wieder ein.

### 7.3 Tokens

Nach `lib/design/tokens.dart`, literale Werte:

- **Abstände** 4 · 8 · 12 · 16 · 24 · 32 · 48. Bandhöhen 56 / 36 / 78 / 0 · 44 · 132.
- **Radien** chip 6 · screen 10 · control 8 · card 14 · sheet 20.
- **Typo** display 28/600 · title 20/600 · heading 17/600 · body 15/400 · label 13/500 ·
  caption 12/400 · mono 12 (Tabellenziffern) · micro 10/500.
- **Farben dark** bg `#0F1114` · surface `#16181D` · surfaceRaised `#1E2127` · screenFill
  `#23262D` · textPrimary `#E8EAED` · ok `#3FBF7F` · attention `#E8A33D` · danger `#E5544B` ·
  accent = Sways `client.focused`, sonst `#4C8DFF`.
- **Farben light** bg `#F5F6F8` · surface `#FFFFFF` · textPrimary `#15171A` · ok `#1E9E5F` ·
  attention `#B36B00` · danger `#C4362C`. Auswahl wird im Hellmodus über den **Ring**
  unterschieden, nicht über die Füllung.
- **Bewegung** — eine geschlossene Liste aus acht Animationen, alle mit impliziten Widgets,
  **null** `AnimationController`. Hover 80 · Snap-Tick 120 easeOutBack · Streifen 180 · Titel
  200 · Auflösen nach Drop 220 · Bildschirm kommt/geht 300 · Flug ins Regal 320 · Countdown
  15000 **linear** (weil er eine Uhr ist; Easing würde über die Restzeit lügen).
- **Abgeleitet, nicht konfiguriert:** `snapDistance = max(14, 0.02 × Canvas-Diagonale)`,
  Skalen-Rasten `[1.0, 1.25, 1.5, 1.75, 2.0]`, beides mit Alt aufhebbar.

Heute stehen dem gegenüber: 8 Radien, 9 Schriftgrößen, ~20 Abstandswerte, 12 fest verdrahtete
Hex-Farben — und ein Light-Theme, das nur auf etwa einem Drittel der App ankommt (Canvas,
Header, Presets und Kacheltext sind fest auf Dunkel verdrahtet, `dot_grid_background.dart:24`).

### 7.4 Einstellungen: von 18 auf 4

| Einstellung | Verdikt | Ersatz |
|---|---|---|
| `autoSwitchProfile` | **entfällt** | es gibt nichts zu wechseln — die Leinwand zeigt immer das Angeschlossene |
| `workspaceManagement` | **automatisch** | pro Setup **gelernt** aus der tatsächlichen Lage |
| `safetyNetSeconds` | **automatisch** | fest 15 s |
| `customModeRevertSeconds` | **automatisch** | derselbe Safety Net |
| `hotplugToasts` | **entfällt** | die Einflug-Animation *ist* die Meldung |
| `profileSuggestionToasts` | **entfällt** | es gibt keinen Vorschlag mehr |
| `autoRevertOnApply` | **entfällt** | es gibt kein Apply |
| `liveApply` | **entfällt** | ersetzt durch **Halten** |
| `autoReapplyOnDrift` | **automatisch** | stille Reparatur, aber nur im 3-s-Fenster nach einem Hotplug |
| `snapDistance` | **automatisch** | abgeleitet, Alt hebt auf |
| `scaleSnapping` | **entfällt** | Rasten mit 3 px Magnetzug + editierbares %-Feld |
| `accentArgb` | **entfällt** | aus Sways `client.focused` |
| `identifyBannerSeconds` | **automatisch** | Identifizieren wird ein **Schalter** |
| `mirrorScaling` | **sichtbar**, aber verschoben | pro Bildschirm auf dessen eigener Streifenzeile |
| `maxBackups` | **automatisch** | 20 rollierend + gepinnter Start-Snapshot |
| `themeChoice` | **sichtbar** | erste Zeile im Erweitert-Sheet, Default wechselt Dunkel → System |
| `kanshiConfigPath` | **Hintergrund** | Erweitert-Sheet |
| `firstRunDone` | **Hintergrund** | wird zu `coachHintShown` |

---

## 8. Roadmap

Jeder Meilenstein ist für sich auslieferbar. Die App ist zwischen zwei Commits nie kaputt.

### M0 — Das Netz, bevor irgendetwas angefasst wird
`ci.yml`: `pub get` → `flutter analyze --fatal-infos` → `flutter test --coverage`, auf jedem
Push und PR. `release.yml` wird von „jeder Push auf main" auf **Tag-getriggert** umgestellt.
Heute veröffentlicht jeder Push ein Release, ohne dass je ein Test gelaufen wäre.
Dazu `test/fixtures/kanshi/` mit den Beispielen aus `kanshi(5)` **wörtlich**, einer
handgeschriebenen `output eDP-1 position 0,0`-Form ohne `enable`, und der realen Config dieses
Rechners.
*Verifiziert durch:* der Golden-Test über die Fixtures ist **rot** — er dokumentiert B2.

### M1 — Track A1 + A2
Die sechs Einzeiler und die drei Safety-Net-Defekte, je ein Commit mit Regressionstest.
*Verifiziert durch:* die Probe-Tests der Audit-Agents werden zu echten Tests.

### M2 — Round-Trip-Verweigerung
Stufe 1 aus B2. Ab hier kann die App eine handgeschriebene Config nicht mehr löschen.
*Verifiziert durch:* Golden-Test wird grün oder verweigert sichtbar den Write.

### M3 — Stabile Identität *(der Meilenstein, der dein Reboot-Problem löst)*
B1 vollständig: EDID-Kriterien in Output-Zeilen **und** Workspace-Kette, Kollisionsbehandlung,
`_rehydrateProfilesAgainst` entschärft, Hotplug-Settle-Barriere (A4.1), `KanshiDaemon` mit
Fallback-Kette (A3.5). Plus ein „Jetzt testen"-Knopf, der die Kette neu anwendet und die
Live-Zuordnung zurückliest.
*Verifiziert durch:* Reboot + Dock-Reconnect, Workspaces und Anordnung sitzen. Manueller Test,
für den es keinen Ersatz gibt.

### M4 — Ehrlichkeit
`SaveOutcome` statt verschluckter Fehler (A3.2), Single-Flight-Write-Queue (A3.3),
Restore-Backup-Reihenfolge (A3.4), Presets erreichen den Compositor (A3.1).

### M5 — Die Zusicherungszeile
Erste sichtbare UX-Arbeit. Ersetzt beide Banner, die Safety-Net-Leiste und alle sieben
SnackBar-Aufrufe. Setzt M4 voraus — der grüne Haken wird aus dem Verifikationsergebnis
gerendert und aus sonst nichts.

### M6 — Stores
Track C, eine Extraktion pro Commit, Fassade bleibt stehen.

**Draußen:** `KanshiDaemon`, `OutputMatcher`, `SaveCoordinator`, `LiveOutputs`,
`HistoryStack`, `WorkspacePlacement`, `DragSessions`, `DriftMonitor`.

**Offen:** `ProfileStore` (inkl. `Profile` immutable), `OperationQueue`/`ApplyService`,
`MirrorCoordinator`.

**`PreferencesController` — hat sich in M8 erledigt, statt gebaut zu werden.** Die
Extraktion sollte elf gespiegelte Einstellungsfelder bändigen. M8 hat zehn Einstellungen
gelöscht; `applyStartupSettings` schiebt heute noch drei Werte weiter. Eine Abstraktionsschicht
für drei Werte zu bauen wäre Zeremonie. Das Problem ist verschwunden, weil die Ursache
verschwunden ist — das ist das bessere Ergebnis als es sauber zu kapseln.

### M7 — Leinwand, Kachel, Regal
Tokens, `monitor_tile.dart` neu (704 → ~330 Zeilen), Drift als gestrichelter Umriss statt
Banner, Regal für abgeschaltete Bildschirme, Resize-Deform-Fehler behoben.

**Das Regal, erledigt in M8 — aber anders als geplant.** Der eigentliche Schaden war nicht
die Position der geparkten Kacheln, sondern dass sie in die Bounding-Box eingingen, aus der
die Leinwand ihren Maßstab berechnet: jeder abgeschaltete Bildschirm verkleinerte die, die
man tatsächlich benutzt. Der Maßstab richtet sich jetzt nur noch nach dem aktiven Cluster;
geparkte Kacheln ragen in den Rand, den die 80-%-Passung ohnehin lässt. Ein eigenes Band
*unter* der Leinwand konkurriert mit dem Streifen um dieselbe Kante — diese Entscheidung
gehört in M10, nach dem Design-Review.

### M8 — Streifen, Titelleiste, Erweitert-Sheet
Der 300-px-Inspektor und die 248-px-Leiste verschwinden, `settings_page.dart` und
`first_run_wizard.dart` werden gelöscht. Zwölf Einstellungen hören auf zu existieren.

### M9 — scfg-AST und gelernte Workspaces
Track D1, danach die pro-Setup gelernte Workspace-Karte.
Hängt hart an M3 — ein Editor über einem ungelösten Boot-Rennen sähe grundlos kaputt aus.

**Die Nummern-Badges auf den Kacheln gehören nach M10.** Die Karte ist da, wird gelernt und
angewandt; sie *auf den Kacheln* anzuzeigen ist eine Gestaltungsentscheidung über dasselbe
Rechteck, das M10 gerade neu formt — Badge-Form, -Position und -Zustand vor dem Review
festzulegen hieße, sie zweimal zu entwerfen.

**Was die App weiterhin nicht lesen kann**, benannt statt verschwiegen: unbenannte Profile,
`output`-Blöcke in geschweiften Klammern, Kriterien per Beschreibung ohne `enable`, die
`...output`-Form und Flip-Transforms. Nichts davon geht beim Speichern mehr verloren — es
erscheint nur nicht in der Oberfläche. Ebenso `mode --custom`: `mode` ist ein Feld, das die
App besitzt und ersetzt, und ihr Modell kennt kein Custom-Flag. Das zu schließen ist der
Domänen-Umbau aus Track D2.

### M10 — UI-Polish: erst Review, dann eckigere Formsprache
Zweistufig, und die Reihenfolge ist der Punkt. Zuerst ein **Design-Review** des Zustands
nach M7/M8 — was trägt, was wirkt weiterhin generisch, wo bricht die Formsprache. Erst
danach, auf Basis dieses Reviews, eine bewusst **eckigere** Design-Sprache. Das revidiert
die Radien-Skala aus 7.3 (chip 6 · screen 10 · control 8 · card 14 · sheet 20) nach unten
und zieht Kanten-, Raster- und Trennlinien-Sprache nach. Zum Schluss der Feinschliff an
Abständen, Typo und Motion.

Explizit im Scope: **die Formsprache muss durch jedes Control durchgezogen sein** — siehe
7.3a. Dropdowns, Menüs und Dialoge sind der bekannte Bruch, weil sie in einem eigenen
Overlay rendern und nichts von der Kachel erben.

Hängt an M7 und M8: ein Review vor dem Umbau würde nur den alten Zustand bewerten.

---

## 9. Test- und CI-Strategie

Heute: **keine** CI-Prüfung, **null** Widget-Tests für ~4000 Zeilen UI, Backend-Parsing nur
gegen handgeschönte JSON-Fixtures (wlr-randr bei 37 % Abdeckung), Tests lassen lebende
`KanshiController` zurück, deren Debounce-Saves die Teardown überleben.

Ziel-Pyramide:

1. **Golden-Corpus** `test/fixtures/kanshi/` — reale Configs rein, Round-Trip raus, Byte-Diff.
   Das ist der wichtigste neue Test des ganzen Plans.
2. **Backend-Fixtures** aus echtem Kommando-Output: `swaymsg -t get_outputs` und `wlr-randr`
   in mehreren Versionen, aufgezeichnet über einen `--dump-raw`-Modus in
   `tool/probe_outputs.dart`.
3. **Property-Tests** für die Snap-Engine gegen die zwei Invarianten, die der Docstring heute
   schon behauptet.
4. **Widget-Tests** für die Zusicherungszeile, die Entscheidungskarte und die Kachelzustände.
5. **`test/support/harness.dart`** mit erzwungenem `dispose` im Teardown.
6. Lint-Verschärfung: `avoid_slow_async_io`, `unawaited_futures`, `discarded_futures`,
   `always_declare_return_types`, `prefer_final_fields` — jede dieser Regeln hätte eine
   Fehlerklasse aus diesem Audit gefunden.

---

## 10. Offene Entscheidungen

Diese kann nur der Maintainer treffen.

- **O1 — Das Wort.** „Setup" (meine Empfehlung: deckt „Nur Laptop" ab, übersetzt sauber, und
  verspricht nichts Geografisches) oder „Ort" (wärmer, aber falsch für Laptop- und Zugfälle)?
- ~~**O2 — Migration bestehender Configs auf EDID.**~~ **Entschieden in M3: evidenzbasiert und
  schrittweise.** Eine EDID-Kennung wird ausschließlich geschrieben, wenn ein Backend sie
  tatsächlich gemeldet hat — nie aus der gespeicherten Anzeigebezeichnung erraten. Das ist
  wichtig, weil die Anzeigebezeichnung das von kanshi geforderte `Unknown` weglässt und eine
  daraus abgeleitete Kennung nie matchen würde. Ein Profil für Hardware, die gerade nicht
  angeschlossen ist, behält also seinen Portnamen, bis du wieder an diesem Schreibtisch
  sitzt. Kein Big-Bang-Rewrite der Datei, keine Rückfrage nötig.
- **O3 — Default-Theme für Bestandsnutzer.** Bei Dunkel bleiben oder beim Upgrade auf System
  wechseln? Neuinstallationen bekommen so oder so System.
- **O4 — Setups, die sich um genau einen Bildschirm unterscheiden** (die klassische
  Dock-/KVM-Neuverhandlung): still ein zweites Setup anlegen und „Zusammenführen" anbieten,
  oder still das bestehende übernehmen und „Abspalten" anbieten?
- **O5 — „Halten" beim Loslassen:** nachfragen („Behalten / Zurück auf gespeichert") oder
  still behalten und auf Ctrl+Z vertrauen?
- **O6 — Nicht-Sway-Backends:** Abschnitte, die es dort nicht gibt (Hauptbildschirm, „Wo
  Fenster aufgehen"), ganz ausblenden (ehrlich, wirkt aber wie ein Funktionsverlust) oder
  sichtbar-deaktiviert zeigen?
- **O7 — Identify beim ersten Start:** eine große Zahl auf jedem physischen Bildschirm 0,55 s
  nach dem Öffnen als wortloses Onboarding — oder zu aggressiv für ein Werkzeug, das man auch
  für eine schnelle Korrektur öffnet?

---

## Anhang A — Bestätigte Befunde (critical + high)

Schwere nach adversarialer Prüfung. `PARTIALLY_TRUE` = Kern bestätigt, Formulierung oder
Schwere korrigiert; die Korrekturen stehen in den jeweiligen Abschnitten oben.

| Schwere | Track | Befund | Ort | Prüfung |
|---|---|---|---|---|
| critical | persist | Handgeschriebene kanshi-Config wird beim ersten Speichern gelöscht | `kanshi_config_parser.dart:382`, `kanshi_config_writer.dart:87` | CONFIRMED |
| critical | persist | Profile und Workspace-Ziele auf instabile Connector-Namen verdrahtet, stabile EDID nur im Kommentar | `kanshi_config_writer.dart:154`, `:174` | CONFIRMED |
| critical | rewrite | Speichern rendert die ganze Datei aus einem verlustbehafteten Modell — nicht lesbare Configs werden komplett gelöscht | `kanshi_config_parser.dart:371`, `:382` | CONFIRMED |
| critical | rewrite | Auch Gelesenes wird beim Schreiben verfälscht: Modi erfunden, Flips verworfen, exec/Kommentare/adaptive_sync gelöscht | `kanshi_config_parser.dart:394`, `:409` | CONFIRMED |
| critical | stabilize | Safety-Net-Revert schreibt in abgehängte Monitorliste — Compositor und Config widersprechen sich dauerhaft | `kanshi_controller.dart:1821`, `:1867` | CONFIRMED |
| critical | stabilize | Profilnamen unescaped — ein Apostroph macht die Config für kanshi unlesbar | `kanshi_config_writer.dart:124`, `:128` | CONFIRMED |
| critical | stabilize | Presets und Profilwechsel erreichen im Default-Modus den Compositor nicht, melden aber Erfolg | `home_page.dart:583`, `:589` | CONFIRMED |
| critical | stabilize | Safety-Net-Revert schreibt ins falsche Profil | `kanshi_controller.dart:1988`, `:1993` | CONFIRMED |
| high | persist | Schreibfehler verschluckt; undo/redo/setMirror melden Erfolg ohne Wirkung | `kanshi_controller.dart:2428`, `:837` | CONFIRMED |
| high | persist | Backend-Wahl schreibt die Config still um und zerstört Mirror- + Rank-Daten | `monitor_service.dart:129`, `:138` | PARTIALLY_TRUE |
| high | persist | `_rehydrateProfilesAgainst` überschreibt gespeicherte Output-IDs mit aktuellen Portnamen | `kanshi_controller.dart:618`, `:629` | CONFIRMED |
| high | rewrite | Snapping ist reihenfolgeabhängig und verletzt beide zugesagten Invarianten | `layout_math.dart:121`, `:138` | CONFIRMED |
| high | rewrite | Light-Theme greift nur auf ~⅓ der App | `dot_grid_background.dart:24`, `:26` | CONFIRMED |
| high | stabilize | `safetyNetSeconds = 0` („Aus") revertiert sofort statt gar nicht | `safety_net.dart:64`, `kanshi_controller.dart:1432` | CONFIRMED |
| high | stabilize | „Current Setup" aliast die Live-Liste — Editor-Edits korrumpieren den Compositor-Snapshot | `kanshi_controller.dart:685`, `:688` | CONFIRMED |
| high | stabilize | Zwei gleichzeitige Saves überschreiben sich und rollen die Datei zurück | `config_service.dart:159`, `:165` | CONFIRMED |
| high | stabilize | „Restore backup" überschreibt das Wiederhergestellte sofort wieder | `kanshi_controller.dart:2386`, `:2392` | CONFIRMED |
| high | stabilize | Rehydrierung überschreibt gespeicherte Refresh-Rate, nächster Save persistiert sie | `kanshi_controller.dart:629`, `:657` | CONFIRMED |
| high | stabilize | Settings pro Slider-Frame über gemeinsamen `.tmp` geschrieben, ~60 Exceptions pro Drag | `app_settings.dart:300`, `:302` | CONFIRMED |
| high | stabilize | Rotierter Output ohne Modes-Liste bekommt transponierten, abgelehnten Modus | `kanshi_config_writer.dart:312`, `:286` | CONFIRMED |
| high | stabilize | Rename akzeptiert leere Namen und Apostrophe | `profile_rail.dart:167`, `:229` | PARTIALLY_TRUE |
| high | stabilize | `_wouldLockOutUser` zählt abgesteckte Outputs mit | `kanshi_controller.dart:1935`, `:1937` | CONFIRMED |
| high | stabilize | Fehlgeschlagener Revert ist still und nicht wiederholbar | `safety_net.dart:70`, `:71` | CONFIRMED |
| high | stabilize | Countdown „0" ist als „Aus" beschriftet, bedeutet aber sofortiges Zurücksetzen | `settings_page.dart:150`, `:153` | CONFIRMED |
| high | stabilize | `toggleEnabled`: kein Guard für den einen Fall, den er abdecken muss | `kanshi_controller.dart:1821`, `:1860` | CONFIRMED |
| high | stabilize | CI führt die vorhandenen Tests nie aus; jeder Push auf main veröffentlicht ein Release | `release.yml:3`, `:60` | PARTIALLY_TRUE |
| high | stabilize | `_verifyAndFixWorkspacePlacement` erzwingt eine Kette aus halb verbundenem Set | `kanshi_controller.dart:349`, `:426` | CONFIRMED |
| high | stabilize | `reapplyActiveProfile` ruft nacktes `kanshictl reload` ohne Fallback — hier nicht funktionsfähig | `kanshi_controller.dart:2198`, `:2204` | CONFIRMED |
| high | stabilize | Kein Debounce im Hotplug-Pfad — jedes Event fährt die volle Pipeline gegen ein Teilset | `sway_backend.dart:323`, `:334` | CONFIRMED |
| high | stabilize | Preset-Knöpfe ändern nichts auf dem Schirm, melden aber Erfolg | `presets_bar.dart:37`, `:44` | PARTIALLY_TRUE |

## Anhang B — Zahlen zum Ist-Stand

| | |
|---|---|
| `lib/` gesamt | ~7.500 Zeilen |
| `kanshi_controller.dart` | 2.793 Zeilen, ~55 Methoden, ~24 Getter, 10 mutable public Felder, 5 nullable Callbacks |
| `home_page.dart` | 910 |
| `kanshi_config_writer.dart` / `_parser.dart` | 522 / 482 |
| `monitor_tile.dart` | 704 |
| `settings_page.dart` / `first_run_wizard.dart` | 599 / 266 (beide entfallen) |
| Tests | 28 Dateien, ~5.600 Zeilen, 358 Tests, davon **0** Widget-Tests |
| Laufzeit-Abhängigkeiten außer Flutter | 1 (`collection`) |
