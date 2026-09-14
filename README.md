# SSD-Tune

PowerShell-Skript für Windows, das die Ursachen für das Muster
*„SSD schreibt erst schnell, nach ein paar GB bricht sie ein, System hängt"*
findet und die sicheren Gegenmaßnahmen anwendet.

## Verwendung

PowerShell **als Administrator** öffnen: Windows-Taste + X → „Terminal (Administrator)".
Kontrolle, ob es geklappt hat: Die Eingabeaufforderung steht dann in
`C:\WINDOWS\system32`, nicht in deinem Benutzerordner.

```powershell
# Skripte fuer dieses Fenster erlauben - Windows blockiert sie sonst
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Sperre fuer heruntergeladene Dateien aufheben
Unblock-File $env:USERPROFILE\Desktop\SSD-Tune.ps1

# 1) Nur Analyse - verändert nichts
& $env:USERPROFILE\Desktop\SSD-Tune.ps1

# 2) Analyse + sichere Fixes
& $env:USERPROFILE\Desktop\SSD-Tune.ps1 -Apply
```

Pfade anpassen, falls das Skript woanders liegt.

### Häufige Fehlermeldungen

| Meldung | Ursache und Lösung |
| --- | --- |
| `Die Datei ... kann nicht geladen werden, da die Ausführung von Skripts auf diesem System deaktiviert ist` | Die `Set-ExecutionPolicy`-Zeile oben fehlt. Sie gilt nur für das aktuelle Fenster und ändert nichts dauerhaft. |
| `... ist nicht digital signiert` | `Unblock-File` auf die Datei anwenden (Zeile oben). |
| SMART-Werte, Temperatur und Verschleiß fehlen in der Ausgabe | Das Fenster hat keine Administratorrechte. Als Administrator neu öffnen. |

Weitere Schalter:

| Schalter | Wirkung |
| --- | --- |
| `-BenchGB <n>` | Größe des Schreibtests in GB (Default 10, `0` = überspringen) |
| `-Drive <X>` | Anderes Laufwerk prüfen (Default: Systemlaufwerk) |
| `-DisableSysMain` | Dienst SysMain/Superfetch abschalten (nicht in `-Apply` enthalten) |
| `-DisableSearchIndex` | Windows-Suchindizierung abschalten (nicht in `-Apply` enthalten) |

## Was geprüft wird

1. Laufwerk, Anbindung, Firmware — und ob Windows die SSD überhaupt als SSD führt
2. Freier Speicherplatz (größter Hebel für den SLC-Cache)
3. TRIM-Status und automatischer Optimierungszeitplan
4. Zustand: Temperatur-Throttling, Verschleiß, unkorrigierbare Fehler
5. Firmware-Stand samt passendem Herstellertool
6. Disk-Timeout und SATA Link Power Management
7. SysMain, Windows Search und Auslagerungsdatei als Mitverursacher
8. Over-Provisioning
9. **Schreibkurven-Test** — misst, nach wie vielen GB der SLC-Cache kippt und
   auf welche Dauerrate das Laufwerk danach fällt
10. Hinweise auf das, was nur manuell geht (Schreibcache, BIOS-Modus, Secure Erase)

Am Ende steht eine nach Priorität sortierte Zusammenfassung mit konkreten Befehlen.

## Was `-Apply` verändert

Ausschließlich verlustfreie Einstellungen:

- TRIM aktivieren, falls deaktiviert
- einmaliges ReTrim
- geplante Laufwerksoptimierung aktivieren
- Disk-Timeout auf „nie"
- SATA Link Power Management auf „Aktiv" (nur bei SATA; kostet auf Notebooks
  etwas Akkulaufzeit)

**Nicht** automatisch ausgeführt, weil folgenreich: Partition verkleinern
(Over-Provisioning), Secure Erase, Firmware-Update, Dienste abschalten.
Für diese Punkte gibt das Skript den fertigen Befehl aus.

## Der Schreibtest

Schreibt standardmäßig 10 GB in 256-MB-Schritten mit `FileOptions.WriteThrough`,
damit der RAM-Schreibpuffer die echten Gerätewerte nicht verdeckt, und gibt pro
Schritt die Rate aus. Die Testdatei wird danach gelöscht (auch bei Abbruch mit
Strg+C über einen `finally`-Block). Der Test läuft nur, wenn mindestens
Testgröße + 10 % Reserve frei sind. 10 GB sind für die Lebensdauer unerheblich —
die TBW-Budgets liegen bei hunderten Terabyte.

## Hintergrund

Beim Symptom „Cache voll, System hängt" sind zwei verschiedene Caches beteiligt:

- **SLC-Cache auf der SSD** — TLC/QLC-Zellen werden anfangs als schneller
  Pseudo-SLC beschrieben. Ist der voll, fällt die Rate auf native
  Geschwindigkeit, bei alten oder DRAM-losen Laufwerken auf 40–100 MB/s.
  Der Cache ist dynamisch: eine fast volle SSD hat kaum noch welchen.
- **Schreibpuffer im RAM** — Windows nimmt Daten erst schnell an und schreibt
  verzögert weg. Ist der Puffer voll, blockiert alles, bis die SSD hinterherkommt.
  Das ist der eigentliche Grund für das Einfrieren.

Deshalb wirken freier Platz, TRIM und Over-Provisioning stärker als jede
Registry-Einstellung: Sie vergrößern den SLC-Cache und senken die Write
Amplification.

## Lokal mit Claude Code weitermachen

Statt das Skript selbst zu starten, kann Claude Code die Diagnose direkt auf dem
Rechner ausführen und auf die Ergebnisse reagieren.

**1. Installieren** — normale PowerShell, *ohne* Administrator:

```powershell
irm https://claude.ai/install.ps1 | iex
```

Alternativ über WinGet: `winget install Anthropic.ClaudeCode`
(aktualisiert sich dann aber nicht automatisch).

**2. Prüfen:**

```powershell
claude --version
claude doctor
```

**3. Starten** — jetzt PowerShell **als Administrator**, sonst fehlen SMART-Werte
und TRIM lässt sich nicht ändern:

```powershell
cd <Ordner mit diesem Repo>
claude
```

Beim ersten Start einmal im Browser anmelden.

**4. Übergabe-Prompt** zum Einfügen in die lokale Session:

> Meine SSD ist älter: sie schreibt erst schnell, nach wenigen GB bricht sie ein
> und das System friert ein. Im Ordner liegt `SSD-Tune.ps1` — führe es aus
> (erst ohne Parameter, also nur Analyse), lies die Ausgabe, und erkläre mir,
> welcher Punkt bei mir konkret zieht. Danach wenden wir die Fixes an. Du läufst
> in einer Administrator-PowerShell, SMART-Werte sollten also lesbar sein.

Ohne Git for Windows nutzt Claude Code das PowerShell-Tool — für diese Aufgabe
genau richtig.
