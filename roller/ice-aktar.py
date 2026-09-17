#!/usr/bin/env python3
"""agency-agents kataloğundan ajan çeker ve bu yığına uyarlar.

Kaynak: github.com/msitarzewski/agency-agents (MIT). Oradaki dosyalar Markdown +
YAML frontmatter; gövde sistem istemi oluyor — bizim rol dosyalarımızla aynı biçim.
Uyarlanan üç şey var:

  1. `name` slug'a çevrilir. Katalogta "Code Reviewer" gibi boşluklu adlar var;
     hem Claude Code hem OpenShell/Canvas tarafı ad olarak slug bekliyor.
  2. `model` eklenir. Katalogta yok, çünkü orası araçtan bağımsız; bizde katman
     adı gerekiyor ve hedefe göre değişiyor (opus / litellm_proxy/opus).
  3. Gövdeye şirket kuralları bağlantısı eklenir. Çekilen ajan genel bir persona;
     bizim kurallarımızı okumasını söylemezsek okumaz.

Aynı dosyadan iki sürüm üretilir: host'taki Claude Code için ve Agent Canvas için.
Bu, spark-kod/spark-test/spark-denetci ile birebir aynı kalıptır.

Kullanım:
    ice-aktar.py --liste                       katalogtaki ajanları listele
    ice-aktar.py --onerilen                    bu yığın için seçilmiş seti kur
    ice-aktar.py engineering/code-reviewer ...  tek tek seç
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HAM = "https://raw.githubusercontent.com/msitarzewski/agency-agents/main"
API = "https://api.github.com/repos/msitarzewski/agency-agents/contents"

# Bu yığında gerçekten işe yarayanlar. Kendi rollerimizle (spark-kod, spark-test,
# spark-denetci) çakışanlar bilerek dışarıda: onlar kurallarımıza göre yazıldı,
# genel persona onların yerini almamalı.
ONERILEN = {
    "engineering/engineering-backend-architect": "opus",
    "engineering/engineering-frontend-developer": "opus",
    "engineering/engineering-software-architect": "opus",
    "engineering/engineering-database-optimizer": "opus",
    "engineering/engineering-devops-automator": "sonnet",
    "engineering/engineering-sre": "sonnet",
    "engineering/engineering-incident-response-commander": "sonnet",
    "engineering/engineering-git-workflow-master": "haiku",
    "engineering/engineering-technical-writer": "sonnet",
    "engineering/engineering-minimal-change-engineer": "opus",
    "engineering/engineering-codebase-onboarding-engineer": "sonnet",
    "engineering/engineering-api-platform-engineer": "opus",
    "product/product-manager": "sonnet",
    "product/product-sprint-prioritizer": "haiku",
    "project-management/project-management-meeting-notes-specialist": "haiku",
}

KURAL_BLOGU = """

---

## Şirket kuralları (spark-stack)

Bu ajan genel bir persona olarak yazıldı; aşağıdaki kurallar onun üstünde ve bağlayıcıdır.
İşe başlamadan önce ilgili dosyayı oku:

| Dosya | Ne zaman |
|---|---|
| `{k}/kod-standartlari.md` | kod yazarken |
| `{k}/test-kurallari.md` | test yazarken |
| `{k}/pr-kurallari.md` | commit ve PR hazırlarken |
| `{k}/yazim-kurallari.md` | doküman, yorum, rapor yazarken |

Kural ile kendi alışkanlığın çelişirse kural kazanır. Bir kural belirsizse bilgi tabanında
ara, uydurma. Test yazman gerekiyorsa `spark-test`, denetim gerekiyorsa `spark-denetci`
rolüne devret — kimse kendi işini onaylamaz.
"""


def slug(ad: str) -> str:
    s = ad.lower().strip()
    degis = {"ı": "i", "ş": "s", "ğ": "g", "ü": "u", "ö": "o", "ç": "c"}
    for a, b in degis.items():
        s = s.replace(a, b)
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return re.sub(r"-{2,}", "-", s) or "ajan"


def cek(yol: str) -> str:
    with urllib.request.urlopen(f"{HAM}/{yol}.md", timeout=30) as r:
        return r.read().decode()


def listele() -> None:
    for bolum in ("engineering", "product", "project-management", "design", "research"):
        try:
            with urllib.request.urlopen(f"{API}/{bolum}", timeout=30) as r:
                items = json.loads(r.read().decode())
        except urllib.error.URLError as exc:
            print(f"  {bolum}: alınamadı ({exc})", file=sys.stderr)
            continue
        print(f"\n{bolum}/")
        for it in items:
            if it["name"].endswith(".md"):
                print(f"  {bolum}/{it['name'][:-3]}")


def ayristir(metin: str) -> tuple[dict, str]:
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", metin, re.S)
    if not m:
        raise ValueError("frontmatter bulunamadı")
    meta: dict[str, str] = {}
    for satir in m.group(1).splitlines():
        if ":" in satir and not satir.startswith((" ", "\t", "#", "-")):
            k, _, v = satir.partition(":")
            meta[k.strip()] = v.strip().strip("\"'")
    return meta, m.group(2).strip()


def uret(meta: dict, govde: str, model: str, kural_yolu: str) -> str:
    ad = slug(meta.get("name", "ajan"))
    aciklama = meta.get("description", "").replace("\n", " ").strip()
    bas = [f"name: {ad}", f"description: {aciklama}", f"model: {model}"]
    if meta.get("color"):
        bas.append(f"color: {meta['color']}")
    return (
        "---\n"
        + "\n".join(bas)
        + "\n---\n\n"
        + govde.rstrip()
        + KURAL_BLOGU.format(k=kural_yolu)
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("ajanlar", nargs="*", help="bolum/dosya-adi (uzantısız)")
    ap.add_argument("--liste", action="store_true", help="katalogu listele")
    ap.add_argument("--onerilen", action="store_true", help="seçilmiş seti kur")
    ap.add_argument(
        "--model",
        default="sonnet",
        help="elle seçilenler için katman (varsayılan sonnet)",
    )
    ap.add_argument("--host-dizin", default=str(Path.home() / ".claude/agents"))
    ap.add_argument("--canvas-dizin", default="")
    ap.add_argument("--kurallar", default=str(Path.home() / "vault/kurallar"))
    ap.add_argument(
        "--onek", default="ajans-", help="ad öneki; kendi rollerimizle karışmasın"
    )
    a = ap.parse_args()

    if a.liste:
        listele()
        return 0

    secim = dict(ONERILEN) if a.onerilen else {y: a.model for y in a.ajanlar}
    if not secim:
        ap.print_help()
        return 1

    host = Path(a.host_dizin)
    host.mkdir(parents=True, exist_ok=True)
    canvas = Path(a.canvas_dizin) if a.canvas_dizin else None
    if canvas:
        canvas.mkdir(parents=True, exist_ok=True)

    ok = hata = 0
    for yol, model in secim.items():
        try:
            meta, govde = ayristir(cek(yol))
        except (urllib.error.URLError, ValueError, UnicodeDecodeError) as exc:
            print(f"  ✖ {yol}: {exc}")
            hata += 1
            continue
        ad = a.onek + slug(meta.get("name", Path(yol).name))
        meta["name"] = ad
        (host / f"{ad}.md").write_text(
            uret(meta, govde, model, a.kurallar), encoding="utf-8"
        )
        if canvas:
            (canvas / f"{ad}.md").write_text(
                uret(meta, govde, f"litellm_proxy/{model}", "/vault/kurallar"),
                encoding="utf-8",
            )
        print(f"  ✓ {ad}  ({model})")
        ok += 1

    nerede = f"{host}" + (f" ve {canvas}" if canvas else "")
    print(f"\n{ok} ajan kuruldu → {nerede}" + (f" · {hata} hata" if hata else ""))
    return 1 if hata and not ok else 0


if __name__ == "__main__":
    sys.exit(main())
