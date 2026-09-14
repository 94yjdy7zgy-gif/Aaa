<#
.SYNOPSIS
    SSD-Diagnose und Tuning fuer Windows (SATA / NVMe / USB).

.DESCRIPTION
    Sucht die Ursachen fuer "Cache laeuft voll, System haengt":
      - SLC-Cache-Einbruch (Schreibkurven-Test)
      - fehlendes/abgeschaltetes TRIM
      - SSD von Windows als HDD erkannt (-> defragmentiert statt TRIM)
      - zu wenig freier Platz / fehlendes Over-Provisioning
      - Temperatur-Throttling, Verschleiss, Firmware
      - SATA Link Power Management, Disk-Timeout
      - SysMain / Windows Search / Auslagerungsdatei als Mitverursacher

    STANDARD: reine Analyse, es wird nichts veraendert.
    MIT -Apply: die sicheren Fixes werden angewendet.

.PARAMETER Apply
    Wendet die sicheren Korrekturen an (TRIM ein, ReTrim, Defrag-Zeitplan,
    Disk-Timeout aus, SATA-LPM aus). Nichts davon loescht Daten.

.PARAMETER BenchGB
    Groesse des Schreibtests in GB. 0 = ueberspringen. Default 10.
    10 GB sind fuer die Lebensdauer voellig unerheblich (TBW liegt bei
    hunderten Terabyte), decken aber den SLC-Cache-Einbruch zuverlaessig auf.

.PARAMETER DisableSysMain
    Schaltet den Dienst SysMain (Superfetch) ab. Bewusst NICHT Teil von -Apply.

.PARAMETER DisableSearchIndex
    Schaltet die Windows-Suchindizierung ab. Bewusst NICHT Teil von -Apply.

.PARAMETER Drive
    Laufwerksbuchstabe ohne Doppelpunkt. Default: Systemlaufwerk.

.EXAMPLE
    .\SSD-Tune.ps1
    Nur Analyse.

.EXAMPLE
    .\SSD-Tune.ps1 -Apply
    Analyse plus sichere Fixes.

.EXAMPLE
    .\SSD-Tune.ps1 -Apply -BenchGB 20 -Drive D
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [int]    $BenchGB = 10,
    [switch] $DisableSysMain,
    [switch] $DisableSearchIndex,
    [string] $Drive
)

$ErrorActionPreference = 'Continue'
if (-not $Drive) { $Drive = $env:SystemDrive.TrimEnd(':') }
$Drive = $Drive.TrimEnd(':').ToUpper()

# ---------------------------------------------------------------- Ausgabe ----
$script:Findings = @()

function Write-Head ($t) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
}
function Write-Ok   ($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn ($t) { Write-Host "  [!]    $t" -ForegroundColor Yellow }
function Write-Bad  ($t) { Write-Host "  [X]    $t" -ForegroundColor Red }
function Write-Info ($t) { Write-Host "         $t" -ForegroundColor Gray }
function Write-Act  ($t) { Write-Host "  ->     $t" -ForegroundColor Magenta }

function Add-Finding {
    param(
        [ValidateSet('Hoch','Mittel','Niedrig')] [string] $Prio,
        [string] $Text,
        [string] $Fix
    )
    $script:Findings += [pscustomobject]@{ Prio = $Prio; Text = $Text; Fix = $Fix }
}

function Format-GB ($bytes) {
    if ($null -eq $bytes) { return "?" }
    return ("{0:N1} GB" -f ($bytes / 1GB))
}

# ------------------------------------------------------------ Rechte-Check ---
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
Write-Host "  SSD-Tune  --  Laufwerk $Drive : " -ForegroundColor White
Write-Host "  Modus: $(if ($Apply) { 'ANALYSE + FIXES' } else { 'nur Analyse (fuer Fixes: -Apply)' })" -ForegroundColor White
Write-Host "  $(Get-Date -Format 'dd.MM.yyyy HH:mm')" -ForegroundColor DarkGray

if (-not $isAdmin) {
    Write-Warn "Ohne Administratorrechte gestartet."
    Write-Info "SMART-Werte, TRIM-Aenderungen und die meisten Fixes brauchen Admin."
    Write-Info "PowerShell als Administrator neu oeffnen und Skript erneut starten."
}

# ============================================================ 1. Hardware ====
Write-Head "1. Laufwerk"

$vol = Get-Volume -DriveLetter $Drive -ErrorAction SilentlyContinue
if (-not $vol) {
    Write-Bad "Laufwerk $Drive : nicht gefunden. Abbruch."
    return
}

$part = Get-Partition -DriveLetter $Drive -ErrorAction SilentlyContinue
$disk = $null; $pdisk = $null
if ($part) {
    $disk  = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
    $pdisk = Get-PhysicalDisk -ErrorAction SilentlyContinue |
             Where-Object { $_.DeviceId -eq $part.DiskNumber } | Select-Object -First 1
}

if ($pdisk) {
    Write-Info ("Modell ........ {0}" -f $pdisk.FriendlyName)
    Write-Info ("Groesse ....... {0}" -f (Format-GB $pdisk.Size))
    Write-Info ("Anbindung ..... {0}" -f $pdisk.BusType)
    Write-Info ("Firmware ...... {0}" -f $pdisk.FirmwareVersion)
    Write-Info ("MediaType ..... {0}" -f $pdisk.MediaType)
    Write-Info ("Zustand ....... {0} / {1}" -f $pdisk.HealthStatus, ($pdisk.OperationalStatus -join ','))

    # --- Erkennt Windows die SSD ueberhaupt als SSD? ---
    if ($pdisk.MediaType -ne 'SSD') {
        Write-Bad "Windows fuehrt dieses Laufwerk NICHT als SSD (MediaType = $($pdisk.MediaType))."
        Write-Info "Folge: Windows defragmentiert statt zu trimmen. Das ist schaedlich und langsam."
        Add-Finding -Prio Hoch `
            -Text "Windows erkennt die SSD als '$($pdisk.MediaType)' statt SSD -> defragmentiert statt TRIM." `
            -Fix  "winsat diskformal   (danach neu starten und erneut pruefen)"
        if ($Apply -and $isAdmin) {
            try {
                Set-PhysicalDisk -UniqueId $pdisk.UniqueId -MediaType SSD -ErrorAction Stop
                Write-Act "MediaType auf SSD gesetzt."
            } catch {
                Write-Warn "Set-PhysicalDisk nicht moeglich ($($_.Exception.Message.Trim()))."
                Write-Act  "Stattdessen WinSAT-Neubewertung starten (dauert ein paar Minuten):"
                Write-Info "   winsat diskformal"
            }
        }
    } else {
        Write-Ok "Wird korrekt als SSD gefuehrt."
    }

    if ($pdisk.BusType -eq 'USB') {
        Write-Bad "USB-Gehaeuse erkannt."
        Write-Info "Die meisten USB-Bruecken reichen TRIM nicht durch. Die SSD verliert dadurch"
        Write-Info "ueber Monate massiv Schreibleistung - das allein erklaert dein Symptom."
        Add-Finding -Prio Hoch `
            -Text "SSD haengt an USB. TRIM wird dort meist nicht durchgereicht." `
            -Fix  "Gehaeuse mit UASP+TRIM-Support (ASMedia ASM1351/JMicron JMS583) nutzen, oder intern anschliessen."
    }
} else {
    Write-Warn "Physische Laufwerksinfos nicht lesbar (Admin noetig?)."
    $d = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($d) { Write-Info ("Fallback: {0} / {1}" -f $d.Model, $d.InterfaceType) }
}

# ========================================================= 2. Freier Platz ===
Write-Head "2. Freier Speicherplatz  (groesster Hebel)"

$freePct = [math]::Round(($vol.SizeRemaining / $vol.Size) * 100, 1)
Write-Info ("Belegt ........ {0} von {1}" -f (Format-GB ($vol.Size - $vol.SizeRemaining)), (Format-GB $vol.Size))
Write-Info ("Frei .......... {0}  ({1} %)" -f (Format-GB $vol.SizeRemaining), $freePct)

if ($freePct -lt 10) {
    Write-Bad "Unter 10 % frei. Der SLC-Cache schrumpft dadurch drastisch zusammen."
    Add-Finding -Prio Hoch `
        -Text "Nur $freePct % frei. Der dynamische SLC-Cache braucht freie Bloecke - das ist sehr wahrscheinlich DIE Hauptursache." `
        -Fix  "Auf mindestens 20-25 % frei bringen. Schnelle Kandidaten: cleanmgr /sageset:1, WinSxS via 'DISM /Online /Cleanup-Image /StartComponentCleanup', Ruhezustandsdatei via 'powercfg /h off' (spart RAM-Groesse), alte Windows.old."
} elseif ($freePct -lt 20) {
    Write-Warn "Unter 20 % frei. Cache und Garbage Collection leiden bereits spuerbar."
    Add-Finding -Prio Hoch `
        -Text "Nur $freePct % frei - zu wenig fuer stabilen SLC-Cache." `
        -Fix  "Auf 20-25 % frei bringen (cleanmgr, DISM StartComponentCleanup, powercfg /h off)."
} else {
    Write-Ok "Ausreichend frei ($freePct %)."
}

# Grosse Platzfresser benennen
$hiberfil = Join-Path "$Drive`:\" "hiberfil.sys"
if (Test-Path -LiteralPath $hiberfil) {
    $hs = (Get-Item -LiteralPath $hiberfil -Force -ErrorAction SilentlyContinue).Length
    if ($hs) { Write-Info ("hiberfil.sys .. {0}   (entfernen mit: powercfg /h off)" -f (Format-GB $hs)) }
}
$winold = Join-Path "$Drive`:\" "Windows.old"
if (Test-Path -LiteralPath $winold) {
    Write-Warn "Windows.old vorhanden - oft 15-30 GB. Entfernen via Datentraegerbereinigung."
}

# =================================================================== 3. TRIM =
Write-Head "3. TRIM"

$trimRaw = (& fsutil behavior query DisableDeleteNotify) 2>&1 | Out-String

# Windows 11 gibt je Dateisystem eine Zeile aus (NTFS / ReFS). ReFS steht dort
# oft auf 1, ohne dass das fuer ein NTFS-Volume irgendetwas bedeutet. Nur die
# zum Laufwerk passende Zeile auswerten - sonst Fehlalarm "TRIM deaktiviert".
$fsName      = if ($vol.FileSystem) { $vol.FileSystem } else { 'NTFS' }
$trimHits    = [regex]::Matches($trimRaw, '(?im)^\s*(\w+)?\s*DisableDeleteNotify\s*=\s*(\d)')
$perFsFormat = $false
$trimOff     = $null

foreach ($m in $trimHits) {
    $tag = $m.Groups[1].Value
    $val = $m.Groups[2].Value
    if (-not $tag) {
        $trimOff = ($val -ne '0')                 # altes Format ohne Dateisystem
    } else {
        $perFsFormat = $true
        if ($tag -ieq $fsName) { $trimOff = ($val -ne '0') }
    }
}

if ($trimHits.Count -gt 0) {
    Write-Info ($trimRaw.Trim())
    if ($perFsFormat) { Write-Info "(massgeblich ist die Zeile fuer $fsName - Laufwerk ${Drive}: ist $fsName)" }
} else {
    Write-Warn "TRIM-Status nicht auslesbar."
}

if ($trimOff) {
    Write-Bad "TRIM ist DEAKTIVIERT. Der Controller weiss nicht, welche Bloecke frei sind."
    Add-Finding -Prio Hoch `
        -Text "TRIM ist abgeschaltet - der Hauptgrund fuer schleichenden Leistungsverfall." `
        -Fix  "fsutil behavior set DisableDeleteNotify 0"
    if ($Apply -and $isAdmin) {
        if ($perFsFormat) { & fsutil behavior set DisableDeleteNotify $fsName 0 | Out-Null }
        else              { & fsutil behavior set DisableDeleteNotify 0 | Out-Null }
        Write-Act "TRIM aktiviert."
    }
} elseif ($trimOff -eq $false) {
    Write-Ok "TRIM ist aktiv fuer $fsName."
} else {
    Write-Warn "TRIM-Status fuer $fsName nicht eindeutig bestimmbar."
}

# Zeitplan fuer Optimierung
$task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Disabled') {
        Write-Warn "Geplante Laufwerksoptimierung ist deaktiviert - es wird nie automatisch getrimmt."
        Add-Finding -Prio Mittel `
            -Text "Der Zeitplan 'ScheduledDefrag' ist aus, TRIM laeuft nie automatisch." `
            -Fix  "Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'"
        if ($Apply -and $isAdmin) {
            Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' | Out-Null
            Write-Act "Zeitplan aktiviert."
        }
    } else {
        Write-Ok "Geplante Optimierung aktiv (Status: $($task.State))."
    }
}

if ($Apply -and $isAdmin) {
    Write-Act "Fuehre ReTrim aus (kann bei grossen Laufwerken einige Minuten dauern)..."
    try {
        Optimize-Volume -DriveLetter $Drive -ReTrim -ErrorAction Stop
        Write-Act "ReTrim abgeschlossen."
    } catch {
        Write-Warn "ReTrim fehlgeschlagen: $($_.Exception.Message.Trim())"
    }
} else {
    Write-Info "Manuelles ReTrim jetzt:  Optimize-Volume -DriveLetter $Drive -ReTrim -Verbose"
}

# ======================================================== 4. SMART/Zustand ===
Write-Head "4. Gesundheit, Verschleiss, Temperatur"

if ($isAdmin -and $pdisk) {
    $rc = $pdisk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    if ($rc) {
        if ($null -ne $rc.Temperature -and $rc.Temperature -gt 0) {
            Write-Info ("Temperatur .... {0} C  (Max bisher: {1} C)" -f $rc.Temperature, $rc.TemperatureMax)
            if ($rc.Temperature -ge 70) {
                Write-Bad "Ueber 70 C - NVMe-SSDs drosseln hier hart."
                Add-Finding -Prio Hoch `
                    -Text "Laufwerkstemperatur $($rc.Temperature) C - thermisches Throttling sehr wahrscheinlich." `
                    -Fix  "M.2-Kuehlkoerper montieren, Gehaeusebelueftung pruefen."
            } elseif ($rc.Temperature -ge 60) {
                Write-Warn "Ueber 60 C - grenzwertig, unter Dauerlast wird gedrosselt."
                Add-Finding -Prio Mittel -Text "Temperatur $($rc.Temperature) C unter Last grenzwertig." -Fix "Kuehlkoerper / Airflow verbessern."
            } else {
                Write-Ok "Temperatur unauffaellig."
            }
        }
        if ($null -ne $rc.Wear) {
            Write-Info ("Verschleiss ... {0} %" -f $rc.Wear)
            if ($rc.Wear -ge 80) {
                Write-Bad "Ueber 80 % der Schreib-Lebensdauer verbraucht."
                Add-Finding -Prio Hoch `
                    -Text "Verschleiss bei $($rc.Wear) % - die Reservebloecke gehen zur Neige, der Controller muss staendig umschichten." `
                    -Fix  "Daten sichern, Austausch einplanen. Tuning hilft hier nur noch begrenzt."
            } elseif ($rc.Wear -ge 50) {
                Write-Warn "Ueber 50 % Verschleiss."
            } else {
                Write-Ok "Verschleiss im gruenen Bereich."
            }
        }
        if ($rc.PowerOnHours) { Write-Info ("Betriebsstunden {0} h  (~{1} Jahre Dauerbetrieb)" -f $rc.PowerOnHours, [math]::Round($rc.PowerOnHours/8760,1)) }
        $errSum = 0
        foreach ($p in 'ReadErrorsUncorrected','WriteErrorsUncorrected') {
            if ($null -ne $rc.$p) { $errSum += $rc.$p }
        }
        if ($errSum -gt 0) {
            Write-Bad "Unkorrigierbare Lese-/Schreibfehler: $errSum"
            Add-Finding -Prio Hoch -Text "Unkorrigierbare I/O-Fehler ($errSum). Das Laufwerk ist am Ausfallen." -Fix "Sofort sichern und ersetzen."
        }
    } else {
        Write-Info "Zuverlaessigkeitszaehler liefert keine Daten (bei manchen SATA-Controllern normal)."
    }

    try {
        $fp = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop
        foreach ($f in $fp) {
            if ($f.PredictFailure) {
                Write-Bad "SMART meldet bevorstehenden Ausfall!"
                Add-Finding -Prio Hoch -Text "SMART-Ausfallvorhersage aktiv." -Fix "Sofort Backup, Laufwerk ersetzen."
            }
        }
        if (-not ($fp | Where-Object PredictFailure)) { Write-Ok "SMART meldet keinen bevorstehenden Ausfall." }
    } catch {
        Write-Info "SMART-Vorhersage nicht abrufbar (bei NVMe haeufig)."
    }
} else {
    Write-Warn "Uebersprungen - Administratorrechte noetig."
}

Write-Info ""
Write-Info "Fuer echte SMART-Rohwerte (empfohlen): smartmontools installieren, dann"
Write-Info "   smartctl -a /dev/sda        bzw.   smartctl -a /dev/nvme0"
Write-Info "   winget install smartmontools.smartmontools"

# ================================================== 5. Firmware / Herstellertool
Write-Head "5. Firmware"

if ($pdisk) {
    Write-Info ("Aktuelle Firmware: {0}" -f $pdisk.FirmwareVersion)
    $name = "$($pdisk.FriendlyName)"
    $tool = switch -Regex ($name) {
        'Samsung'          { 'Samsung Magician' ; break }
        'Crucial|Micron'   { 'Crucial Storage Executive' ; break }
        'WDC|WD_BLACK|SanDisk' { 'WD Dashboard' ; break }
        'Kingston'         { 'Kingston SSD Manager' ; break }
        'Intel|Solidigm'   { 'Solidigm Storage Tool' ; break }
        'Seagate'          { 'SeaTools / Seagate Toolkit' ; break }
        'Corsair'          { 'Corsair SSD Toolbox' ; break }
        'ADATA'            { 'ADATA SSD Toolbox' ; break }
        default            { 'Hersteller-Tool (siehe Support-Seite des Herstellers)' }
    }
    Write-Act "Firmware-Update pruefen mit: $tool"
    Add-Finding -Prio Mittel `
        -Text "Firmware $($pdisk.FirmwareVersion) - es gab reihenweise Firmware-Bugs mit genau diesem Symptombild." `
        -Fix  "$tool installieren und Firmware-Update pruefen. Vorher Backup."
}

# ============================================ 6. Energie / Link Power Mgmt ===
Write-Head "6. Energieeinstellungen"

$dt = (& powercfg /query SCHEME_CURRENT SUB_DISK 6738e2c4-e8a5-4a42-b16a-e040e769756e) 2>&1 | Out-String
if ($dt -match '(?im)^\s*(?:Current AC Power Setting Index|Aktueller Wechselstrom\w*)\s*:\s*0x([0-9a-f]+)') {
    $secs = [Convert]::ToInt32($matches[1], 16)
    if ($secs -gt 0) {
        Write-Warn "Festplatte wird nach $secs s abgeschaltet - verursacht Haenger beim Aufwachen."
        Add-Finding -Prio Mittel -Text "Disk-Timeout aktiv ($secs s)." -Fix "powercfg /change disk-timeout-ac 0"
    } else {
        Write-Ok "Disk-Timeout ist aus."
    }
}
if ($Apply -and $isAdmin) {
    & powercfg /change disk-timeout-ac 0 2>&1 | Out-Null
    & powercfg /change disk-timeout-dc 0 2>&1 | Out-Null
    Write-Act "Disk-Timeout auf 'nie' gesetzt."
}

if ($pdisk -and $pdisk.BusType -eq 'SATA') {
    $SUB_DISK = '0012ee47-9041-4b5d-9b77-535fba8b1442'
    $LPM      = '0b2d69d7-a2a1-449c-9680-f91c70521c60'
    Write-Info "SATA erkannt. AHCI Link Power Management (HIPM/DIPM) verursacht auf vielen"
    Write-Info "Systemen kurze Aussetzer unter Last."
    Add-Finding -Prio Mittel `
        -Text "SATA Link Power Management kann Mikro-Haenger verursachen." `
        -Fix  "powercfg -attributes $SUB_DISK $LPM -ATTRIB_HIDE ; powercfg /setacvalueindex SCHEME_CURRENT $SUB_DISK $LPM 0 ; powercfg /setactive SCHEME_CURRENT   (auf Notebooks kostet das etwas Akkulaufzeit)"
    if ($Apply -and $isAdmin) {
        & powercfg -attributes $SUB_DISK $LPM -ATTRIB_HIDE 2>&1 | Out-Null
        & powercfg /setacvalueindex SCHEME_CURRENT $SUB_DISK $LPM 0 2>&1 | Out-Null
        & powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
        Write-Act "SATA Link Power Management auf 'Aktiv' (aus) gesetzt."
    }
}

# ================================================ 7. Dienste / Auslagerung ===
Write-Head "7. Mitverursacher: Dienste und Auslagerungsdatei"

foreach ($svcName in 'SysMain','WSearch') {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) { continue }
    $label = if ($svcName -eq 'SysMain') { 'SysMain (Superfetch)' } else { 'Windows Search (Indizierung)' }
    if ($svc.Status -eq 'Running') {
        Write-Warn "$label laeuft - haeufige Ursache fuer dauerhafte 100 % Datentraegerlast."
        Add-Finding -Prio Mittel `
            -Text "$label laeuft und erzeugt Hintergrund-I/O, das die langsame SSD zusaetzlich saettigt." `
            -Fix  "Testweise abschalten: Stop-Service $svcName -Force ; Set-Service $svcName -StartupType Disabled   (Skript-Schalter: -Disable$(if($svcName -eq 'SysMain'){'SysMain'}else{'SearchIndex'}))"
    } else {
        Write-Ok "$label laeuft nicht."
    }
}

if ($DisableSysMain -and $isAdmin) {
    Stop-Service SysMain -Force -ErrorAction SilentlyContinue
    Set-Service  SysMain -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Act "SysMain gestoppt und deaktiviert."
}
if ($DisableSearchIndex -and $isAdmin) {
    Stop-Service WSearch -Force -ErrorAction SilentlyContinue
    Set-Service  WSearch -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Act "Windows Search gestoppt und deaktiviert."
}

$ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
Write-Info ("Arbeitsspeicher: {0}" -f (Format-GB $ram))
$pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
if ($pf) {
    foreach ($p in $pf) {
        Write-Info ("Auslagerungsdatei: {0}  belegt {1} von {2} MB" -f $p.Name, $p.CurrentUsage, $p.AllocatedBaseSize)
        if ($p.CurrentUsage -gt ($p.AllocatedBaseSize * 0.5)) {
            Write-Warn "Auslagerungsdatei stark genutzt - bei grossen Kopiervorgaengen entsteht daraus ein Teufelskreis."
            Add-Finding -Prio Hoch `
                -Text "Die Auslagerungsdatei auf der langsamen SSD wird stark genutzt. Beim Schreiben grosser Datenmengen faengt Windows an zu swappen - genau da friert das System ein." `
                -Fix  "RAM aufruesten, oder Auslagerungsdatei auf ein anderes (schnelleres) Laufwerk legen."
        }
    }
}
if ($ram -lt 8GB) {
    Add-Finding -Prio Hoch `
        -Text ("Nur {0} RAM. Windows puffert Schreibvorgaenge im RAM; ist der Puffer voll, blockiert alles bis die SSD hinterherkommt." -f (Format-GB $ram)) `
        -Fix  "RAM-Aufruestung bringt hier mehr als jede SSD-Einstellung."
}

# ============================================== 8. Over-Provisioning-Check ===
Write-Head "8. Over-Provisioning"

if ($part -and $disk) {
    $unalloc = $disk.LargestFreeExtent
    $opPct = if ($disk.Size -gt 0) { [math]::Round(($unalloc / $disk.Size) * 100, 1) } else { 0 }
    Write-Info ("Nicht zugewiesen auf dem Datentraeger: {0}  ({1} %)" -f (Format-GB $unalloc), $opPct)

    if ($opPct -lt 5) {
        Write-Warn "Praktisch kein Over-Provisioning vorhanden."
        $sup = Get-PartitionSupportedSize -DriveLetter $Drive -ErrorAction SilentlyContinue
        $targetShrink = [int64]($disk.Size * 0.10)
        $newSize = $part.Size - $targetShrink
        $canDo = ($sup -and $newSize -gt $sup.SizeMin)
        Write-Info "10 % der SSD unpartitioniert zu lassen gibt dem Controller dauerhaft Reserve-"
        Write-Info "bloecke: groesserer SLC-Cache, weniger Write Amplification. Bei alten Laufwerken"
        Write-Info "oft die wirksamste Einzelmassnahme nach 'Platz schaffen'."
        if ($canDo) {
            Add-Finding -Prio Mittel `
                -Text "Kein Over-Provisioning. 10 % unpartitioniert lassen vergroessert den SLC-Cache spuerbar." `
                -Fix  ("Partition verkleinern (vorher Backup!):  Resize-Partition -DriveLetter $Drive -Size {0}" -f $newSize)
            Write-Act ("Befehl waere:  Resize-Partition -DriveLetter $Drive -Size {0}   ({1} freimachen)" -f $newSize, (Format-GB $targetShrink))
            Write-Info "Wird vom Skript bewusst NICHT automatisch ausgefuehrt."
        } else {
            Write-Info "Zu wenig freier Platz zum Verkleinern - erst aufraeumen (Punkt 2)."
        }
    } else {
        Write-Ok "Over-Provisioning vorhanden ($opPct %)."
    }
}

# ================================================= 9. Schreibkurven-Test =====
Write-Head "9. Schreibtest  (deckt den SLC-Cache-Einbruch auf)"

if ($BenchGB -le 0) {
    Write-Info "Uebersprungen (-BenchGB 0)."
} else {
    $needed = [int64]$BenchGB * 1GB
    $reserve = [int64]($vol.Size * 0.10)
    if ($vol.SizeRemaining -lt ($needed + $reserve)) {
        Write-Warn ("Uebersprungen: zu wenig freier Platz ({0} frei, benoetigt {1} + 10 % Reserve)." -f (Format-GB $vol.SizeRemaining), (Format-GB $needed))
    } else {
        $testFile = Join-Path "$Drive`:\" ("ssdtune_bench_{0}.tmp" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        $chunkMB  = 256
        $bufMB    = 8
        $chunks   = [int](($BenchGB * 1024) / $chunkMB)
        $writesPerChunk = [int]($chunkMB / $bufMB)

        Write-Info ("Schreibe {0} GB in {1}-MB-Schritten nach {2}" -f $BenchGB, $chunkMB, $testFile)
        Write-Info "WriteThrough aktiv - der RAM-Cache kann die echten Geraetewerte nicht verschleiern."
        Write-Info "Abbruch jederzeit mit Strg+C (Testdatei dann ggf. manuell loeschen)."
        Write-Host ""

        $buf = New-Object byte[] ($bufMB * 1MB)
        (New-Object Random 12345).NextBytes($buf)   # zufaellig: umgeht Controller-Komprimierung
        $rates = New-Object System.Collections.Generic.List[double]
        $fs = $null

        try {
            $fs = New-Object System.IO.FileStream(
                    $testFile,
                    [System.IO.FileMode]::Create,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None,
                    1MB,
                    [System.IO.FileOptions]::WriteThrough)

            for ($c = 1; $c -le $chunks; $c++) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                for ($w = 0; $w -lt $writesPerChunk; $w++) {
                    $buf[0] = [byte](($c * 7 + $w) % 256)   # Dedupe der Controller umgehen
                    $buf[1] = [byte](($c * 31 + $w * 17) % 256)
                    $fs.Write($buf, 0, $buf.Length)
                }
                $fs.Flush($true)
                $sw.Stop()

                $mbs = $chunkMB / $sw.Elapsed.TotalSeconds
                $rates.Add($mbs)

                $written = $c * $chunkMB / 1024.0
                $bar = "#" * [math]::Min(40, [int]($mbs / 25))
                Write-Host ("  {0,6:N2} GB  {1,8:N0} MB/s  {2}" -f $written, $mbs, $bar) -ForegroundColor $(
                    if ($mbs -ge 300) { 'Green' } elseif ($mbs -ge 120) { 'Yellow' } else { 'Red' })
            }
        } catch {
            Write-Bad "Schreibtest abgebrochen: $($_.Exception.Message.Trim())"
        } finally {
            if ($fs) { $fs.Dispose() }
            if (Test-Path -LiteralPath $testFile) {
                Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
                Write-Info ""
                Write-Info "Testdatei geloescht."
            }
        }

        if ($rates.Count -ge 4) {
            $peak = ($rates | Measure-Object -Maximum).Maximum
            $tailCount = [math]::Max(2, [int]($rates.Count * 0.25))
            $tail = $rates[($rates.Count - $tailCount)..($rates.Count - 1)]
            $sustained = ($tail | Measure-Object -Average).Average

            # Einbruchspunkt: erster Chunk dauerhaft unter 60 % des Peaks
            $cliffGB = $null
            for ($i = 1; $i -lt $rates.Count; $i++) {
                if ($rates[$i] -lt ($peak * 0.6)) { $cliffGB = ($i * $chunkMB) / 1024.0; break }
            }

            Write-Host ""
            Write-Info ("Spitze ........... {0:N0} MB/s" -f $peak)
            Write-Info ("Dauerhaft (Ende) . {0:N0} MB/s" -f $sustained)
            if ($cliffGB) {
                Write-Info ("SLC-Cache ........ ca. {0:N1} GB, danach Einbruch" -f $cliffGB)
            } else {
                Write-Info  "SLC-Cache ........ kein Einbruch innerhalb des Tests"
            }

            if ($sustained -lt 60) {
                Write-Bad ("Dauerschreibrate nur {0:N0} MB/s - das ist die Ursache der Haenger." -f $sustained)
                Add-Finding -Prio Hoch `
                    -Text ("Nach ca. {0} GB faellt die Schreibrate auf {1:N0} MB/s. Windows nimmt Daten weiter schnell in den RAM an; ist der Puffer voll, blockiert das System, bis die SSD hinterherkommt." -f $(if($cliffGB){"{0:N1}" -f $cliffGB}else{"?"}), $sustained) `
                    -Fix  "Erst Punkte 2, 3 und 8 abarbeiten (Platz, TRIM, Over-Provisioning) und erneut messen. Bleibt es dabei: Secure Erase (Punkt 10) oder Austausch. Grosse Kopien in Etappen unter der Cachegroesse."
            } elseif ($sustained -lt 150) {
                Write-Warn ("Dauerschreibrate {0:N0} MB/s - typisch fuer QLC oder DRAM-lose Laufwerke." -f $sustained)
                Add-Finding -Prio Mittel `
                    -Text ("Dauerschreibrate {0:N0} MB/s nach Cache-Einbruch." -f $sustained) `
                    -Fix  "Over-Provisioning (Punkt 8) und freier Platz (Punkt 2) heben diesen Wert am ehesten an."
            } else {
                Write-Ok ("Dauerschreibrate {0:N0} MB/s - unauffaellig." -f $sustained)
            }
        }
    }
}

# ================================================== 10. Manuelle Massnahmen ==
Write-Head "10. Was nur du manuell machen kannst"

Write-Info "a) Schreibcache pruefen:"
Write-Info "   Geraete-Manager -> Laufwerke -> SSD -> Richtlinien"
Write-Info "   'Schreibcache auf dem Geraet aktivieren' MUSS an sein."
Write-Info "   'Windows-Schreibcachepuffer-Leerung deaktivieren' NICHT anhaken"
Write-Info "   (bringt Tempo, riskiert aber Datenverlust bei Stromausfall)."
Write-Info ""
Write-Info "b) SATA-Modus im BIOS: muss AHCI sein, nicht IDE/RAID."
Write-Info ""
Write-Info "c) Secure Erase - die wirksamste reine Software-Massnahme bei alten SSDs."
Write-Info "   Setzt die interne Zuordnungstabelle zurueck, stellt das urspruengliche"
Write-Info "   Schreibverhalten meist wieder her. Braucht Backup + Neuinstallation."
Write-Info "   Weg: Hersteller-Tool oder Parted Magic / bootfaehiger USB-Stick."

# ===================================================== Zusammenfassung =======
Write-Head "ZUSAMMENFASSUNG"

if ($script:Findings.Count -eq 0) {
    Write-Ok "Keine Auffaelligkeiten gefunden."
} else {
    $order = @{ 'Hoch' = 0; 'Mittel' = 1; 'Niedrig' = 2 }
    $i = 0
    foreach ($f in ($script:Findings | Sort-Object { $order[$_.Prio] })) {
        $i++
        $col = switch ($f.Prio) { 'Hoch' { 'Red' } 'Mittel' { 'Yellow' } default { 'Gray' } }
        Write-Host ""
        Write-Host ("  {0}. [{1}] {2}" -f $i, $f.Prio.ToUpper(), $f.Text) -ForegroundColor $col
        Write-Host ("      Fix: {0}" -f $f.Fix) -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host ("  " + ("-" * 70)) -ForegroundColor DarkGray
if (-not $Apply) {
    Write-Host "  Das war nur die Analyse. Sichere Fixes anwenden mit:" -ForegroundColor White
    Write-Host "      .\SSD-Tune.ps1 -Apply" -ForegroundColor Cyan
}
Write-Host "  Reihenfolge der Wirksamkeit: freier Platz > TRIM > Over-Provisioning >" -ForegroundColor White
Write-Host "  Firmware > Secure Erase. Aus einer alten QLC-SSD wird trotzdem keine" -ForegroundColor White
Write-Host "  schnelle - aber die Haenger bekommst du weg." -ForegroundColor White
Write-Host ""
