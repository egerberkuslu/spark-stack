#!/usr/bin/env python3
"""Katalogtan kurulan ajanları bu yığına uyarlar.

agency-agents'ın resmî kurucusu (scripts/install.sh) ajanları Claude Code'un
dizinine olduğu gibi kopyalar — araçtan bağımsız yazıldıkları için içlerinde ne
model adı ne de bizim kurallarımız vardır. Bu betik kurulumdan sonra çalışır ve
üç şeyi ekler:

  1. `model` alanı. Bizde katman adı gerekiyor; hangi katman olacağı ajanın
     işine göre seçilir (mimari/kod → opus, işletme → sonnet, özet → haiku).
  2. Şirket kuralları. Çekilen persona genel bir uzmandır; kuralları okumasını
     söylemezsek okumaz.
  3. Agent Canvas kopyası. Kapta model adı `litellm_proxy/<katman>` ve kural
     yolu `/vault/kurallar` olmak zorunda, host'takinden ayrışır.

Uyarlanmış dosyaya ikinci kez dokunulmaz; betik tekrar tekrar çalıştırılabilir.

    uyarla.py --host ~/.claude/agents --canvas /srv/ai/data/canvas/agents
    uyarla.py --sil engineering-sre
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

IZ = "<!-- spark-stack:uyarlandi -->"

# Ajanın işine göre katman. Eşleşme yoksa sonnet: ortada bir seçim, ne pahalı
# ne yetersiz. Anahtarlar dosya adında aranır.
KATMAN = {
    "opus": (
        "architect",
        "backend",
        "frontend",
        "database",
        "api-platform",
        "minimal-change",
        "senior-developer",
        "software",
        "security",
        "refactoring",
        "privacy",
        "payments",
    ),
    "haiku": (
        "git-workflow",
        "meeting-notes",
        "sprint-prioritizer",
        "studio-operations",
        "feedback-synthesizer",
    ),
}


def katman_sec(ad: str) -> str:
    for tier, anahtarlar in KATMAN.items():
        if any(a in ad for a in anahtarlar):
            return tier
    return "sonnet"


def kural_blogu(kural_yolu: str) -> str:
    kok = kural_yolu.rsplit("/", 1)[0] or kural_yolu
    return f"""

{IZ}

---

## Şirket kuralları (spark-stack)

Bu ajan genel bir persona olarak yazıldı; aşağıdaki kurallar onun üstünde ve bağlayıcıdır.
İşe başlamadan önce ilgili dosyayı oku:

| Dosya | Ne zaman |
|---|---|
| `{kural_yolu}/kod-standartlari.md` | kod yazarken |
| `{kural_yolu}/test-kurallari.md` | test yazarken |
| `{kural_yolu}/pr-kurallari.md` | commit ve PR hazırlarken |
| `{kural_yolu}/yazim-kurallari.md` | doküman, yorum, rapor yazarken |

Kural ile kendi alışkanlığın çelişirse kural kazanır. Test yazman gerekiyorsa `spark-test`,
denetim gerekiyorsa `spark-denetci` rolüne devret — kimse kendi işini onaylamaz.

## Bilgi tabanında araştır

Şirketin hafızası `{kok}` altında, salt okunur. Geçmiş bir karar, tasarım notu ya da kaynak
gerektiren her soruda önce oraya bak; hafızandan cevap verme.

| Nerede | Ne var |
|---|---|
| `{kok}/wiki/index.md` | başlangıç noktası, konu haritası |
| `{kok}/wiki/overview.md` | sistemin bugünkü hâli |
| `{kok}/wiki/log.md` | kararlar ve ne zaman alındıkları |
| `{kok}/inbox/` | henüz işlenmemiş kaynaklar |

`grep -ril "konu" {kok}/wiki` ile başla, bulduğun sayfayı oku. Karar vault'ta yazılıysa ona uy
ve hangi sayfaya dayandığını söyle. Yazılı değilse "vault'ta kayıt yok" de, varmış gibi konuşma.
"""


def slug(ad: str) -> str:
    s = ad.lower().strip()
    for a, b in {"ı": "i", "ş": "s", "ğ": "g", "ü": "u", "ö": "o", "ç": "c"}.items():
        s = s.replace(a, b)
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return re.sub(r"-{2,}", "-", s) or "ajan"


def ayristir(metin: str) -> tuple[list[str], str] | None:
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n(.*)$", metin, re.S)
    if not m:
        return None
    return m.group(1).splitlines(), m.group(2)


def alan(satirlar: list[str], ad: str) -> str | None:
    for s in satirlar:
        if s.lower().startswith(ad + ":"):
            return s.split(":", 1)[1].strip().strip("\"'")
    return None


def yaz(hedef: Path, satirlar: list[str], govde: str, model: str, kural: str) -> None:
    fm = [s for s in satirlar if not s.lower().startswith("model:")]
    fm.append(f"model: {model}")
    if IZ not in govde:
        govde = govde.rstrip() + kural_blogu(kural)
    hedef.write_text(
        "---\n" + "\n".join(fm) + "\n---\n\n" + govde.lstrip(), encoding="utf-8"
    )


def uyarla(
    host: Path, canvas: Path | None, kural_host: str, onek: str
) -> tuple[int, int]:
    yeni = atlanan = 0
    for f in sorted(host.glob("*.md")):
        if f.name.startswith("spark-"):
            continue  # kendi rollerimiz; onlar zaten uyarlı
        metin = f.read_text(encoding="utf-8")
        parca = ayristir(metin)
        if not parca:
            continue
        satirlar, govde = parca
        if IZ in govde and alan(satirlar, "model"):
            atlanan += 1
            continue

        ad = alan(satirlar, "name") or f.stem
        yeni_ad = slug(ad)
        if onek and not yeni_ad.startswith(onek):
            yeni_ad = onek + yeni_ad
        satirlar = [s for s in satirlar if not s.lower().startswith("name:")]
        satirlar.insert(0, f"name: {yeni_ad}")

        tier = katman_sec(f.stem.lower())
        hedef = host / f"{yeni_ad}.md"
        yaz(hedef, satirlar, govde, tier, kural_host)
        if hedef != f:
            f.unlink()
        if canvas:
            yaz(
                canvas / f"{yeni_ad}.md",
                satirlar,
                govde,
                f"litellm_proxy/{tier}",
                "/vault/kurallar",
            )
        print(f"  ✓ {yeni_ad}  ({tier})")
        yeni += 1
    return yeni, atlanan


def sil(adlar: list[str], host: Path, canvas: Path | None) -> int:
    n = 0
    for ad in adlar:
        for d in (host, canvas):
            if not d:
                continue
            for p in list(d.glob(f"*{ad}*.md")):
                if p.name.startswith("spark-"):
                    print(f"  ! {p.name} temel rol, silinmedi")
                    continue
                p.unlink()
                print(f"  ✗ {p}")
                n += 1
    return n


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--host", required=True)
    ap.add_argument("--canvas", default="")
    ap.add_argument("--kurallar", required=True)
    ap.add_argument("--onek", default="ajans-")
    ap.add_argument("--sil", nargs="+", metavar="AD")
    a = ap.parse_args()

    host = Path(a.host)
    if not host.is_dir():
        print(f"dizin yok: {host}", file=sys.stderr)
        return 1
    canvas = Path(a.canvas) if a.canvas else None
    if canvas:
        canvas.mkdir(parents=True, exist_ok=True)

    if a.sil:
        n = sil(a.sil, host, canvas)
        print(f"\n{n} dosya silindi" if n else "\neşleşen ajan yok")
        return 0

    yeni, atlanan = uyarla(host, canvas, a.kurallar, a.onek)
    print(
        f"\n{yeni} ajan uyarlandı" + (f", {atlanan} zaten uyarlıydı" if atlanan else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
