[Console]::OutputEncoding = [Text.Encoding]::UTF8
$j = [Console]::In.ReadToEnd() | ConvertFrom-Json
$E = [char]27
function C($n, $s) { "$E[38;5;${n}m$s$E[0m" }
function Dim($s) { "$E[2m$s$E[0m" }
function Bold($s) { "$E[1m$s$E[0m" }
function Clip($s, $n) { $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $n) { $s.Substring(0, $n - 1) + [string][char]0x2026 } else { $s } }

$sep = Dim "  $([char]0x00B7)  "
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
$used = $null; $skillOn = $false; $agents = 0; $curTool = $null; $quiet = 0; $mainQuiet = 0; $state = 'idle'; $since = $null; $first = $null; $last = $null
$tp = $j.transcript_path
if ($tp -and (Test-Path $tp)) {
    $fs = [IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    $len = $fs.Length; $take = [math]::Min($len, 400KB)
    $null = $fs.Seek($len - $take, 'Begin')
    $buf = New-Object byte[] $take
    $null = $fs.Read($buf, 0, $take); $fs.Close()
    $rawTxt = [Text.Encoding]::UTF8.GetString($buf); $lines = $rawTxt -split "`n"
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
            if ($t -and $t -notmatch '^\s*<[A-Za-z]') {
                if ($null -eq $last) {
                    $last = $t
                    try { $since = ($now.ToUniversalTime() - ([datetime]$o.timestamp).ToUniversalTime()).TotalSeconds } catch {}
                }
                $cands += ($t -replace '\s+', ' ').Trim()
            }
        }
        if ($null -ne $used -and $gotState -and $cands.Count -ge 8 -and $null -ne $first) { break }
    }
    # skill de ahorro de tokens en uso (se detecta al invocarla y se recuerda durante la sesion)
    try {
        $kf = Join-Path $env:USERPROFILE ".claude\state\skill-$sid.txt"
        if ($rawTxt -match '"skill"\s*:\s*"(ecc:)?ahorro-tokens"|<command-name>/?ahorro-tokens') {
            $skillOn = $true
            if (-not (Test-Path $kf)) { [IO.File]::WriteAllText($kf, '1') }
        } elseif (Test-Path $kf) { $skillOn = $true }
    } catch {}
    # cache de mensajes: si la cola del transcript (salidas enormes de agentes) no trae mensajes de usuario, usa los ultimos guardados
    try {
        $cf = Join-Path $env:USERPROFILE ".claude\state\msgs-$sid.txt"
        if ($cands.Count) {
            $nw = ($cands -join "`n")
            if (-not (Test-Path $cf) -or [IO.File]::ReadAllText($cf, [Text.Encoding]::UTF8) -ne $nw) { [IO.File]::WriteAllText($cf, $nw, (New-Object Text.UTF8Encoding($false))) }
        } elseif (Test-Path $cf) {
            $cands = @([IO.File]::ReadAllText($cf, [Text.Encoding]::UTF8) -split "`n" | Where-Object { $_ })
        }
    } catch {}
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
    # subagentes en segundo plano: sus transcripts viven en <sesion>/subagents/agent-*.jsonl
    $live = 0
    try {
        $sd = Join-Path (Join-Path (Split-Path $tp -Parent) ([IO.Path]::GetFileNameWithoutExtension($tp))) 'subagents'
        if (Test-Path $sd) {
            foreach ($af in Get-ChildItem $sd -Filter 'agent-*.jsonl') {
                if (($now - $af.LastWriteTime).TotalSeconds -gt 45) { continue }
                $as = [IO.File]::Open($af.FullName, 'Open', 'Read', 'ReadWrite')
                $tk = [math]::Min($as.Length, 6KB); $null = $as.Seek($as.Length - $tk, 'Begin')
                $ab = New-Object byte[] $tk; $null = $as.Read($ab, 0, $tk); $as.Close()
                $al = @([Text.Encoding]::UTF8.GetString($ab) -split "`n" | Where-Object { $_.Trim() })
                if ($al.Count -and $al[$al.Count - 1] -notmatch '"stop_reason":"end_turn"') { $live++ }
            }
        }
    } catch {}
    if ($live -gt $agents) { $agents = $live }
    $quiet = ($now - [IO.File]::GetLastWriteTime($tp)).TotalSeconds
    if ($state -eq 'work' -and $quiet -gt 180) { $state = 'idle' }
    $mainQuiet = $quiet
    if ($live -gt 0) { $state = 'work'; $quiet = 0 }
}

# parpadeo solo mientras Claude trabaja; en reposo todo queda fijo para no distraer al leer
$ph = $true; if ($state -eq 'work') { $ph = ($tick % 2 -eq 0) }

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
    if ($agents -gt 0 -and $mainQuiet -gt 10) {
        if ($agents -eq 1) { $wl = 'agente' } else { $wl = 'agentes' }
        $badge = (C 141 ("$frame Esperando $agents $wl").PadRight(22))
    } else {
        $badge = (C 214 ("$frame Trabajando$el").PadRight(22))
    }
} else {
    if ($ph) { $dot = [string][char]0x25CF } else { $dot = [string][char]0x25CB }
    $badge = (C 82 ("$dot Libre").PadRight(22))
}

# ---- barra de contexto ----
$bar = ''; $ctx = Dim 'ctx --'
if ($null -ne $used) {
    $pct = [math]::Min(100, [math]::Round(100 * $used / $size))
    $k = [math]::Round($used / 1000)
    $w = 12; $f = [math]::Round($pct / 100 * $w)
    if ($pct -lt 50) { $cc = 82 } elseif ($pct -lt 75) { $cc = 226 } elseif ($pct -lt 90) { $cc = 208 } else { $cc = 196 }
    $full = [string][char]0x25B0; $emp = [string][char]0x25B1
    $bar = (C $cc ($full * $f)) + (Dim ($emp * ($w - $f)))
    # recomendacion de /compact segun el contexto usado
    if ($pct -ge 85) { $tt = '/compact YA'; $tc = 196; if (-not $ph) { $tc = 88 } }
    elseif ($pct -ge 80) { $tt = '/compact recomendado'; $tc = 208 }
    elseif ($pct -ge 60) { $tt = '/compact pronto'; $tc = 226 }
    else { $tt = ''; $tc = 240 }
    if ($tt) { $tag = C $tc $tt } else { $tag = '' }
    $ctx = "$bar " + (C $cc ("{0,3}%" -f [int]$pct)) + (Dim (" {0,4}k" -f [int]$k)) + '  ' + $tag
}

if ($skillOn) { $ctx += '  ' + (C 49 "$([char]0x25C9) Ahorro tokens") }

# ---- coste / tiempo / lineas ----
$extra = @()
if ($j.cost) {
    if ($null -ne $j.cost.total_duration_ms) {
        $m = [int]([double]$j.cost.total_duration_ms / 60000)
        if ($m -ge 60) { $tm = '{0}h{1:00}m' -f [int][math]::Floor($m / 60), ($m % 60) } else { $tm = "${m}m" }
        
    }
}
# limites de uso: siempre visibles; >=80% amarillo, >90% rojo; hora real de reinicio
$dias = 'dom', 'lun', 'mar', 'mie', 'jue', 'vie', 'sab'
foreach ($lim in @(@('five_hour', 'Diario 5h'), @('seven_day', 'Semanal'))) {
    $r = $j.rate_limits.($lim[0])
    $lab = ([string]$lim[1]).PadRight(9)
    if ($r -and $null -ne $r.used_percentage) {
        $p = [int][math]::Round([double]$r.used_percentage)
        if ($p -gt 90) { $lc = 196 } elseif ($p -ge 80) { $lc = 226 } else { $lc = 82 }
        $bl = ($lim[0] -eq 'five_hour' -and $p -gt 92) -or ($lim[0] -eq 'seven_day' -and $p -gt 95)
        $mark = '  '; if ($bl) { if ($ph) { $mark = '! ' } else { $lc = 88 } }
        $rs = ''
        if ($r.resets_at) {
            try {
                $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.resets_at).LocalDateTime
                if ($dt.Date -eq $now.Date) { $rs = $dt.ToString('HH:mm') } else { $rs = $dias[[int]$dt.DayOfWeek] + ' ' + $dt.ToString('HH:mm') }
            } catch {}
        }
        if ($rs) { $rtxt = ('  Reinicio ' + $rs).PadRight(20) } else { $rtxt = ''.PadRight(20) }
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
if ($branch) { $r1 += '  ' + (Dim ([string][char]0xE0A0)) + ' ' + (C 213 $branch) }
$r1 += $sep + (Bold (C 214 $j.model.display_name))
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
$r1 += $sep + (C 117 $full2)
$rows += $r1

$agTxt = ("$([char]0x25C8) $agents " + $(if ($agents -eq 1) { 'Agente' } else { 'Agentes' })).PadRight(12)
if ($agents -gt 0) { $ag = C 141 $agTxt } else { $ag = Dim $agTxt }
$r2 = $badge + $sep + $ag + $sep + $ctx
$rows += $r2
if ($extra.Count) { $rows += (C $col ([string][char]0x25D4)) + ' ' + ($extra -join $sep) }

$msg = $resumen; if (-not $msg) { $msg = $ctxMsg }
function Cap($t) { if ($t) { $t.Substring(0,1).ToUpper() + $t.Substring(1) } else { $t } }
$msg = Cap $msg; $first = Cap $first
# resumen generado por Haiku (hook UserPromptSubmit): tema y mensaje con sentido
try {
    $sf = Join-Path $env:USERPROFILE ".claude\state\sum-$sid.json"
    if (Test-Path $sf) {
        $sj = [IO.File]::ReadAllText($sf, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $manual -and $sj.tema) { $first = Clip ([string]$sj.tema) 60 }
        if ($sj.mensaje) { $msg = Clip ([string]$sj.mensaje) 68 }
    }
} catch {}
$accion = 'Acci' + [string][char]0x00F3 + 'n   '
if ($toolTxt) {
    $qt = ''
    if ($quiet -gt 45) { if ($quiet -ge 60) { $qt = '   ' + (C 220 ("sin actividad $([int][math]::Floor($quiet / 60))m")) } else { $qt = '   ' + (C 220 ("sin actividad $([int]$quiet)s")) } }
    $rows += (C $col ([string][char]0x25B8)) + ' ' + (Dim $accion) + (C 208 $toolTxt) + $qt
} else {
    $rows += (C $col ([string][char]0x25B8)) + ' ' + (Dim $accion) + (Dim 'En espera')
}
$tm = ''
if ($first) { $tm += (C $col ([string][char]0x2726)) + ' ' + (Dim 'Tema ') + (Bold (C 87 $first)) }
if ($msg) { if ($tm) { $tm += $sep }; $tm += (C $col ([string][char]0x270E)) + ' ' + (Dim 'Mensaje ') + (C 183 $msg) }
if ($tm) { $rows += $tm }

foreach ($row in $rows) { ' ' + $row }
