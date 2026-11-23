# Barra de estado para Claude Code

Barra de estado en 5 líneas para Claude Code (Windows, PowerShell 5.1): modelo, carpeta y rama, ruta abreviada, estado y agentes, contexto, límites diario/semanal con hora de reinicio, acción en curso, tema y resumen del último mensaje.

## Instalación
1. Copia `statusline.ps1` a `C:\Users\<tu-usuario>\.claude\`.
2. Añade a `settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/<tu-usuario>/.claude/statusline.ps1",
  "refreshInterval": 1
}
```
3. Reinicia Claude Code.

## Tema y resumen con sentido (opcional, usa Haiku)
Un hook genera con Claude Haiku el tema de la conversación y el resumen del último mensaje, y la barra los muestra en la última línea. Se actualiza con el 1.er mensaje y después cada 3. Gasta unos ~1.300 tokens de entrada por llamada (medido). Si no lo instalas, la barra usa palabras clave (gratis, pero con menos sentido).

1. Copia `hooks/summarize_prompt.py` a `C:\Users\<tu-usuario>\.claude\hooks\`.
2. Añade a `settings.json`:

```json
"hooks": {
  "UserPromptSubmit": [
    { "hooks": [ { "type": "command", "command": "python C:/Users/<tu-usuario>/.claude/hooks/summarize_prompt.py" } ] }
  ]
}
```
3. Reinicia Claude Code. Necesita `python` y `claude` en el PATH.

## Notas
- Sin plan con límites de uso, los límites salen como `--`.
- Pensado para mensajes en español.
- Tema manual: `~/.claude/state/topic-<id de sesión>.txt`.
- Cuenta los agentes en segundo plano leyendo `<sesión>/subagents/agent-*.jsonl`.
