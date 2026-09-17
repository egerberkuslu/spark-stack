#!/usr/bin/env python3
"""spark-stack A2A köprüsü.

Roller (spark-kod, spark-test, spark-denetci) bu sunucu üzerinden Agent2Agent
protokolüyle dışarı açılır. Böylece bir ajan, başka bir süreçteki hatta başka
bir makinedeki role standart bir protokolle görev verebilir; SDK'ya ya da aynı
konuşmaya bağlı kalmaz.

Tasarım kararları:
  - Yalnız standart kütüphane. Kurulum adımı, pip, derleme yok; imaj
    python:3.12-alpine olarak doğrudan çalışır.
  - Rol tanımı tek kaynaktan gelir: roller/agents/*.md dosyalarının frontmatter
    ve gövdesi. Sistem istemi gövdedir, yani kural okuma talimatı da oradan
    gelir; burada kopyası tutulmaz.
  - Kurallar salt okunur bağlanır ve her isteğe sistem isteminin içine eklenir.
    Böylece uzaktan gelen bir görev de şirket kurallarına bağlı kalır.

Protokol: https://github.com/a2aproject/A2A; keşif /.well-known/agent-card.json,
gövde JSON-RPC 2.0, metotlar SendMessage / GetTask / ListTasks / CancelTask.
"""

from __future__ import annotations

import json
import os
import re
import threading
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROTOCOL_VERSION = "1.0"
JSONRPC = "2.0"

ROLES_DIR = Path(os.environ.get("A2A_ROLES_DIR", "/roles"))
RULES_DIR = Path(os.environ.get("A2A_RULES_DIR", "/vault/kurallar"))
GATEWAY = os.environ.get("A2A_GATEWAY_URL", "http://litellm:4000/v1").rstrip("/")
GATEWAY_KEY = os.environ.get("A2A_GATEWAY_KEY", "sk-spark")
PORT = int(os.environ.get("A2A_PORT", "8400"))
BASE_URL = os.environ.get("A2A_BASE_URL", f"http://localhost:{PORT}").rstrip("/")
MAX_TOKENS = int(os.environ.get("A2A_MAX_TOKENS", "4096"))
REQUEST_TIMEOUT = int(os.environ.get("A2A_TIMEOUT", "900"))

# JSON-RPC hata kodları: spec 9.x
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
TASK_NOT_FOUND = -32001
TASK_NOT_CANCELABLE = -32002

_TASKS: dict[str, dict] = {}
_TASKS_LOCK = threading.Lock()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ── Rol yükleme ─────────────────────────────────────────────────────────────


def _parse_role(path: Path) -> dict | None:
    """frontmatter + gövde ayrıştırır. Gövde sistem istemidir."""
    text = path.read_text(encoding="utf-8")
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", text, re.S)
    if not m:
        return None
    raw, body = m.group(1), m.group(2).strip()
    meta: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" in line and not line.startswith((" ", "\t", "#")):
            k, _, v = line.partition(":")
            meta[k.strip()] = v.strip().strip("\"'")
    name = meta.get("name") or path.stem
    return {
        "id": name,
        "name": name,
        "description": meta.get("description", ""),
        "model": meta.get("model", "opus"),
        "system_prompt": body,
    }


def load_roles() -> dict[str, dict]:
    roles: dict[str, dict] = {}
    if not ROLES_DIR.is_dir():
        return roles
    for path in sorted(ROLES_DIR.glob("*.md")):
        if path.name.lower() == "readme.md":
            continue
        role = _parse_role(path)
        if role:
            roles[role["id"]] = role
    return roles


def load_rules() -> str:
    """Kuralları tek metne toplar. Uzaktan gelen görev de bunlara bağlı kalır."""
    if not RULES_DIR.is_dir():
        return ""
    chunks = []
    for path in sorted(RULES_DIR.glob("*.md")):
        try:
            chunks.append(
                f"### {path.name}\n\n{path.read_text(encoding='utf-8').strip()}"
            )
        except OSError:
            continue
    if not chunks:
        return ""
    return (
        "Aşağıdaki şirket kuralları bağlayıcıdır; işe başlamadan önce bunlara uy.\n\n"
        + "\n\n".join(chunks)
        + "\n\n## Bilgi tabanı\n\n"
        "Şirketin hafızası /vault altında salt okunur bağlı: /vault/wiki/index.md konu "
        "haritası, /vault/wiki/log.md kararlar, /vault/inbox/ işlenmemiş kaynaklar. "
        "Geçmiş bir karara dayanan her cevapta önce oraya bak; dayandığın sayfayı söyle. "
        "Kayıt yoksa 'vault'ta kayıt yok' de, varmış gibi konuşma.\n\n"
        "Not: bu çağrı protokol üzerinden geldi; dosya okuma aracın yoksa yukarıdaki "
        "kuralları uygula ve vault'a bakman gerektiğini raporunda belirt."
    )


# ── Agent Card ──────────────────────────────────────────────────────────────


def _skill(role: dict) -> dict:
    return {
        "id": role["id"],
        "name": role["name"],
        "description": role["description"],
        "tags": ["spark-stack", "yerel", role["id"]],
        "inputModes": ["text/plain"],
        "outputModes": ["text/plain"],
    }


def agent_card(roles: dict[str, dict], role_id: str | None = None) -> dict:
    if role_id:
        role = roles[role_id]
        name = role["name"]
        desc = role["description"]
        url = f"{BASE_URL}/agents/{role_id}/a2a/v1"
        skills = [_skill(role)]
    else:
        name = "spark-stack"
        desc = (
            "DGX Spark üzerinde yerel model havuzuyla çalışan rol tabanlı ajanlar. "
            "Her rol şirket kurallarını bilgi tabanından okuyarak çalışır."
        )
        url = f"{BASE_URL}/a2a/v1"
        skills = [_skill(r) for r in roles.values()]
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "name": name,
        "description": desc,
        "version": os.environ.get("A2A_VERSION", "1.0.0"),
        "supportedInterfaces": [
            {
                "url": url,
                "protocolBinding": "JSONRPC",
                "protocolVersion": PROTOCOL_VERSION,
            }
        ],
        "capabilities": {"streaming": False, "pushNotifications": False},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": skills,
    }


# ── Modeli çağırma ──────────────────────────────────────────────────────────


def call_gateway(model: str, system: str, user: str) -> str:
    # Rol dosyaları Agent Canvas için "litellm_proxy/<katman>" yazar; biz kapıya
    # doğrudan konuştuğumuz için önek düşer ve katman adı kalır. Tek kaynak
    # bozulmasın diye ayrı bir rol kopyası tutmuyoruz.
    if model.startswith("litellm_proxy/"):
        model = model.split("/", 1)[1]
    payload = json.dumps({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }).encode()
    req = urllib.request.Request(
        f"{GATEWAY}/chat/completions",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {GATEWAY_KEY}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
        body = json.loads(resp.read().decode())
    return body["choices"][0]["message"]["content"]


# ── JSON-RPC ────────────────────────────────────────────────────────────────


def _text_from_message(message: dict) -> str:
    parts = message.get("parts") or []
    out = []
    for p in parts:
        if isinstance(p, dict):
            if "text" in p:
                out.append(str(p["text"]))
            elif isinstance(p.get("root"), dict) and "text" in p["root"]:
                out.append(str(p["root"]["text"]))
    return "\n".join(out).strip()


def _task(
    task_id: str, context_id: str, state: str, text: str | None, role_id: str
) -> dict:
    task = {
        "id": task_id,
        "contextId": context_id,
        "status": {"state": state, "timestamp": _now()},
        "metadata": {"role": role_id},
    }
    if text is not None:
        task["artifacts"] = [
            {
                "artifactId": str(uuid.uuid4()),
                "name": f"{role_id} çıktısı",
                "parts": [{"text": text}],
            }
        ]
    return task


def handle_send_message(params: dict, roles: dict, path_role: str | None) -> dict:
    message = params.get("message")
    if not isinstance(message, dict):
        raise JsonRpcError(INVALID_PARAMS, "params.message gerekli")
    user_text = _text_from_message(message)
    if not user_text:
        raise JsonRpcError(INVALID_PARAMS, "message.parts içinde metin yok")

    role_id = (
        path_role
        or params.get("skillId")
        or (message.get("metadata") or {}).get("skillId")
    )
    if not role_id:
        role_id = next(iter(roles), None)
    if role_id not in roles:
        raise JsonRpcError(INVALID_PARAMS, f"bilinmeyen rol: {role_id}")
    role = roles[role_id]

    task_id = str(uuid.uuid4())
    context_id = (
        params.get("contextId") or message.get("contextId") or str(uuid.uuid4())
    )

    rules = load_rules()
    system = (
        role["system_prompt"]
        if not rules
        else f"{role['system_prompt']}\n\n---\n\n{rules}"
    )

    try:
        answer = call_gateway(role["model"], system, user_text)
        task = _task(task_id, context_id, "TASK_STATE_COMPLETED", answer, role_id)
    except (urllib.error.URLError, KeyError, ValueError, TimeoutError) as exc:
        task = _task(
            task_id,
            context_id,
            "TASK_STATE_FAILED",
            f"kapıya ulaşılamadı: {exc}",
            role_id,
        )

    with _TASKS_LOCK:
        _TASKS[task_id] = task
    return {"task": task}


def handle_get_task(params: dict) -> dict:
    task_id = params.get("id") or params.get("taskId")
    with _TASKS_LOCK:
        task = _TASKS.get(task_id)
    if task is None:
        raise JsonRpcError(TASK_NOT_FOUND, "görev bulunamadı")
    return {"task": task}


def handle_list_tasks(_params: dict) -> dict:
    with _TASKS_LOCK:
        return {"tasks": list(_TASKS.values())}


def handle_cancel_task(params: dict) -> dict:
    task_id = params.get("id") or params.get("taskId")
    with _TASKS_LOCK:
        task = _TASKS.get(task_id)
        if task is None:
            raise JsonRpcError(TASK_NOT_FOUND, "görev bulunamadı")
        state = task["status"]["state"]
        if state in (
            "TASK_STATE_COMPLETED",
            "TASK_STATE_FAILED",
            "TASK_STATE_CANCELED",
        ):
            raise JsonRpcError(TASK_NOT_CANCELABLE, f"görev {state} durumunda")
        task["status"] = {"state": "TASK_STATE_CANCELED", "timestamp": _now()}
        return {"task": task}


class JsonRpcError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# Spesifikasyon v1.0'da metotlar "SendMessage", v0.3'te "message/send" yazılıyordu
# ve sahadaki istemciler ikiye bölünmüş durumda. İkisini de kabul ediyoruz;
# reddetmek uyumluluk kazandırmaz, yalnız çağıranı kırar.
ALIASES = {
    "message/send": "SendMessage",
    "tasks/get": "GetTask",
    "tasks/list": "ListTasks",
    "tasks/cancel": "CancelTask",
}

METHODS = {
    "SendMessage": None,  # rol bilgisi gerektiği için ayrı ele alınır
    "GetTask": handle_get_task,
    "ListTasks": handle_list_tasks,
    "CancelTask": handle_cancel_task,
}


# ── HTTP ────────────────────────────────────────────────────────────────────

CARD_SUFFIX = "/.well-known/agent-card.json"


class Handler(BaseHTTPRequestHandler):
    server_version = "spark-stack-a2a/1.0"

    def log_message(
        self, fmt: str, *args: object
    ) -> None:  # sessiz; docker logs zaten satırı taşır
        print(f"{self.address_string()} {fmt % args}", flush=True)

    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _role_from_path(self, path: str, suffix: str) -> str | None:
        m = re.match(r"^/agents/([^/]+)" + re.escape(suffix) + r"$", path)
        return m.group(1) if m else None

    def do_GET(self) -> None:  # noqa: N802
        roles = load_roles()
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path == CARD_SUFFIX:
            return self._send(200, agent_card(roles))
        role_id = self._role_from_path(path, CARD_SUFFIX)
        if role_id:
            if role_id not in roles:
                return self._send(404, {"error": "bilinmeyen rol"})
            return self._send(200, agent_card(roles, role_id))
        if path == "/health":
            return self._send(
                200, {"status": "ok", "roles": sorted(roles), "gateway": GATEWAY}
            )
        return self._send(404, {"error": "bulunamadı"})

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        path_role = self._role_from_path(path, "/a2a/v1")
        if path not in ("/a2a/v1",) and path_role is None:
            return self._send(404, {"error": "bulunamadı"})

        try:
            req = json.loads(raw.decode() or "{}")
        except (ValueError, UnicodeDecodeError):
            return self._send(200, self._err(None, PARSE_ERROR, "geçersiz JSON"))

        if (
            not isinstance(req, dict)
            or req.get("jsonrpc") != JSONRPC
            or "method" not in req
        ):
            return self._send(
                200,
                self._err(
                    req.get("id") if isinstance(req, dict) else None,
                    INVALID_REQUEST,
                    "geçersiz JSON-RPC isteği",
                ),
            )

        rid = req.get("id")
        method = ALIASES.get(req["method"], req["method"])
        params = req.get("params") or {}
        roles = load_roles()

        try:
            if method == "SendMessage":
                result = handle_send_message(params, roles, path_role)
            elif method in METHODS and METHODS[method]:
                result = METHODS[method](params)
            else:
                return self._send(
                    200, self._err(rid, METHOD_NOT_FOUND, f"bilinmeyen metot: {method}")
                )
        except JsonRpcError as exc:
            return self._send(200, self._err(rid, exc.code, exc.message))
        # Sunucu sınırı: beklenmedik hata istemciye JSON-RPC hatası olarak döner, yutulmaz
        except Exception as exc:  # noqa: BLE001
            return self._send(200, self._err(rid, INTERNAL_ERROR, str(exc)))

        return self._send(200, {"jsonrpc": JSONRPC, "id": rid, "result": result})

    @staticmethod
    def _err(rid: str | int | None, code: int, message: str) -> dict:
        return {
            "jsonrpc": JSONRPC,
            "id": rid,
            "error": {"code": code, "message": message},
        }


def main() -> None:
    roles = load_roles()
    print(
        f"spark-stack A2A köprüsü :{PORT}  roller={sorted(roles) or 'YOK'}  "
        f"kapı={GATEWAY}  kurallar={'var' if load_rules() else 'yok'}",
        flush=True,
    )
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
