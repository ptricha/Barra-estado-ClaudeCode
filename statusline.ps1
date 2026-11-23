[Console]::OutputEncoding = [Text.Encoding]::UTF8
$j = [Console]::In.ReadToEnd() | ConvertFrom-Json
$E = [char]27
function C($n, $s) { "$E[38;5;${n}m$s$E[0m" }
function Dim($s) { "$E[2m$s$E[0m" }
function Bold($s) { "$E[1m$s$E[0m" }
function Clip($s, $n) { $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + [string][char]0x2026 } else { $s } }

$sep = Dim "   $([char]0x00B7)   "
$now = Get-Date
$tick = [int]$now.TimeOfDay.TotalSeconds

# ---- identidad de sesion (color + id corto estables) ----
$sid = [string]$j.session_id
if (-not $sid) { $sid = "0000" }
$h = 0; foreach ($ch in $sid.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 100003 }
$palette = 39, 208, 141, 78, 205, 220, 45, 171, 118, 203, 81, 214
$col = $palette[$h % $palette.Count]
$short = $sid.Substring(0, [math]::Min(4, $sid.Length))

# ---- contexto ----
$size = 200000
if ($j.context_window -and $j.context_window.context_window_size) { $size = [double]$j.context_window.context_window_size }
$used = $null; $agents = 0; $curTool = $null; $quiet = 0; $state = 'idle'; $since = $null; $first = $null; $last = $null
$tp = $j.transcript_path
if ($tp -and (Test-Path $tp)) {
    $fs = [IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    $len = $fs.Length; $take = [math]::Min($len, 400KB)
    $null = $fs.Seek($len - $take, 'Begin')
    $buf = New-Object byte[] $take
    $null = $fs.Read($buf, 0, $take); $fs.Close()
    $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
    if ($take -lt $len) { $lines = $lines[1..($lines.Count - 1)] }
    $lines = @($lines | Where-Object { $_.Trim() })
    $manual = $false; $gotState = $false; $cands = @(); $ctxMsg = $null; $doneIds = @{}; $agents = 0
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($o.isSidechain) { continue }
        if ($o.message.content -isnot [string]) {
            foreach ($b in @($o.message.content)) {
                if ($b.type -eq 'tool_result' -and $b.tool_use_id) { $doneIds[[string]$b.tool_use_id] = 1 }
                elseif ($b.type -eq 'tool_use' -and -not $doneIds.ContainsKey([string]$b.id)) {
                    if ($b.name -eq 'Agent' -or $b.name -eq 'Task') { $agents++ }
                    if ($null -eq $curTool) { $curTool = $b }
                }
            }
        }
        $u = $o.message.usage
        if ($null -eq $used -and $u) {
            $used = [double]$u.input_tokens + [double]$u.cache_read_input_tokens + [double]$u.cache_creation_input_tokens
        }
        if (-not $gotState -and ($o.type -eq 'user' -or $o.type -eq 'assistant')) {
            $gotState = $true
            if ($o.type -eq 'assistant' -and $o.message.stop_reason -eq 'end_turn') { $state = 'idle' } else { $state = 'work' }
        }
        if ($null -eq $first) {
            if ($o.type -eq 'custom-title' -and $o.customTitle) { $first = [string]$o.customTitle }
            elseif ($o.type -eq 'ai-title' -and $o.aiTitle) { $first = [string]$o.aiTitle }
        }
        if ($cands.Count -lt 8 -and $o.type -eq 'user' -and -not $o.isMeta) {
            $c = $o.message.content
            if ($c -is [string]) { $t = $c } else { $t = ($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
            if ($t -and $t -notmatch '^\s*<(system-reminder|command-|local-command|pasted)') {
                if ($null -eq $last) {
                    $last = $t
                    try { $since = ($now.ToUniversalTime() - ([datetime]$o.timestamp).ToUniversalTime()).TotalSeconds } catch {}
                }
                $cands += ($t -replace '\s+', ' ').Trim()
            }
        }
        if ($null -ne $used -and $gotState -and $cands.Count -ge 8 -and $null -ne $first) { break }
    }
    # tema manual (prioridad): ~/.claude/state/topic-<session_id>.txt
    try { $tf = Join-Path $env:USERPROFILE ".claude\state\topic-$sid.txt"; if (Test-Path $tf) { $tt = (Get-Content $tf -TotalCount 1 -Encoding UTF8).Trim(); if ($tt) { $first = $tt; $manual = $true } } } catch {}
    # tema: titulo de sesion generado por Claude (ultimo ai-title); si no esta en la cola, mirar el principio
    if ($null -eq $first) {
        $sr = New-Object IO.StreamReader($tp, [Text.Encoding]::UTF8)
        $n = 0; while ($n -lt 150 -and -not $sr.EndOfStream) { $n++; $l = $sr.ReadLine()
            if ($l -match '"type":"(ai|custom)-title"') { try { $o = $l | ConvertFrom-Json; if ($o.customTitle) { $first = [string]$o.customTitle } elseif ($o.aiTitle) { $first = [string]$o.aiTitle } } catch {} } }
        $sr.Close()
    }
    # tema dinamico: palabras clave de los ultimos mensajes (los recientes pesan mas), se recalcula tras cada mensaje
    if (-not $manual -and $cands.Count) {
        $stop = '^(perf\w*|ahor\w*|cuand\w*|pero|como|para|porque|quier\w*|pued\w*|haz|hac\w+|dame|dime|esto|esta\w*|este|esos|esas|ese|esa|eso|algo|otro|otra|mas|menos|muy|solo|tambi\w+|donde|cual\w*|todo\w*|cada|tien\w+|tengo|sobre|desde|hasta|entre|segun|aqui|asi|bien|vale|que|con|por|del|las|los|una|uno|unos|unas|sea|ser|pon\w*|pone|debe\w*|despu\w+|tras|lado|abajo|arriba|mensaje\w*|ultimo|primer\w*|siempre|nunca|nada|poco|mucho\w*|hay|han|era|son|fue|dejar|deja\w*|quita\w*|cambia\w*|anad\w*|crea\w*|genera\w*|usa\w*|mira\w*|revisa\w*|puedes|favor|gracias|tema|actualice\w*|actualiz\w*|centre\w*|ademas|barra|estado\w*)$'
        $score = @{}; $form = @{}; $wgt = $cands.Count
        foreach ($m in $cands) {
            foreach ($mm in [regex]::Matches($m.ToLower(), '[\p{L}\p{N}_\-]{4,}')) {
                $w = $mm.Value
                $pl = $w.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
                if ($pl -match $stop) { continue }
                $st = $pl.Substring(0, [math]::Min(5, $pl.Length))
                if (-not $score.ContainsKey($st)) { $score[$st] = 0; $form[$st] = $w }
                $score[$st] += $wgt
            }
            $wgt--
        }
        $top = @($score.GetEnumerator() | Sort-Object -Property @{e={$_.Value};Descending=$true} | Select-Object -First 4 | ForEach-Object { $form[$_.Key] })
        if ($top.Count -ge 2) { $first = ($top -join ' ' + [char]0x00B7 + ' ') }
    }
    # contexto: ultimo mensaje que quepa ENTERO (o su primera frase completa), sin puntos suspensivos
    $maxCtx = 100
    foreach ($m in $cands) {
        if ($m.Length -le $maxCtx) { $ctxMsg = $m; break }
        $sents = @($m -split '(?<=[\.\?\!:])\s+' | Where-Object { $_.Length -ge 12 -and $_.Length -le $maxCtx })
        if ($sents.Count) { $ctxMsg = $sents[$sents.Count - 1]; break }
    }
    # resumen telegrafico: solo si se muestra el ultimo mensaje entero (palabras de contenido, max 7)
    $resumen = $null
    if ($cands.Count) {
        $fill = '^(perf\w*|ahor\w*|cuand\w*|pero|como|para|porque|quier\w*|pued\w*|haz|hac\w+|haga\w*|dame|dime|esto|esta|este|esos|esas|ese|esa|eso|algo|otro|otra|lado|mas|menos|muy|solo|tambi\w+|donde|cual\w*|todo\w*|cada|tien\w+|tengo|sobre|desde|hasta|entre|segun|aqui|alli|asi|bien|vale|ok|que|con|por|del|las|los|una|uno|unos|unas|sea|sean|ser|esta\w*|va|vaya\w*)$'
        $seenP = @{}; $keep = @()
        foreach ($mm in [regex]::Matches($cands[0].ToLower(), '[\p{L}\p{N}_\-]{3,}')) {
            $w = $mm.Value
            $pl = $w.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
            $stem = $pl.Substring(0, [math]::Min(5, $pl.Length))
            if ($pl -match $fill -or $seenP.ContainsKey($stem)) { continue }
            $seenP[$stem] = 1; $keep += $w
            if ($keep.Count -ge 6) { break }
        }
        if ($keep.Count -ge 2) { $resumen = $keep -join ' ' }
    }
    # transcript sin actividad reciente => no esta trabajando
    $quiet = ($now - [IO.File]::GetLastWriteTime($tp)).TotalSeconds
    if ($state -eq 'work' -and $quiet -gt 180) { $state = 'idle' }
}

# ---- herramienta en curso ----
$toolTxt = ''
if ($state -eq 'work' -and $curTool) {
    $nm = [string]$curTool.name; $ti = $curTool.input
    $verbs = @{ Edit = 'Editando'; Write = 'Escribiendo'; Read = 'Leyendo'; Bash = 'Ejecutando'; PowerShell = 'Ejecutando'; Grep = 'Buscando'; Glob = 'Buscando'; Agent = 'Agente'; Task = 'Agente'; WebSearch = 'Buscando en web'; WebFetch = 'Leyendo web'; NotebookEdit = 'Editando'; Skill = 'Skill' }
    $verb = $verbs[$nm]; if (-not $verb) { $verb = $nm }
    $tg = ''
    if ($ti.file_path) { $tg = Split-Path -Leaf ([string]$ti.file_path) }
    elseif ($ti.command) { $tg = [string]$ti.command }
    elseif ($ti.pattern) { $tg = [string]$ti.pattern }
    elseif ($ti.query) { $tg = [string]$ti.query }
    elseif ($ti.description) { $tg = [string]$ti.description }
    elseif ($ti.url) { $tg = [string]$ti.url }
    elseif ($ti.skill) { $tg = [string]$ti.skill }
    $toolTxt = Clip "$verb $tg" 60
}

# ---- estado animado ----
$spin = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
if ($state -eq 'work') {
    $frame = [string][char]$spin[$tick % $spin.Count]
    $el = ''
    if ($null -ne $since -and $since -ge 0) { $el = ' ' + [int]$since + 's' }
    $badge = (C 214 ("$frame Trabajando$el").PadRight(18))
} else {
    if ($tick % 2 -eq 0) { $dot = [string][char]0x25CF } else { $dot = [string][char]0x25CB }
    $badge = (C 78 ("$dot Libre").PadRight(18))
}

# ---- barra de contexto ----
$bar = ''; $ctx = Dim 'ctx --'
if ($null -ne $used) {
    $pct = [math]::Min(100, [math]::Round(100 * $used / $size))
    $k = [math]::Round($used / 1000)
    $w = 12; $f = [math]::Round($pct / 100 * $w)
    if ($pct -lt 50) { $cc = 78 } elseif ($pct -lt 75) { $cc = 220 } elseif ($pct -lt 90) { $cc = 208 } else { $cc = 196 }
    $full = [string][char]0x25B0; $emp = [string][char]0x25B1
    $bar = (C $cc ($full * $f)) + (Dim ($emp * ($w - $f)))
    $warn = ''
    if ($pct -ge 85) { if ($tick % 2 -eq 0) { $warn = ' ' + (C 196 '! /compact') } }
    $ctx = "$bar " + (C $cc ("{0,3}%" -f [int]$pct)) + (Dim (" {0,4}k" -f [int]$k)) + $warn
}

# ---- coste / tiempo / lineas ----
$extra = @()
if ($j.cost) {
    if ($null -ne $j.cost.total_duration_ms) {
        $m = [int]([double]$j.cost.total_duration_ms / 60000)
        if ($m -ge 60) { $tm = '{0}h{1:00}m' -f [int][math]::Floor($m / 60), ($m % 60) } else { $tm = "${m}m" }
        $extra += (Dim 'Sesion ') + (C 252 $tm)
    }
}
# limites de uso: siempre visibles; >=80% amarillo, >90% rojo; hora real de reinicio
$dias = 'dom', 'lun', 'mar', 'mie', 'jue', 'vie', 'sab'
foreach ($lim in @(@('five_hour', 'Diario 5h'), @('seven_day', 'Semanal'))) {
    $r = $j.rate_limits.($lim[0])
    $lab = ([string]$lim[1]).PadRight(9)
    if ($r -and $null -ne $r.used_percentage) {
        $p = [int][math]::Round([double]$r.used_percentage)
        if ($p -gt 90) { $lc = 196 } elseif ($p -ge 80) { $lc = 220 } else { $lc = 78 }
        $mark = '  '; if ($p -gt 90 -and $tick % 2 -eq 0) { $mark = '! ' }
        $rs = ''
        if ($r.resets_at) {
            try {
                $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.resets_at).LocalDateTime
                if ($dt.Date -eq $now.Date) { $rs = $dt.ToString('HH:mm') } else { $rs = $dias[[int]$dt.DayOfWeek] + ' ' + $dt.ToString('HH:mm') }
            } catch {}
        }
        if ($rs) { $rtxt = ('  Reinicio ' + $rs).PadRight(19) } else { $rtxt = ''.PadRight(19) }
        $extra += (C $lc ($mark + $lab + ('{0,3}%' -f $p))) + (Dim $rtxt)
    } else { $extra += (Dim ('  ' + $lab + '  --').PadRight(33)) }
}

# ---- carpeta + rama git (sin lanzar procesos) ----
$cwd = [string]$j.workspace.current_dir
$dir = Split-Path -Leaf $cwd
$branch = ''
try {
    $d = $cwd
    while ($d -and -not (Test-Path (Join-Path $d '.git'))) { $p = Split-Path -Parent $d; if ($p -eq $d) { $d = $null; break }; $d = $p }
    if ($d) {
        $hd = Join-Path $d '.git\HEAD'
        if (Test-Path $hd) { $r = (Get-Content $hd -TotalCount 1); if ($r -match 'ref: refs/heads/(.+)$') { $branch = $Matches[1] } else { $branch = $r.Substring(0, 7) } }
    }
} catch {}

# ---- composicion final: marco redondeado ----
$hz = [string][char]0x2500
$gl = Dim ' '
$rows = @()

$r1 = (C $col ([string][char]0x25C6)) + ' ' + (Bold (C $col $dir))
if ($branch) { $r1 += '  ' + (Dim ([string][char]0xE0A0)) + ' ' + (C 141 $branch) }
$r1 += $sep + (Bold (C 252 $j.model.display_name))
$full2 = $cwd; if ($env:USERPROFILE -and $full2.StartsWith($env:USERPROFILE, 'OrdinalIgnoreCase')) { $full2 = '~' + $full2.Substring($env:USERPROFILE.Length) }
$full2 = $full2 -replace '/', '\'
if ($full2.Length -gt 38) {
    $parts = @($full2 -split '\\' | Where-Object { $_ })
    $tail = [string]$parts[$parts.Count - 1]
    if ($parts.Count -ge 3) {
        $cand = $parts[0] + '\' + [string][char]0x2026 + '\' + $parts[$parts.Count - 2] + '\' + $tail
        if ($cand.Length -gt 38) { $cand = $parts[0] + '\' + [string][char]0x2026 + '\' + $tail }
        $full2 = $cand
    }
    if ($full2.Length -gt 38) { $full2 = Clip $full2 38 }
}
$r1 += $sep + (C 111 $full2)
$rows += $r1

$agTxt = ("$([char]0x25C8) $agents " + $(if ($agents -eq 1) { 'Agente' } else { 'Agentes' })).PadRight(13)
if ($agents -gt 0) { $ag = C 214 $agTxt } else { $ag = Dim $agTxt }
$r2 = $badge + $sep + $ag + $sep + $ctx
if ($extra.Count) { $r2 += $sep + ($extra -join $sep) }
$rows += $r2

$msg = $resumen; if (-not $msg) { $msg = $ctxMsg }
function Cap($t) { if ($t) { $t.Substring(0,1).ToUpper() + $t.Substring(1) } else { $t } }
$msg = Cap $msg; $first = Cap $first
$accion = 'Acci' + [string][char]0x00F3 + 'n   '
if ($toolTxt) {
    $qt = ''
    if ($quiet -gt 45) { if ($quiet -ge 60) { $qt = '   ' + (C 220 ("sin actividad $([int][math]::Floor($quiet / 60))m")) } else { $qt = '   ' + (C 220 ("sin actividad $([int]$quiet)s")) } }
    $rows += (C $col ([string][char]0x25B8)) + ' ' + (Dim $accion) + (C 214 $toolTxt) + $qt
} else {
    $rows += (C $col ([string][char]0x25B8)) + ' ' + (Dim $accion) + (Dim 'En espera')
}
if ($first) { $rows += (C $col ([string][char]0x2726)) + ' ' + (Dim 'Tema     ') + (Bold (C 252 $first)) }
if ($msg) { $rows += (C $col ([string][char]0x270E)) + ' ' + (Dim 'Mensaje  ') + (C 250 $msg) }

for ($i = 0; $i -lt $rows.Count; $i++) {
    if ($i -eq 0) { $g = [char]0x256D } elseif ($i -eq $rows.Count - 1) { $g = [char]0x2570 } else { $g = [char]0x251C }
    (C $col "$g$hz") + ' ' + $rows[$i]
}
