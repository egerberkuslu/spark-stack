#!/usr/bin/env bash
# Ortak skill dizinini derler: makinede ne varsa kapta da olsun.
#
# Agent Canvas kullanıcı skill'lerini ~/.agents/skills altından okur ve biçim
# Claude Code'unkiyle aynı (SKILL.md + frontmatter). Bu betik üç kaynağı tek
# dizinde birleştirir, compose da onu kaba salt okunur bağlar:
#
#   1. kurallar/*.md   → tetikleyicisiz düz .md; her konuşmada TAM METİN yüklenir
#   2. claude-obsidian skill'leri → PRODUCT_ROOT kaptaki yola sabitlenir
#   3. host skill'leri (~/.claude/skills) → superpowers ve kendi yazdıkların
#
# Her çalıştırmada hedef sıfırdan kurulur; silinen bir skill kapta kalmaz.
#
#   skill-birlestir.sh <hedef> <kurallar> <claude-obsidian-kok> [host-skills]

set -Eeuo pipefail

HEDEF="${1:?kullanım: skill-birlestir.sh <hedef> <kurallar> <co-kök> [host-skills]}"
KURALLAR="${2:?kurallar dizini gerekli}"
CO_KOK="${3:-}"
HOST_SKILLS="${4:-$HOME/.claude/skills}"
# Kapta claude-obsidian'ın bağlandığı yol; skill'lerdeki yer tutucu buna çevrilir
CO_KAP="${CO_KAP:-/opt/claude-obsidian}"

rm -rf "$HEDEF"; mkdir -p "$HEDEF"

k=0; c=0; h=0

# 1) Kurallar: klasörsüz düz .md. Tetikleyicisi olmadığı için tam metin yüklenir,
#    yani kuralı okumak ajanın kararına kalmaz.
if [[ -d "$KURALLAR" ]]; then
  for f in "$KURALLAR"/*.md; do
    [[ -e "$f" ]] || continue
    cp "$f" "$HEDEF/"; k=$((k+1))
  done
fi

# 2) claude-obsidian skill'leri. Betik yolları PRODUCT_ROOT üzerinden veriliyor
#    ve kaynakta yer tutucu olarak duruyor; kaptaki gerçek yola sabitliyoruz.
if [[ -n "$CO_KOK" && -d "$CO_KOK/skills" ]]; then
  for d in "$CO_KOK/skills"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    ad="$(basename "$d")"
    mkdir -p "$HEDEF/$ad"
    cp -r "$d". "$HEDEF/$ad/"
    sed -i "s|/absolute/path/to/installed/claude-obsidian|$CO_KAP|g" "$HEDEF/$ad/SKILL.md"
    c=$((c+1))
  done
fi

# 3) Host skill'leri. Aynı ada sahip bir skill varsa üzerine yazılmaz: kurallar
#    ve claude-obsidian öncelikli, çünkü onlar bu yığının sözleşmesi.
if [[ -d "$HOST_SKILLS" ]]; then
  for d in "$HOST_SKILLS"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    ad="$(basename "$d")"
    [[ -e "$HEDEF/$ad" ]] && continue
    mkdir -p "$HEDEF/$ad"
    cp -r "$d". "$HEDEF/$ad/"
    h=$((h+1))
  done
fi

echo "kurallar=$k claude-obsidian=$c host=$h  →  $HEDEF"
