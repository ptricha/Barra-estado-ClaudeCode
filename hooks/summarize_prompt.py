"""Hook UserPromptSubmit: genera tema y resumen del ultimo mensaje con Haiku (en segundo plano)
y los guarda en ~/.claude/state/sum-<session>.json para la barra de estado."""
import json, os, subprocess, sys, tempfile

STATE = os.path.join(os.path.expanduser('~'), '.claude', 'state')
PROMPT = """Eres el generador de etiquetas de una barra de estado. El usuario tiene varios chats abiertos y necesita saber de un vistazo de que va cada uno.
Devuelve SOLO un JSON valido, sin texto extra ni bloques de codigo: {"tema": "...", "mensaje": "..."}
- "tema": de que va la conversacion en general, frase con sentido, maximo 50 caracteres (cuentalos: es obligatorio no pasar de 50), sin verbos de orden (ej: "Refactor del modulo de pagos y sus tests"). Si el tema anterior sigue valiendo, conservalo tal cual.
- "mensaje": resumen del ULTIMO mensaje del usuario, frase completa y con sentido, maximo 70 caracteres, en espanol (ej: "Usar PostgreSQL en vez de SQLite y esperar mas instrucciones").
Tema anterior: {tema}
Mensajes recientes del usuario (el ultimo es el mas reciente):
{prompts}"""


def path(sid):
    return os.path.join(STATE, 'sum-%s.json' % sid)


def load(sid):
    try:
        with open(path(sid), encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {'tema': '', 'mensaje': '', 'prompts': []}


def worker(sid):
    d = load(sid)
    prompts = d.get('prompts', [])[-4:]
    text = PROMPT.replace('{tema}', d.get('tema') or '(ninguno)').replace(
        '{prompts}', '\n'.join('- ' + p[:600] for p in prompts))
    env = dict(os.environ, CC_SUMMARY_JOB='1')
    r = subprocess.run(
        ['claude', '-p', '--model', 'haiku', '--no-session-persistence', '--disable-slash-commands',
         '--strict-mcp-config', '--tools', '', '--system-prompt', 'Responde solo con lo pedido.',
         '--output-format', 'text', text],
        capture_output=True, text=True, encoding='utf-8', env=env, cwd=tempfile.gettempdir(), timeout=120,
        creationflags=0x08000000)
    out = r.stdout.strip()
    a, b = out.find('{'), out.rfind('}')
    res = json.loads(out[a:b + 1])
    d = load(sid)  # recargar por si llego otro mensaje mientras tanto
    d['tema'] = str(res.get('tema', d.get('tema', ''))).strip()
    d['mensaje'] = str(res.get('mensaje', '')).strip()
    tmp = path(sid) + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, path(sid))


def main():
    if os.environ.get('CC_SUMMARY_JOB'):
        return
    if len(sys.argv) > 2 and sys.argv[1] == '--worker':
        try:
            worker(sys.argv[2])
        except Exception:
            pass
        return
    try:
        data = json.load(sys.stdin)
        sid, prompt = data['session_id'], (data.get('prompt') or '').strip()
    except Exception:
        return
    if not prompt or prompt.startswith('<'):
        return
    os.makedirs(STATE, exist_ok=True)
    d = load(sid)
    d['prompts'] = (d.get('prompts', []) + [prompt])[-6:]
    d['n'] = d.get('n', 0) + 1
    with open(path(sid), 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    if d['n'] % 3 != 1:  # solo se resume el 1.o y despues cada 3 mensajes
        return
    subprocess.Popen([(sys.executable.replace('python.exe', 'pythonw.exe')), __file__, '--worker', sid], creationflags=0x08000008,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)


main()
