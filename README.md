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

Notas: sin plan con límites de uso, los límites salen como `--`. Tema y resumen están pensados para español. Tema manual: `~/.claude/state/topic-<id de sesión>.txt`.
