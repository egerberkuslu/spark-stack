#!/usr/bin/env bash
# Kural kapısını makineye kurar. install.sh çağırır; tek başına da çalışır.
#
#   kur.sh <AI_ROOT> <kaynak roller/denetim dizini>
#
# Ne yapar: kapı betiğini ve kancaları $AI_ROOT/denetim altına koyar, ruff ve
# pytest için ayrı bir sanal ortam açar (sistem Python'una dokunmaz), statik
# statik shellcheck'i indirir, git'in genel kanca yolunu bu dizine çevirir. Aynı dizin
# Canvas kabına /opt/spark-denetim olarak bağlanır; ruff ve shellcheck ikilileri
# bin/ altında durduğu için kapta da aynı denetim koşar.
set -Eeuo pipefail
AI_ROOT="${1:?AI_ROOT gerekli}"; SRC="${2:?kaynak dizin gerekli}"
D="$AI_ROOT/denetim"
mkdir -p "$D/bin" "$D/hooks"
cp "$SRC/kural_kapisi.py" "$SRC/github-workflow.yml" "$SRC/pull_request_template.md" "$D/"
cp "$SRC"/hooks/* "$D/hooks/"; chmod +x "$D/hooks/"* "$D/kural_kapisi.py"

# ruff + pytest: kendi sanal ortamı. ruff'ın ikilisi bin/'e de kopyalanır;
# kapta Python sürümü farklı olsa da o ikili tek başına çalışır.
if [[ ! -x "$D/.venv/bin/ruff" ]]; then
  python3 -m venv "$D/.venv"
  "$D/.venv/bin/pip" install -q --upgrade pip >/dev/null
  "$D/.venv/bin/pip" install -q ruff pytest
fi
cp -f "$D/.venv/bin/ruff" "$D/bin/ruff"

# Statik shellcheck: resmi sürüm tek dosya; apt paketi kap için uygun değil.
if [[ ! -x "$D/bin/shellcheck" ]]; then
  ARCH="$(uname -m)"; T="$(mktemp -d)"
  if curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.${ARCH}.tar.xz" -o "$T/sc.tar.xz" \
     && tar -xJf "$T/sc.tar.xz" -C "$T"; then
    cp "$T"/shellcheck-stable/shellcheck "$D/bin/shellcheck"; chmod +x "$D/bin/shellcheck"
  elif command -v shellcheck >/dev/null; then
    cp "$(command -v shellcheck)" "$D/bin/shellcheck"
  fi
  rm -rf "$T"
fi

# Genel kanca yolu: makinedeki her depo (insan ve Claude Code dahil) kapıdan geçer.
git config --global core.hooksPath "$D/hooks"
touch "$D/atlama.log"

printf 'kapı: %s\nruff: %s\nshellcheck: %s\nhooksPath: %s\n' \
  "$D/kural_kapisi.py" "$("$D/bin/ruff" --version 2>/dev/null || echo yok)" \
  "$("$D/bin/shellcheck" --version 2>/dev/null | sed -n 's/^version: //p' || echo yok)" \
  "$(git config --global core.hooksPath)"
