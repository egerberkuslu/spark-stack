#!/usr/bin/env bash
###############################################################################
#  spark-stack — DGX Spark yerel kod asistanı · Docker tabanlı kurulum        #
#                                                                             #
#    bash install.sh --demo             haiku + sonnet           ~45 GB      #
#    bash install.sh                    + opus                   ~65 GB      #
#    bash install.sh --all              dört katman + eklentiler ~132 GB     #
#                                                                             #
#    --token hf_xxx      HuggingFace anahtarını komutla ver                   #
#    --with-fable        dördüncü katman (en yüksek kalite)                   #
#    --with-extras       Open WebUI + Qdrant + Whisper                        #
#    --with-wiki         Obsidian + claude-obsidian bilgi tabanı              #
#    --with-nemoclaw     NVIDIA NemoClaw ajan kabı (--all dahil)              #
#    --with-swap         llama-swap: katmanı istek anında aç (--all dahil)    #
#    --with-canvas       Agent Canvas ajan kontrol merkezi (--all dahil)      #
#    --with-a2a          A2A köprüsü: rolleri protokolle aç (--all dahil)     #
#    --vault PATH        vault yolu (varsayılan ~/vault)                      #
#    --resume            yarım kalan kurulumu sürdür                          #
#    --status            servis durumu     --uninstall   tümünü kaldır        #
#                                                                             #
#  Makineye kurulan tek şey: Claude Code (tek dosya CLI).                     #
#  Modeller, sunucular, veritabanları, MCP sunucuları — hepsi konteynerde.    #
###############################################################################
set -Eeuo pipefail
VERSION="2.0-docker"
START_TS=$(date +%s)
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

AI_ROOT="${AI_ROOT:-/srv/ai}"
MODELS="$AI_ROOT/models"; DATA="$AI_ROOT/data"; CDIR="$AI_ROOT/compose"
STATE="$DATA/.state"; LOGFILE="$AI_ROOT/install.log"
ENVF="$CDIR/.env"
WITH_FABLE=0; WITH_EXTRAS=0; WITH_WIKI=0; WITH_NEMOCLAW=0; WITH_SWAP=0; WITH_CANVAS=0; WITH_A2A=0
RESUME=0; MODE=install; DEMO=0
TIERS=(haiku sonnet opus)          # varsayılan kurulum katmanları
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-}"
NEMOCLAW_SANDBOX="${NEMOCLAW_SANDBOX:-spark}"   # NemoClaw kabının adı

if [[ -t 1 ]]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; BLU=$'\033[1;36m'
else B=""; D=""; R=""; RED=""; GRN=""; YLW=""; BLU=""; fi

STEP_KEYS=(precheck docker layout images models gateway boot claude mcp skills wiki nemoclaw verify)
STEP_NAME=("Ön kontrol" "Docker + GPU altyapısı" "Dosya düzeni" "İmajlar indiriliyor" \
           "Model ağırlıkları" "Kapı ayarı" "Servisler açılıyor" "Claude Code" \
           "MCP sunucuları" "Skill'ler ve roller" "Obsidian + bilgi tabanı" "NemoClaw ajan kabı" \
           "Doğrulama")
STEP_WEIGHT=(1 6 1 12 50 2 15 4 8 3 3 6 1)
TOTAL_WEIGHT=0; DONE_WEIGHT=0; CUR=0; STEP_START=0

elapsed(){ local s=$(( $(date +%s)-START_TS )); printf '%02d:%02d' $((s/60)) $((s%60)); }
bar(){ local pct=$1; local w=32; local f=$(( pct*w/100 )); local out="[" i
       for ((i=0;i<w;i++)); do if ((i<f)); then out+="█"; else out+="·"; fi; done
       printf '%s] %3d%%' "$out" "$pct"; }
pctnow(){ echo $(( TOTAL_WEIGHT==0?0:DONE_WEIGHT*100/TOTAL_WEIGHT )); }
_w(){ printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || true; }
log(){ _w "[$(date +%T)] $*"; printf '  %s│%s %s\n' "$D" "$R" "$*"; }
ok(){ _w "[$(date +%T)] OK: $*"; printf '  %s│%s %s✓%s %s\n' "$D" "$R" "$GRN" "$R" "$*"; }
warn(){ _w "[$(date +%T)] UYARI: $*"; printf '  %s│%s %s!%s %s\n' "$D" "$R" "$YLW" "$R" "$*"; }
die(){ _w "[$(date +%T)] HATA: $*"
  printf '\n%s  ✖ HATA:%s %s\n  Ayrıntı: %s\n  Devam:   %sbash install.sh --resume%s\n\n' \
    "$RED" "$R" "$*" "$LOGFILE" "$B" "$R"; exit 1; }
trap 'die "beklenmedik hata — satır $LINENO"' ERR

sbegin(){ CUR=$1; STEP_START=$(date +%s)
  printf '\n%s┌─ [%d/%d] %s%s%s\n' "$BLU" $((CUR+1)) ${#STEP_KEYS[@]} "$B" "${STEP_NAME[$CUR]}" "$R"
  _w ""; _w "=== [$((CUR+1))/${#STEP_KEYS[@]}] ${STEP_NAME[$CUR]} ==="; }
send(){ DONE_WEIGHT=$((DONE_WEIGHT+${STEP_WEIGHT[$CUR]})); echo "${STEP_KEYS[$CUR]}" >>"$STATE"
  printf '%s└─%s %s  %s%ss · toplam %s · kalan %d adım%s\n' "$BLU" "$R" "$(bar "$(pctnow)")" \
    "$D" $(( $(date +%s)-STEP_START )) "$(elapsed)" $(( ${#STEP_KEYS[@]}-CUR-1 )) "$R"; }
sskip(){ DONE_WEIGHT=$((DONE_WEIGHT+${STEP_WEIGHT[$CUR]}))
  printf '%s┌─ [%d/%d] %s (atlandı)%s\n' "$D" $((CUR+1)) ${#STEP_KEYS[@]} "${STEP_NAME[$CUR]}" "$R"; }
did(){ [[ -f "$STATE" ]] && grep -qx "$1" "$STATE"; }

spin(){ local m="$1"; shift; local tmp; tmp=$(mktemp)
  ( "$@" >"$tmp" 2>&1 ) & local pid=$! mk='-\|/' i=0 t0=$(date +%s)
  while kill -0 $pid 2>/dev/null; do
    printf '\r  %s│%s %s %s %s(%ss)%s ' "$D" "$R" "${mk:i++%4:1}" "$m" "$D" $(( $(date +%s)-t0 )) "$R"; sleep 0.4
  done; wait $pid; local rc=$?; printf '\r\033[K'; cat "$tmp" >>"$LOGFILE"; rm -f "$tmp"; return $rc; }

# Uzun süren dış kurulumlar (curl|bash gibi) için. spin()'in aksine çıktıyı
# gizlemez: her satır loga tam, ekrana soluk ve kırpılmış düşer — dakikalarca
# süren bir adımda ne olduğu görünsün diye.
stream(){ local tag="$1"; shift
  _w "--- $tag başladı ---"
  "$@" 2>&1 | while IFS= read -r line; do
    _w "$line"
    printf '  %s│   %.110s%s\n' "$D" "$line" "$R"
  done
  local rc=${PIPESTATUS[0]}
  _w "--- $tag bitti (rc=$rc) ---"
  return "$rc"; }

wait_http(){ local u=$1 to=${2:-1800} l=${3:-servis} t=0
  while ! curl -sf "$u" >/dev/null 2>&1; do sleep 5; t=$((t+5))
    printf '\r  %s│%s ⏳ %s açılıyor… %ss %s(ilk açılışta GPU çekirdekleri derlenir)%s' "$D" "$R" "$l" "$t" "$D" "$R"
    (( t>=to )) && { printf '\n'; return 1; }; done
  printf '\r\033[K'; ok "$l hazır (${t}s)"; }

have(){ command -v "$1" >/dev/null 2>&1; }

APT_UPDATED=0
apt_up(){ (( APT_UPDATED )) && return 0; spin "paket listesi güncelleniyor" sudo apt-get update -qq; APT_UPDATED=1; }
apt_get(){ sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"; }

# Docker'ı çağırırken: kullanıcı docker grubuna yeni eklendiyse bu oturumda
# sokete erişemez; o durumda sudo ile devam ederiz (yeniden giriş gerekmesin).
DKR="docker"
detect_docker(){
  if docker info >/dev/null 2>&1; then DKR="docker"
  elif sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1; then DKR="sudo docker"
  else DKR=""; fi
}
dk(){ $DKR "$@"; }
# GB10'da "nvidia-smi --query-gpu=memory.*" çoğu sürümde "Not Supported" döner:
# bellek GPU'ya ayrılmış değil, CPU ile ortak. O durumda /proc/meminfo'ya düşeriz.
gpumem(){
  local out
  out="$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)"
  if [[ -n "$out" && "$out" != *"Not Supported"* && "$out" != *"[N/A]"* ]]; then
    echo "$out"; return
  fi
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
       END{ if(t>0) printf "%.1f / %.1f GiB (birleşik bellek)", (t-a)/1048576, t/1048576; else print "?" }' \
      /proc/meminfo 2>/dev/null || echo "?"
}

# Katman → gerçek model. Her adımda bu isimler ekrana yazılır ki hangi katmanın
# hangi modeli çalıştırdığı hiçbir noktada belirsiz kalmasın.
tier_repo(){ local v="${1^^}_REPO"; echo "${!v}"; }
tier_desc(){ case "$1" in
  haiku)  echo "hızlı Qwen · anlık cevap · commit mesajı" ;;
  sonnet) echo "hızlı NVIDIA · günlük iş · ~108 tok/s" ;;
  opus)   echo "Qwen kalite · ciddi kod (varsayılan)" ;;
  fable)  echo "NVIDIA ağır · en zor işler · tek başına" ;;
esac; }
tier_port(){ case "$1" in haiku) echo 8002;; sonnet) echo 8000;; opus) echo 8888;; fable) echo 8001;; esac; }
tier_size(){ case "$1" in haiku) echo "~25 GB";; sonnet) echo "~20 GB";; opus) echo "~20 GB";; fable) echo "~67 GB";; esac; }
DC(){ $DKR compose --env-file "$ENVF" -f "$CDIR/docker-compose.yml" "$@"; }

while [[ $# -gt 0 ]]; do case "$1" in
  --demo) DEMO=1; TIERS=(haiku sonnet) ;;
  --all)  WITH_FABLE=1; WITH_EXTRAS=1; WITH_WIKI=1; WITH_NEMOCLAW=1; WITH_SWAP=1; WITH_CANVAS=1; WITH_A2A=1 ;;
  --with-fable) WITH_FABLE=1 ;; --with-extras) WITH_EXTRAS=1 ;;
  --with-nemoclaw) WITH_NEMOCLAW=1 ;; --no-nemoclaw) WITH_NEMOCLAW=0 ;;
  --with-swap) WITH_SWAP=1 ;; --no-swap) WITH_SWAP=0 ;;
  --with-canvas) WITH_CANVAS=1 ;; --no-canvas) WITH_CANVAS=0 ;;
  --with-a2a) WITH_A2A=1 ;; --no-a2a) WITH_A2A=0 ;;
  --projects) shift; CANVAS_PROJECTS="${1:-}" ;; --projects=*) CANVAS_PROJECTS="${1#--projects=}" ;;
  --sandbox) shift; NEMOCLAW_SANDBOX="${1:-spark}" ;; --sandbox=*) NEMOCLAW_SANDBOX="${1#--sandbox=}" ;;
  --with-wiki) WITH_WIKI=1 ;; --vault) shift; OBSIDIAN_VAULT="${1:-}"; WITH_WIKI=1 ;;
  --vault=*) OBSIDIAN_VAULT="${1#--vault=}"; WITH_WIKI=1 ;;
  --resume) RESUME=1 ;; --token) shift; HF_TOKEN="${1:-}" ;; --token=*) HF_TOKEN="${1#--token=}" ;;
  --status) MODE=status ;; --uninstall) MODE=uninstall ;;
  -h|--help) sed -n '5,19p' "$0" | sed 's/^# \?//; s/ *#$//'; exit 0 ;;
  *) echo "bilinmeyen: $1"; exit 1 ;; esac; shift; done

if [[ "$MODE" == status ]]; then have spark && exec spark status || { echo "kurulum yok"; exit 1; }; fi

if [[ "$MODE" == uninstall ]]; then
  detect_docker
  printf '\n%s  Silinecek: tüm konteynerler + %s (modeller dahil)%s\n' "$YLW" "$AI_ROOT" "$R"
  read -rp "  Onaylıyorsan 'evet' yaz: " a; [[ "$a" == evet ]] || exit 0
  [[ -f "$CDIR/docker-compose.yml" ]] && DC --profile demo --profile daily --profile fable \
    --profile swap --profile canvas --profile a2a --profile extras --profile stt down -v 2>/dev/null || true
  detect_docker; dk ps -aq --filter name=sk- | xargs -r $DKR rm -f 2>/dev/null || true
  # NemoClaw kabını, OpenShell gateway'ini ve CLI'sini kendi kaldırıcısı siler.
  if have nemoclaw; then
    echo "  NemoClaw kaldırılıyor"
    nemoclaw uninstall --yes >/dev/null 2>&1 || echo "  ! olmadı — elle: nemoclaw uninstall --yes"
  fi
  sudo rm -rf "$AI_ROOT"; sudo rm -f /usr/local/bin/spark
  sed -i '/# >>> spark-stack >>>/,/# <<< spark-stack <<</d' ~/.bashrc
  echo "  silindi"; exit 0
fi

(( WITH_FABLE )) && STEP_WEIGHT[4]=90
(( DEMO ))       && STEP_WEIGHT[4]=25
for w in "${STEP_WEIGHT[@]}"; do TOTAL_WEIGHT=$((TOTAL_WEIGHT+w)); done

clear 2>/dev/null || true
cat <<BANNER
${B}${BLU}
   ▄▄▄▄▄ ▄▄▄▄  ▄▄▄  ▄▄▄▄  ▄   ▄     ▄▄▄▄▄▄▄▄  ▄▄▄  ▄▄▄▄ ▄   ▄
   █     █   █ █  █ █   █ █  █      █   █   █ █  █ █    █  █
   ▀▀▀▀█ ████  ████ ████  ██▀       ▀▀▀ █   █ ████ █    ██▀
   ▀▀▀▀▀ █     █  █ █  █  █ ▀▄      ▀▀▀ ▀   ▀ █  ▀ ▀▀▀▀ █ ▀▄
${R}
  ${D}v${VERSION} · $(date '+%d.%m.%Y %H:%M') · her şey konteynerde${R}

  ${B}KATMANLAR${R}
    ${B}haiku${R}   ~25 GB  :8002   Qwen3.6-35B-A3B          ${D}hızlı Qwen · anlık cevap${R}
    ${B}sonnet${R}  ~20 GB  :8000   Nemotron-3.5-Lightning   ${D}hızlı NVIDIA · ~108 tok/s${R}
$( ((DEMO)) && echo "    ${D}opus    (demo modunda atlandı — sonra: spark pull opus)${R}" \
            || echo "    ${B}opus${R}    ~20 GB  :8888   Qwen3.8-27B + MTP        ${D}Qwen kalite · varsayılan${R}" )
$( ((WITH_FABLE)) && echo "    ${B}fable${R}   ~67 GB  :8001   Nemotron-3-Super-120B    ${D}NVIDIA ağır · tek başına${R}" )
    ${B}kapı${R}     LiteLLM                   tek API adresi            :4000
$( ((WITH_EXTRAS)) && echo "    ${B}ekstra${R}   Open WebUI + Qdrant + Whisper                       :3000" )
$( ((WITH_WIKI))   && echo "    ${B}vault${R}    Obsidian + claude-obsidian (15 skill)" )
$( ((WITH_SWAP))   && echo "    ${B}swap${R}     llama-swap — katmanı istek anında açar, boştayı düşürür" )
$( ((WITH_CANVAS)) && echo "    ${B}canvas${R}   Agent Canvas — ajan kontrol merkezi + otomasyonlar   :8300" )
$( ((WITH_A2A))    && echo "    ${B}a2a${R}      A2A köprüsü — roller protokolle adreslenebilir      :8400" )
$( ((WITH_NEMOCLAW)) && echo "    ${B}nemoclaw${R} NVIDIA NemoClaw — ajan OpenShell kabında, model kapıdan" )

  ${B}İNDİRME${R}  $( ((DEMO)) && echo "~45 GB" || { ((WITH_FABLE)) && echo "~132 GB" || echo "~65 GB"; } )
  ${D}1 Gbit hatta $( ((DEMO)) && echo "15-20 dk" || { ((WITH_FABLE)) && echo "50-70 dk" || echo "30-40 dk"; } ) \
(indirme + ilk açılışta GPU çekirdeği derleme dahil)${R}
BANNER
printf '\n'
sudo -v || die "sudo gerekiyor"
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
sudo mkdir -p "$AI_ROOT" "$DATA" "$CDIR"; sudo chown -R "$USER:$USER" "$AI_ROOT"
touch "$LOGFILE"; [[ $RESUME == 1 ]] || : >"$STATE"
_w "════ spark-stack $VERSION · $(date) ════"

# ── 0 ÖN KONTROL ────────────────────────────────────────────────────────────
sbegin 0
[[ "$(uname -m)" == aarch64 ]] && ok "mimari aarch64" || warn "mimari $(uname -m) — Spark imajları uymayabilir"
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
  ok "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else
  warn "NVIDIA sürücüsü görünmüyor — sonraki adımda kurulacak"
fi
FREE=$(df -BG --output=avail "$AI_ROOT" | tail -1 | tr -dc '0-9')
NEED=$(( WITH_FABLE ? 200 : 100 ))
(( WITH_NEMOCLAW )) && NEED=$(( NEED + 10 ))    # OpenShell gateway + kap imajları
ok "boş disk ${FREE}GB (gereken ~${NEED}GB)"
(( FREE < NEED )) && die "disk yetersiz"
curl -sf https://huggingface.co >/dev/null || die "internet yok"

TOKSRC=""
[[ -n "${HF_TOKEN:-}" ]] && TOKSRC="komut satırı/ortam"
[[ -z "${HF_TOKEN:-}" && -f "$SRC_DIR/.env" ]] && { set -a; source "$SRC_DIR/.env"; set +a; [[ -n "${HF_TOKEN:-}" ]] && TOKSRC="./.env"; }
[[ -z "${HF_TOKEN:-}" && -f "$ENVF" ]] && { set -a; source "$ENVF"; set +a; [[ -n "${HF_TOKEN:-}" ]] && TOKSRC="kayıtlı"; }
if [[ -z "${HF_TOKEN:-}" || "$HF_TOKEN" == hf_xxx ]]; then
  cat <<TH

  ${B}HuggingFace anahtarı gerekiyor${R} (ücretsiz, modeller oradan iniyor)
    1) huggingface.co → üye ol / giriş yap
    2) Sağ üst profil → Settings → Access Tokens
    3) + Create new token → Type: ${B}Read${R} → Create
    4) ${B}hf_${R}… ile başlayan yazıyı kopyala, aşağıya yapıştır
  ${D}Yapıştırınca ekranda görünmez (güvenlik). Enter'a bas.${R}
  ${D}Sonraki sefer sormasın:  bash install.sh --token hf_xxx${R}

TH
  for t in 1 2 3; do
    read -rsp "  Anahtar (hf_...): " HF_TOKEN; echo
    HF_TOKEN="$(tr -d '[:space:]' <<<"${HF_TOKEN:-}")"
    [[ "$HF_TOKEN" == hf_* ]] && { TOKSRC="ekrandan"; break; }
    (( t<3 )) && warn "'hf_' ile başlamalı ($t/3)" || die "geçerli anahtar girilmedi"
  done
fi
HF_TOKEN="$(tr -d '[:space:]' <<<"$HF_TOKEN")"
curl -sf -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami-v2 >/tmp/.hfw 2>/dev/null \
  && ok "anahtar geçerli — $(jq -r '.name // "?"' /tmp/.hfw 2>/dev/null || echo ok) (kaynak: $TOKSRC)" \
  || die "anahtar reddedildi (süresi dolmuş ya da yanlış)"
rm -f /tmp/.hfw
send

# ── 1 DOCKER + GPU ALTYAPISI ────────────────────────────────────────────────
#  Makinede hiçbir şey olmadığı varsayımıyla çalışır:
#  temel paketler → NVIDIA sürücüsü → Docker Engine → NVIDIA Container Toolkit.
#  Zaten kurulu olanlar atlanır (DGX OS çoğunu hazır getirir).
sbegin 1


# 1.1 temel araçlar
MISSING=()
for p in curl ca-certificates gnupg jq git; do have "$p" || MISSING+=("$p"); done
# ca-certificates komut değil, dosya kontrolü
[[ -d /etc/ssl/certs ]] || MISSING+=(ca-certificates)
if (( ${#MISSING[@]} )); then
  apt_up; spin "temel paketler: ${MISSING[*]}" apt_get "${MISSING[@]}" || die "temel paketler kurulamadı"
fi
ok "temel araçlar hazır (curl, jq, git, gnupg)"

# 1.2 NVIDIA sürücüsü
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
  ok "NVIDIA sürücüsü: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
else
  warn "NVIDIA sürücüsü yok — kuruluyor (kurulum sonrası YENİDEN BAŞLATMA gerekir)"
  apt_up
  if apt-cache show nvidia-driver-580-open >/dev/null 2>&1; then DRV=nvidia-driver-580-open
  elif apt-cache show nvidia-driver-570-open >/dev/null 2>&1; then DRV=nvidia-driver-570-open
  else DRV=""; fi
  if [[ -n "$DRV" ]]; then
    spin "sürücü kuruluyor: $DRV" apt_get "$DRV" || die "sürücü kurulamadı"
    printf '\n%s  Sürücü kuruldu. Makineyi yeniden başlat, sonra devam et:%s\n\n    sudo reboot\n    cd %s && bash install.sh --resume\n\n' "$YLW" "$R" "$SRC_DIR"
    exit 0
  else
    die "uygun sürücü paketi bulunamadı — DGX OS güncel mi? 'sudo apt update && sudo apt full-upgrade' deneyip tekrar çalıştır"
  fi
fi

# 1.3 Docker Engine
if have docker && docker compose version >/dev/null 2>&1; then
  ok "docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) + compose v2 zaten kurulu"
else
  warn "Docker yok (ya da compose v2 eksik) — resmi depodan kuruluyor"
  sudo install -m0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg || die "docker anahtarı alınamadı"
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  APT_UPDATED=0; apt_up
  spin "docker kuruluyor" apt_get docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    || die "docker kurulamadı"
  sudo systemctl enable --now docker >/dev/null 2>&1 || true
  ok "docker kuruldu"
fi

# 1.4 kullanıcıyı docker grubuna ekle (bu oturumda etkili olmazsa sudo ile devam ederiz)
groups "$USER" | grep -qw docker || { sudo usermod -aG docker "$USER"; warn "docker grubuna eklendin — bu kurulum sudo ile devam edecek"; }
detect_docker
[[ -n "$DKR" ]] || die "docker çalışmıyor: 'sudo systemctl status docker' ile bak"
[[ "$DKR" == "sudo docker" ]] && log "not: bu oturumda 'sudo docker' kullanılıyor; yeni terminalde sudo'suz çalışacak"

# 1.5 NVIDIA Container Toolkit — konteynerlerin GPU'yu görmesi için
if dk info 2>/dev/null | grep -qi nvidia; then
  ok "NVIDIA Container Toolkit zaten yapılandırılmış"
else
  warn "NVIDIA Container Toolkit yok — kuruluyor"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    || die "nvidia anahtarı alınamadı"
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  APT_UPDATED=0; apt_up
  spin "nvidia-container-toolkit kuruluyor" apt_get nvidia-container-toolkit || die "toolkit kurulamadı"
  sudo nvidia-ctk runtime configure --runtime=docker >>"$LOGFILE" 2>&1 || die "nvidia-ctk yapılandırması başarısız"
  spin "docker yeniden başlatılıyor" sudo systemctl restart docker
  sleep 3; detect_docker
  ok "NVIDIA Container Toolkit kuruldu"
fi

# 1.6 gerçek test
spin "konteynerden GPU testi" dk run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L \
  || die "konteyner GPU'yu göremiyor — 'sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker' deneyip --resume"
ok "konteynerler GPU'yu görüyor"

sudo swapoff -a 2>/dev/null || true
ok "swap kapatıldı (birleşik bellekte kilitlenmeyi gizler)"
send

# ── 2 DOSYA DÜZENİ ──────────────────────────────────────────────────────────
sbegin 2
mkdir -p "$MODELS/hf" "$DATA"/{cache-haiku,cache-sonnet,cache-opus,cache-fable,webui,qdrant,canvas} \
         "$CDIR" "$AI_ROOT/bin"
cp "$SRC_DIR/docker-compose.yml" "$CDIR/"
[[ -f "$SRC_DIR/a2a/server.py" ]] && cp "$SRC_DIR/a2a/server.py" "$CDIR/a2a-server.py"
if [[ ! -f "$ENVF" ]]; then cp "$SRC_DIR/.env.example" "$ENVF"; fi
sed -i "s|^HF_TOKEN=.*|HF_TOKEN=$HF_TOKEN|; s|^AI_ROOT=.*|AI_ROOT=$AI_ROOT|" "$ENVF"
grep -q '^VLLM_IMAGE=' "$ENVF" || echo "VLLM_IMAGE=ghcr.io/aeon-7/aeon-vllm-ultimate:latest" >> "$ENVF"
# llama-swap sokete root olmadan erişsin diye host'un docker grup kimliği
DOCKER_GID="$(getent group docker | cut -d: -f3)"; DOCKER_GID="${DOCKER_GID:-999}"
sed -i '/^DOCKER_GID=/d' "$ENVF"; echo "DOCKER_GID=$DOCKER_GID" >> "$ENVF"

# Agent Canvas: kabı senin kullanıcı kimliğinle çalıştırıyoruz. Alternatifi,
# proje klasörünü kabın kullanıcısına devretmekti — o da senin kendi
# dosyalarına erişimini bozardı.
sed -i '/^CANVAS_UID=/d;/^CANVAS_GID=/d' "$ENVF"
printf 'CANVAS_UID=%s\nCANVAS_GID=%s\n' "$(id -u)" "$(id -g)" >> "$ENVF"
grep -q '^CANVAS_PROJECTS=' "$ENVF" \
  || echo "CANVAS_PROJECTS=${CANVAS_PROJECTS:-$HOME/projects}" >> "$ENVF"
# Vault yolu burada kesinleşir (bilgi tabanı adımı çok sonra geliyor) çünkü
# Canvas kabı onu salt-okunur bağlıyor ve compose'un yolu şimdiden bilmesi gerek.
VAULT_PATH="${OBSIDIAN_VAULT:-$HOME/vault}"
sed -i '/^OBSIDIAN_VAULT=/d' "$ENVF"; echo "OBSIDIAN_VAULT=$VAULT_PATH" >> "$ENVF"
mkdir -p "$VAULT_PATH"
# Ayarları ve sırları şifreleyen anahtar bir kez üretilir; kaybolursa kayıtlı
# kimlik bilgileri okunamaz hale gelir, o yüzden .env'de kalıcı tutuluyor.
rnd(){ openssl rand -hex "${1:-32}" 2>/dev/null || head -c"${1:-32}" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
grep -q '^OH_SECRET_KEY=' "$ENVF" || echo "OH_SECRET_KEY=$(rnd 32)" >> "$ENVF"
grep -q '^CANVAS_KEY='    "$ENVF" || echo "CANVAS_KEY=$(rnd 24)"    >> "$ENVF"
chmod 600 "$ENVF"
set -a; source "$ENVF"; set +a
sudo install -m0755 "$SRC_DIR/spark" /usr/local/bin/spark
ok "$CDIR hazır · 'spark' komutu kuruldu"
send

# ── 3 İMAJLAR ───────────────────────────────────────────────────────────────
sbegin 3
for img in "$VLLM_IMAGE" ghcr.io/berriai/litellm:main-latest; do
  spin "indiriliyor: ${img##*/}" dk pull "$img" && ok "${img##*/}" || die "imaj indirilemedi: $img"
done
if (( WITH_SWAP )); then
  SWAP_IMG="ghcr.io/mostlygeek/llama-swap:${LLAMASWAP_TAG:-unified-cuda13}"
  spin "indiriliyor: ${SWAP_IMG##*/}" dk pull "$SWAP_IMG" && ok "${SWAP_IMG##*/}" \
    || die "llama-swap imajı indirilemedi: $SWAP_IMG"
  # llama-swap'in Docker API istemcisi yok, komutu düz exec ediyor. Konteynerleri
  # başlatabilmesi için statik docker CLI ikilisi imajın içine bağlanır.
  if [[ -x "$AI_ROOT/bin/docker" ]]; then
    ok "docker CLI hazır ($("$AI_ROOT/bin/docker" --version 2>/dev/null | head -1 || echo '?'))"
  else
    DCLI_VER="${DOCKER_CLI_VERSION:-28.5.1}"; DCLI_ARCH="$(uname -m)"
    spin "statik docker CLI ($DCLI_VER · $DCLI_ARCH)" bash -c \
      "curl -fsSL 'https://download.docker.com/linux/static/stable/$DCLI_ARCH/docker-$DCLI_VER.tgz' \
       | tar -xz -C '$AI_ROOT/bin' --strip-components=1 docker/docker" \
      && chmod +x "$AI_ROOT/bin/docker" && ok "docker CLI indirildi" \
      || die "statik docker CLI indirilemedi — .env içinde DOCKER_CLI_VERSION dene"
  fi
fi
if (( WITH_CANVAS )); then
  CANVAS_IMG="ghcr.io/openhands/agent-canvas:${CANVAS_TAG:-1.19.0}"
  spin "indiriliyor: ${CANVAS_IMG##*/}" dk pull "$CANVAS_IMG" && ok "${CANVAS_IMG##*/}" \
    || die "Agent Canvas imajı indirilemedi: $CANVAS_IMG"
  mkdir -p "${CANVAS_PROJECTS:-$HOME/projects}"
  ok "proje klasörü: ${CANVAS_PROJECTS:-$HOME/projects}  (ajan yalnız burayı görür)"
fi
((WITH_EXTRAS)) && for img in ghcr.io/open-webui/open-webui:main qdrant/qdrant:latest; do
  spin "indiriliyor: ${img##*/}" dk pull "$img" || warn "$img indirilemedi"; done
send

# ── Model indirme yardımcısı ────────────────────────────────────────────────
#  Konteyner içinden indiriyoruz: makineye python/pip kurmuyoruz.
pull_model(){ # pull_model <katman>
  local t=$1 repo_var="${1^^}_REPO" repo
  repo="${!repo_var}"
  if [[ -f "$MODELS/$t/config.json" ]]; then
    ok "$t = $(tier_repo "$t") — zaten indirilmiş ($(du -sh "$MODELS/$t"|cut -f1))"; return 0; fi
  log "$t ← $repo  ($(tier_size "$t"))"
  log "   ayrı terminalden izle:  watch -n5 du -sh $MODELS/$t"
  dk run --rm -e HF_TOKEN="$HF_TOKEN" -e HF_HUB_ENABLE_HF_TRANSFER=1 \
    -v "$MODELS":/models --entrypoint bash "$VLLM_IMAGE" \
    -c "hf download '$repo' --local-dir /models/$t --max-workers ${HF_WORKERS:-16}" 2>&1 \
    | tee -a "$LOGFILE" | tail -1
  [[ -f "$MODELS/$t/config.json" ]] || die "$t indirilemedi ($repo)"
  ok "$t indi — $(du -sh "$MODELS/$t"|cut -f1)"

  # Spekülatif decode taslak modeli varsa (ör. sonnet için DSpark) onu da çek
  local draft_var="${1^^}_DRAFT" draft="${!draft_var:-}"
  if [[ -n "$draft" && ! -f "$MODELS/$t-draft/config.json" ]]; then
    log "$t taslak modeli ← $draft  (~1 GB)"
    dk run --rm -e HF_TOKEN="$HF_TOKEN" -e HF_HUB_ENABLE_HF_TRANSFER=1 \
      -v "$MODELS":/models --entrypoint bash "$VLLM_IMAGE" \
      -c "hf download '$draft' --local-dir /models/$t-draft --max-workers ${HF_WORKERS:-16}" 2>&1 \
      | tee -a "$LOGFILE" | tail -1
    [[ -f "$MODELS/$t-draft/config.json" ]] || die "$t taslak modeli indirilemedi ($draft)"
    ok "$t taslak indi — spekülatif decode aktif"
  fi
}

# ── 4 MODEL AĞIRLIKLARI ─────────────────────────────────────────────────────
#  Sıra önemli: küçükten büyüğe. Böylece ilk model erken hazır olur ve
#  büyükler inerken bile makine test edilebilir durumda olur.
sbegin 4
ALL_TIERS=("${TIERS[@]}"); ((WITH_FABLE)) && ALL_TIERS+=(fable)
printf '  %s│%s\n' "$D" "$R"
printf '  %s│  %-7s %-42s %-8s %s%s\n' "$D" "KATMAN" "MODEL" "BOYUT" "KULLANIM" "$R"
printf '  %s│  %-7s %-42s %-8s %s%s\n' "$D" "──────" "─────" "─────" "────────" "$R"
for t in "${ALL_TIERS[@]}"; do
  printf '  %s│%s  %s%-7s%s %-42s %-8s %s%s%s\n' "$D" "$R" "$B" "$t" "$R" \
    "$(tier_repo "$t")" "$(tier_size "$t")" "$D" "$(tier_desc "$t")" "$R"
done
printf '  %s│%s\n' "$D" "$R"
for t in "${ALL_TIERS[@]}"; do pull_model "$t"; done
log "toplam: $(du -sh "$MODELS" 2>/dev/null|cut -f1)"
send

# ── 5 KAPI AYARI ────────────────────────────────────────────────────────────
#  Kurulu olmayan katman da tanımlanır ama isteği kurulu bir katmana düşer.
#  Böylece "model bulunamadı" hatası yerine çalışan bir cevap gelir.
sbegin 5
FALLBACK_MAIN=opus; [[ " ${TIERS[*]} " == *" opus "* ]] || FALLBACK_MAIN=sonnet

# Kapı katmanlara doğrudan mı bakacak, yoksa llama-swap üzerinden mi? Tek fark
# adres: llama-swap varsa dört katman da onun arkasında, o da istek geldiğinde
# ilgili konteyneri açıyor.
tier_base(){
  if (( WITH_SWAP )); then echo "http://llamaswap:8080/v1"
  else echo "http://host.docker.internal:$(tier_port "$1")/v1"; fi
}
{
  echo "model_list:"
  for t in haiku sonnet opus fable; do
    cat <<YAML
  - model_name: $t
    litellm_params: {model: openai/$t, api_base: $(tier_base "$t"), api_key: x}
YAML
  done
  cat <<YAML
  # Araçlar "claude-sonnet-4-5" gibi isimler gönderirse ana modele düşsün
  - model_name: "claude-*"
    litellm_params: {model: openai/$FALLBACK_MAIN, api_base: $(tier_base "$FALLBACK_MAIN"), api_key: x}

litellm_settings: {drop_params: true, modify_params: true, request_timeout: 900, num_retries: 1}
router_settings:
  fallbacks:
    - fable: ["$FALLBACK_MAIN"]
    - opus: ["sonnet"]
    - haiku: ["sonnet"]
general_settings: {master_key: ${LITELLM_KEY:-sk-spark}}
YAML
} > "$CDIR/litellm.yaml"

# ── llama-swap ayarı ────────────────────────────────────────────────────────
#  Konteynerleri compose oluşturur, llama-swap yalnızca başlatıp durdurur:
#  bütün vLLM bayrakları docker-compose.yml ve .env içinde tek yerde kalır.
#  cmd düz exec edilir (kabuk yok), o yüzden komutlar tek satır ve sade.
if (( WITH_SWAP )); then
  SWAP_HEALTH="${SWAP_HEALTH_TIMEOUT:-2100}"   # ilk açılışta GPU çekirdeği derlenir
  SWAP_UNLOAD="${SWAP_UNLOAD_TIMEOUT:-60}"     # durdurmanın bitmesini bekle
  {
    cat <<YAML
# spark-stack — llama-swap ayarı (install.sh üretir; elle düzenleme, üzerine yazılır)
healthCheckTimeout: $SWAP_HEALTH
globalTTL: 0
unloadTimeout: $SWAP_UNLOAD

models:
YAML
    for t in haiku sonnet opus fable; do
      ttl_var="SWAP_TTL_${t^^}"
      cat <<YAML
  $t:
    cmd: docker start -a sk-$t
    cmdStop: docker stop -t 30 sk-$t
    proxy: http://$t:8000
    checkEndpoint: /v1/models
    ttl: ${!ttl_var:-${SWAP_TTL:-1800}}
YAML
    done
    cat <<YAML

# İlk üç katman birlikte durabilir; fable açılınca üçü de düşer, çünkü
# birleşik bellekte ikisi aynı anda sığmaz.
routing:
  router:
    use: group
    settings:
      groups:
        gunluk:
          swap: false
          exclusive: true
          members: [haiku, sonnet, opus]
        agir:
          swap: true
          exclusive: true
          members: [fable]
YAML
  } > "$CDIR/llamaswap.yaml"
  ok "llama-swap ayarı yazıldı — katmanlar istek anında açılacak"
  log "   ısınma payı ${SWAP_HEALTH}s · boşta düşme ${SWAP_TTL:-1800}s · kapı → llamaswap:8080"
fi

for t in haiku sonnet opus fable; do
  if [[ -f "$MODELS/$t/config.json" ]]; then
    ok "$t → $(tier_repo "$t")  :$(tier_port "$t")"
  else
    log "$t → kurulu değil, istek $FALLBACK_MAIN katmanına düşer"
  fi
done
send

# ── 6 SERVİSLER AÇILIYOR ────────────────────────────────────────────────────
#  Sıra: haiku (en hızlı açılan) → sonnet → opus. İlk ikisi açıldığında
#  sistem zaten kullanılabilir; opus arkadan yetişir.
sbegin 6
if (( WITH_SWAP )); then
  # Konteynerler oluşturulur ama başlatılmaz; açma işini llama-swap üstlenir.
  CREATE_PROFILES=(--profile demo --profile daily)
  (( WITH_FABLE )) && CREATE_PROFILES+=(--profile fable)
  spin "model konteynerleri oluşturuluyor (kapalı)" DC "${CREATE_PROFILES[@]}" create \
    || die "model konteynerleri oluşturulamadı"
  ok "konteynerler hazır ve kapalı — açmayı llama-swap üstlenecek"
  DC --profile swap up -d || die "kapı ve llama-swap açılmadı"
  wait_http "http://127.0.0.1:${SWAP_PORT:-8081}/health" 180 llama-swap || die "llama-swap açılmadı — spark logs llamaswap"
  wait_http http://127.0.0.1:4000/health/liveliness 300 kapı || die "kapı açılmadı"
  # İlk istek ısınmayı beklemesin diye ana katmanı burada açıyoruz. Claude Code
  # kendi zaman aşımına takılmasın diye bu bekleme kuruluma alındı.
  log "ana katman ısıtılıyor: $FALLBACK_MAIN — ilk açılışta GPU çekirdeği derlenir"
  if curl -s --max-time "${SWAP_HEALTH_TIMEOUT:-2100}" http://localhost:4000/v1/chat/completions \
       -H "Authorization: Bearer ${LITELLM_KEY:-sk-spark}" -H 'Content-Type: application/json' \
       -d "{\"model\":\"$FALLBACK_MAIN\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}]}" \
       >>"$LOGFILE" 2>&1; then
    ok "$FALLBACK_MAIN ısındı — bundan sonra /model <katman> yeter, spark up gerekmez"
  else
    warn "ilk ısıtma tamamlanmadı — 'spark ask \"merhaba\" $FALLBACK_MAIN' ile tekrar dene"
  fi
  log "   bellek: $(gpumem)"
else
  PROFILE=daily; (( DEMO )) && PROFILE=demo
  DC --profile "$PROFILE" up -d || die "servisler açılmadı"
  for t in "${TIERS[@]}"; do
    log "$t başlatılıyor — $(tier_repo "$t")"
    wait_http "http://127.0.0.1:$(tier_port "$t")/v1/models" 1800 "$t" || die "$t açılmadı — spark logs $t"
    log "   bellek: $(gpumem)"
  done
  wait_http http://127.0.0.1:4000/health/liveliness 300 kapı || die "kapı açılmadı"
fi
if (( WITH_CANVAS )); then
  CP="${CANVAS_PORT:-8300}"
  if DC --profile canvas up -d >>"$LOGFILE" 2>&1; then
    t=0
    # Kök yol SPA döndürüyor; 2xx/3xx/404 hepsi "ayakta" demek, 000 değil.
    until [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$CP/canvas" 2>/dev/null)" != 000 ]]; do
      sleep 5; t=$((t+5)); printf '\r  %s│%s ⏳ Agent Canvas açılıyor… %ss' "$D" "$R" "$t"
      (( t >= 180 )) && break
    done
    printf '\r\033[K'
    ok "Agent Canvas: http://localhost:$CP/canvas"
    log "   panel anahtarı (.env içinde CANVAS_KEY): ${CANVAS_KEY:-üretildi}"

    # ── Canvas'ı elle ayar gerektirmeyecek hale getir ────────────────────
    #  İki şey ayar API'sinden tohumlanıyor: modelin yerel kapıya bakması ve
    #  alt ajan devrinin açılması. İkincisi kritik — varsayılanı KAPALI ve
    #  kapalıyken devir aracı hiç yüklenmiyor, yani roller görev alamıyor.
    CAPI="http://127.0.0.1:$CP/api/settings"
    SEED=$(cat <<JSON
{"agent_settings_diff":{"enable_sub_agents":true,
 "llm":{"model":"litellm_proxy/$FALLBACK_MAIN","base_url":"http://litellm:4000","api_key":"${LITELLM_KEY:-sk-spark}"}}}
JSON
)
    if curl -sf -X PATCH "$CAPI" -H "X-Session-API-Key: ${CANVAS_KEY:-}" \
         -H 'Content-Type: application/json' -d "$SEED" >>"$LOGFILE" 2>&1; then
      # Yazdık demek yetmez; geri okuyup gerçekten oturmuş mu bakıyoruz.
      CCHK="$(curl -sf "$CAPI" -H "X-Session-API-Key: ${CANVAS_KEY:-}" 2>/dev/null \
              | jq -r '[(.. | objects | select(has("enable_sub_agents")) | .enable_sub_agents)] | first // "yok"' 2>/dev/null)"
      if [[ "$CCHK" == "true" ]]; then
        ok "Canvas ayarlandı — alt ajan devri AÇIK, model litellm_proxy/$FALLBACK_MAIN"
        log "   roller kendiliğinden yüklenir: spark-kod · spark-test · spark-denetci"
      else
        warn "ayar yazıldı ama doğrulanamadı (okunan: $CCHK) — 'spark canvas' ile bak"
      fi
    else
      warn "Canvas ayarı tohumlanamadı — panelden elle: Settings → Agent → Sub-agents açık,"
      log "   Settings → LLM: litellm_proxy/$FALLBACK_MAIN · http://litellm:4000 · ${LITELLM_KEY:-sk-spark}"
    fi
  else
    warn "Agent Canvas açılmadı — spark logs canvas"
  fi
fi
if (( WITH_A2A )); then
  AP="${A2A_PORT:-8400}"
  if DC --profile a2a up -d >>"$LOGFILE" 2>&1 && wait_http "http://127.0.0.1:$AP/health" 90 "A2A köprüsü"; then
    A2AR="$(curl -sf --max-time 10 "http://127.0.0.1:$AP/health" 2>/dev/null | jq -r '.roles|join(", ")' 2>/dev/null)"
    ok "A2A köprüsü: http://localhost:$AP/.well-known/agent-card.json"
    log "   protokolle açılan roller: ${A2AR:-?}"
  else
    warn "A2A köprüsü açılmadı — spark logs a2a"
  fi
fi
((WITH_EXTRAS)) && { DC --profile extras up -d && ok "Open WebUI: http://localhost:3000" || warn "ekstralar açılmadı"; }
send

# ── 7 CLAUDE CODE ───────────────────────────────────────────────────────────
sbegin 7
# Tek host kurulumu bu: Claude Code senin terminalinde çalışan bir CLI,
# konteynerde çalıştırmak dosya/git erişimini gereksiz zorlaştırırdı.
have claude || spin "Claude Code indiriliyor" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
export PATH="$HOME/.local/bin:$PATH"; have claude || die "claude komutu bulunamadı"
sed -i '/# >>> spark-stack >>>/,/# <<< spark-stack <<</d' ~/.bashrc
cat >> ~/.bashrc <<EOF
# >>> spark-stack >>>
export PATH="\$HOME/.local/bin:\$PATH"
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=${LITELLM_KEY:-sk-spark}
export ANTHROPIC_API_KEY=${LITELLM_KEY:-sk-spark}
export ANTHROPIC_DEFAULT_OPUS_MODEL=$FALLBACK_MAIN
export ANTHROPIC_DEFAULT_SONNET_MODEL=$FALLBACK_MAIN
export ANTHROPIC_DEFAULT_HAIKU_MODEL=haiku
export ANTHROPIC_MODEL=$FALLBACK_MAIN
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
# <<< spark-stack <<<
EOF
export ANTHROPIC_BASE_URL=http://localhost:4000 ANTHROPIC_AUTH_TOKEN="${LITELLM_KEY:-sk-spark}" ANTHROPIC_API_KEY="${LITELLM_KEY:-sk-spark}"
ok "Claude Code yerel kapıya bağlandı (bulut kapalı)"
send

# ── 8 MCP — hepsi konteyner ────────────────────────────────────────────────
sbegin 8
addmcp(){ local n=$1; shift
  if claude mcp list 2>/dev/null | grep -q "^$n"; then ok "$n (zaten ekli)"
  elif claude mcp add --scope user "$n" -- "$@" >>"$LOGFILE" 2>&1; then ok "$n"
  else warn "$n eklenemedi"; fi; }
# Docker MCP imajları: makineye node/python kurmuyoruz.
# Bu komutlar Claude Code ayarına kaydediliyor ve SONRA çalışacak — o zaman
# kullanıcı docker grubunda olacağı için düz 'docker' doğru (sudo değil).
addmcp filesystem docker run -i --rm --mount "type=bind,src=$HOME,dst=$HOME" mcp/filesystem "$HOME"
addmcp fetch      docker run -i --rm mcp/fetch
addmcp git        docker run -i --rm --mount "type=bind,src=$HOME,dst=$HOME" mcp/git
addmcp memory     docker run -i --rm -v "$DATA/mcp-memory:/app/dist" mcp/memory
addmcp sequential-thinking docker run -i --rm mcp/sequentialthinking
addmcp context7   docker run -i --rm mcp/context7
addmcp playwright docker run -i --rm --init --pull=always mcr.microsoft.com/playwright/mcp
for i in mcp/filesystem mcp/fetch mcp/git mcp/memory mcp/sequentialthinking mcp/context7 mcr.microsoft.com/playwright/mcp; do
  spin "MCP imajı: ${i##*/}" dk pull "$i" || warn "${i} indirilemedi"; done
send

# ── 9 SKILL'LER ────────────────────────────────────────────────────────────
sbegin 9
mkdir -p "$HOME/.claude/skills"
if claude plugin marketplace add obra/superpowers-marketplace >>"$LOGFILE" 2>&1 \
 && claude plugin install superpowers@superpowers-marketplace >>"$LOGFILE" 2>&1; then
  ok "superpowers eklentisi kuruldu"
else
  warn "eklenti CLI'si kullanılamadı — skill'ler kopyalanıyor"
  T=$(mktemp -d)
  if dk run --rm -v "$T:/out" alpine/git clone -q --depth 1 https://github.com/obra/superpowers /out/sp >>"$LOGFILE" 2>&1 \
     && [[ -d "$T/sp/skills" ]]; then
    cp -r "$T/sp/skills/." "$HOME/.claude/skills/" && ok "$(ls "$T/sp/skills"|wc -l) skill kopyalandı"
  else warn "superpowers alınamadı — sonra: /plugin install superpowers@superpowers-marketplace"; fi
  sudo rm -rf "$T"
fi
# ── Ortak sözleşme: kurallar vault'ta, roller ajanlarda ────────────────────
#  Kuralların metni tek yerde (bilgi tabanında) durur. Skill ve rol dosyaları
#  onun metnini KOPYALAMAZ, yerini gösterir — kopya eskir, tek kaynak eskimez.
#  Böylece bir kuralı vault'ta değiştirdiğinde host'taki Claude Code da, Agent
#  Canvas kabındaki ajan da aynı anda yeni kurala bağlanmış olur.
KURALLAR="$VAULT_PATH/kurallar"
if [[ -d "$SRC_DIR/roller" ]]; then
  mkdir -p "$KURALLAR"
  YENI=0
  for f in "$SRC_DIR/roller/kurallar/"*.md; do
    [[ -e "$f" ]] || continue
    if [[ -f "$KURALLAR/$(basename "$f")" ]]; then continue; fi
    cp "$f" "$KURALLAR/"; YENI=$((YENI+1))
  done
  if (( YENI )); then ok "kural taslakları bilgi tabanına kondu: $KURALLAR ($YENI dosya)"
  else ok "kurallar zaten var, üzerine yazılmadı: $KURALLAR"; fi

  # Skill: kuralların yerini söyler, metnini taşımaz
  mkdir -p "$HOME/.claude/skills/sirket-kurallari"
  sed "s|__KURALLAR__|$KURALLAR|g" "$SRC_DIR/roller/SKILL.md" \
    > "$HOME/.claude/skills/sirket-kurallari/SKILL.md"
  ok "skill: sirket-kurallari → $KURALLAR"

  # ── Roller: aynı kaynak, iki hedef ──────────────────────────────────────
  #  Host'taki Claude Code ile Agent Canvas rolleri aynı Markdown biçimini
  #  okuyor (frontmatter + gövde = sistem istemi). Ayrışan tek şey iki alan:
  #  kural yolu (host'ta ~/vault, kapta /vault) ve model adı (kapıda katman adı,
  #  Canvas'ta litellm_proxy/<katman>). O yüzden tek dosyadan iki sürüm üretiyoruz.
  mkdir -p "$HOME/.claude/agents"
  CANVAS_AGENTS="$DATA/canvas/agents"
  mkdir -p "$CANVAS_AGENTS"
  ROL=0
  for f in "$SRC_DIR/roller/agents/"*.md; do
    [[ -e "$f" ]] || continue
    # host: Claude Code katman adını doğrudan kullanır
    sed -e "s|__KURALLAR__|$KURALLAR|g" \
        -e "s|__MODEL_OPUS__|opus|g" -e "s|__MODEL_SONNET__|sonnet|g" \
        "$f" > "$HOME/.claude/agents/$(basename "$f")"
    # canvas: kapı üstünden litellm_proxy öneki, kural yolu kabın içindeki bağlama
    sed -e "s|__KURALLAR__|/vault/kurallar|g" \
        -e "s|__MODEL_OPUS__|litellm_proxy/opus|g" \
        -e "s|__MODEL_SONNET__|litellm_proxy/sonnet|g" \
        "$f" > "$CANVAS_AGENTS/$(basename "$f")"
    ROL=$((ROL+1))
  done
  ok "$ROL rol kuruldu — host: ~/.claude/agents · Canvas: $CANVAS_AGENTS"
  log "   Canvas her konuşmada bu dizini kendiliğinden tarar (~/.openhands/agents)"

  # Kural skill'i Canvas tarafında da dursun (yönlendiren ajan için)
  CSK="$DATA/canvas/skills/installed/sirket-kurallari"
  mkdir -p "$CSK"
  sed "s|__KURALLAR__|/vault/kurallar|g" "$SRC_DIR/roller/SKILL.md" > "$CSK/SKILL.md"
  ok "kural skill'i Canvas tarafına da yazıldı"

  # Proje notu: insan için sözleşme özeti (Canvas bunu OTOMATİK OKUMAZ)
  PROJ="${CANVAS_PROJECTS:-$HOME/projects}"
  mkdir -p "$PROJ"
  if [[ -f "$PROJ/AGENTS.md" ]]; then
    log "AGENTS.md zaten var, dokunulmadı: $PROJ/AGENTS.md"
  else
    cp "$SRC_DIR/roller/AGENTS.md" "$PROJ/AGENTS.md"
    ok "proje notu: $PROJ/AGENTS.md"
  fi
else
  warn "roller/ klasörü bulunamadı — kurallar ve roller kurulmadı"
fi
send

# ── 10 OBSIDIAN + BİLGİ TABANI ──────────────────────────────────────────────
#  AgriciDaniel/claude-obsidian: Claude Code eklentisi + 15 Agent Skill.
#  Kaynak at → Claude okur, bağlar, Obsidian vault'una kaydeder. Kanıt/alıntı
#  takibi yapar, BM25 ile arar (embedding gerekmez), düz Markdown bırakır.
#  Kod yazarken notlarına bakabilmen için: /claude-obsidian:wiki-query
sbegin 10
if (( WITH_WIKI == 0 )); then
  log "atlandı — sonradan:  bash install.sh --with-wiki --resume"
else
  PYV="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo 0)"
  if [[ "$(printf '%s\n3.11\n' "$PYV" | sort -V | head -1)" != "3.11" ]]; then
    warn "python3 $PYV < 3.11 — bilgi tabanı atlanıyor (claude-obsidian 3.11+ ister)"
  else
    ok "python3 $PYV"
    # ── Obsidian uygulaması (ARM64 AppImage) ──────────────────────────────
    #  Spark aarch64; Obsidian resmi .deb'i yalnız amd64 için var, ARM64 tarafında
    #  AppImage yayınlıyorlar. Onu /opt'a kurup menüye ve PATH'e ekliyoruz.
    #  Not: vault düz Markdown; Obsidian olmadan da her şey çalışır, uygulama
    #  sadece görsel gezinme (graph, canvas) için.
    if have obsidian; then
      ok "Obsidian zaten kurulu"
    else
      OBS_VER="$(curl -sf https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/desktop-releases.json | jq -r '.latestVersion // empty')"
      if [[ -z "$OBS_VER" ]]; then
        warn "Obsidian sürümü öğrenilemedi — uygulama atlanıyor (vault yine de çalışır)"
      else
        OBS_URL="https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBS_VER}/Obsidian-${OBS_VER}-arm64.AppImage"
        spin "libfuse2 kuruluyor (AppImage için)" apt_get libfuse2t64 || apt_get libfuse2 || warn "libfuse2 kurulamadı"
        sudo mkdir -p /opt/obsidian
        if spin "Obsidian $OBS_VER indiriliyor (ARM64 AppImage)" \
             sudo curl -fsSL -o /opt/obsidian/Obsidian.AppImage "$OBS_URL"; then
          sudo chmod +x /opt/obsidian/Obsidian.AppImage
          # PATH sarmalayıcı — AppImage'ı doğru bayraklarla açar
          sudo tee /usr/local/bin/obsidian >/dev/null <<'OBSEOF'
#!/usr/bin/env bash
# Obsidian (ARM64 AppImage). Argüman verilmezse varsayılan vault açılır.
exec /opt/obsidian/Obsidian.AppImage --no-sandbox "$@"
OBSEOF
          sudo chmod +x /usr/local/bin/obsidian
          # Uygulama menüsü girdisi
          sudo tee /usr/share/applications/obsidian.desktop >/dev/null <<'DESKEOF'
[Desktop Entry]
Name=Obsidian
Exec=/opt/obsidian/Obsidian.AppImage --no-sandbox %u
Terminal=false
Type=Application
Icon=obsidian
Categories=Office;
MimeType=x-scheme-handler/obsidian;
DESKEOF
          ok "Obsidian $OBS_VER kuruldu (komut: obsidian)"
          [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && \
            log "   masaüstü oturumu yok — uygulama şimdilik açılmaz, vault dosyaları yine çalışır"
        else
          warn "Obsidian indirilemedi — vault yine de çalışır"
        fi
      fi
    fi

    WIKI_DIR="$AI_ROOT/claude-obsidian"
    if [[ -d "$WIKI_DIR/.git" ]]; then spin "claude-obsidian güncelleniyor" git -C "$WIKI_DIR" pull -q || true
    else spin "claude-obsidian indiriliyor" git clone -q https://github.com/AgriciDaniel/claude-obsidian "$WIKI_DIR" || die "claude-obsidian indirilemedi"; fi
    ok "ürün: $WIKI_DIR ($(git -C "$WIKI_DIR" describe --tags --always 2>/dev/null || echo main))"

    # Kasa yolu: --vault ile verilmediyse varsayılan
    VAULT="${OBSIDIAN_VAULT:-$HOME/vault}"

    # init (yeni vault) mı adopt (mevcut Obsidian vault'u) mı?
    if [[ -f "$VAULT/.claude-obsidian.json" ]]; then
      ok "vault zaten hazır: $VAULT"
    else
      WOP="init"; [[ -d "$VAULT/.obsidian" ]] && WOP="adopt"
      log "vault hazırlanıyor ($WOP): $VAULT"
      # İki aşamalı onay: önce plan, plandaki sha256 ile uygula.
      # Bu projenin güvenlik sözleşmesi — hiçbir yazma onaysız yapılmaz.
      GEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; OPID="spark-stack-$(date +%s)"
      PLAN="$(cd "$WIKI_DIR" && python3 scripts/claude-obsidian.py "$WOP" "$VAULT" \
                --generated-at "$GEN" --operation-id "$OPID" 2>>"$LOGFILE")" || die "vault planı üretilemedi"
      echo "$PLAN" >>"$LOGFILE"
      SHA="$(jq -r '.approved_plan_sha256 // empty' <<<"$PLAN" 2>/dev/null)"
      [[ -n "$SHA" ]] || die "plan hash'i okunamadı — elle: cd $WIKI_DIR && python3 scripts/claude-obsidian.py $WOP $VAULT"
      log "plan onayı: ${SHA:0:16}…"
      (cd "$WIKI_DIR" && python3 scripts/claude-obsidian.py "$WOP" "$VAULT" \
         --generated-at "$GEN" --operation-id "$OPID" \
         --approved-plan-sha256 "$SHA" --apply) >>"$LOGFILE" 2>&1 || die "vault oluşturulamadı"
      ok "vault hazır: $VAULT"
    fi

    # 'wiki' komutu: vault'a girip Claude Code'u eklentiyle açar
    sudo tee /usr/local/bin/wiki >/dev/null <<WIKIEOF
#!/usr/bin/env bash
# wiki — vault'ta Claude Code aç (claude-obsidian eklentisiyle)
#   wiki            vault'u aç
#   wiki "soru"     vault'a soru sor (wiki-query)
cd "$VAULT" || { echo "vault bulunamadı: $VAULT"; exit 1; }
if [[ -n "\${1:-}" ]]; then
  exec claude --plugin-dir "$WIKI_DIR" "/claude-obsidian:wiki-query \$*"
else
  exec claude --plugin-dir "$WIKI_DIR"
fi
WIKIEOF
    sudo chmod +x /usr/local/bin/wiki
    ok "'wiki' komutu kuruldu"

    # Kod yazarken notlara bakabilmek için: vault'u MCP olarak ekle
    if claude mcp list 2>/dev/null | grep -q '^vault'; then ok "vault MCP zaten ekli"
    elif claude mcp add --scope user vault -- docker run -i --rm \
           --mount "type=bind,src=$VAULT,dst=$VAULT" mcp/filesystem "$VAULT" >>"$LOGFILE" 2>&1; then
      ok "vault MCP eklendi — her projede notlarına erişebilirsin"
    else warn "vault MCP eklenemedi"; fi

    sed -i '/^OBSIDIAN_VAULT=/d' "$ENVF"; echo "OBSIDIAN_VAULT=$VAULT" >> "$ENVF"
    log "kullanım:  wiki  ·  wiki \"soru\"  ·  obsidian  ·  kaynak at: $VAULT/inbox/"
  fi
fi
send

# ── 11 NEMOCLAW — yalıtılmış ajan kabı ──────────────────────────────────────
#  NVIDIA NemoClaw (Apache-2.0, github.com/NVIDIA/NemoClaw): ajanı OpenShell
#  sanal kabında çalıştırır, üstüne ağ politikası, anlık görüntü ve yaşam
#  döngüsü yönetimi koyar. Varsayılan ajanı OpenClaw.
#
#  Projenin "makineye tek şey kurulur" kuralından tek sapma burası: NemoClaw
#  yalnız kendi CLI'sini host'a bırakıyor (Node.js + ~/.local/bin/nemoclaw),
#  çünkü dağıtım biçimi bu. Ajanın kendisi, gateway ve kap yine konteynerde.
#
#  Model buluttan değil bizim kapımızdan gelir: LiteLLM :4000 OpenAI uyumlu uç
#  olarak kaydedilir. Anthropic uyumlu yol da var ama OpenClaw o yolda akışta
#  native tool_use/emit_ok doğrulaması arıyor; yerel modellerde kırılgan.
sbegin 11
if (( WITH_NEMOCLAW == 0 )); then
  log "atlandı — sonradan:  bash install.sh --with-nemoclaw --resume"
else
  NC_KEY="${LITELLM_KEY:-sk-spark}"
  NC_URL="http://localhost:4000/v1"
  log "kaynak : https://www.nvidia.com/nemoclaw.sh  (NVIDIA/NemoClaw · Apache-2.0)"
  log "kap    : $NEMOCLAW_SANDBOX"
  log "model  : $FALLBACK_MAIN  ←  $NC_URL"

  # Onboarding ucu gerçekten yokluyor; kapı kapalıysa orada takılır.
  if curl -sf --max-time 10 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
    ok "kapı ayakta — NemoClaw modeli doğrulayabilecek"
  else
    warn "kapı (:4000) cevap vermiyor — onboarding model doğrulamasında düşebilir"
  fi
  if have node; then log "node $(node -v 2>/dev/null || echo '?')  (NemoClaw en az v22.19 ister)"
  else log "node yok — NemoClaw kendi kuracak (nvm ile)"; fi

  export PATH="$HOME/.local/bin:$PATH"
  if have nemoclaw; then
    ok "nemoclaw zaten kurulu — $(nemoclaw --version 2>/dev/null | head -1 || echo '?')"
  else
    # HF_TOKEN bilerek geçilmiyor: yönetilen vLLM kullanmıyoruz, anahtarın
    # başka bir aracın durum dosyalarına yazılmasına gerek yok.
    # NEMOCLAW_SANDBOX_GPU=0: birleşik bellek zaten vLLM'de; çıkarım dışarıdan
    # geldiği için kabın GPU'ya ihtiyacı yok.
    nemoclaw_bootstrap(){
      curl -fsSL https://www.nvidia.com/nemoclaw.sh | env \
        NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
        NEMOCLAW_NON_INTERACTIVE=1 \
        NEMOCLAW_NO_EXPRESS=1 \
        NEMOCLAW_NON_INTERACTIVE_SUDO_MODE=prompt \
        NEMOCLAW_SANDBOX_NAME="$NEMOCLAW_SANDBOX" \
        NEMOCLAW_SANDBOX_GPU=0 \
        NEMOCLAW_PROVIDER=custom \
        NEMOCLAW_ENDPOINT_URL="$NC_URL" \
        NEMOCLAW_MODEL="$FALLBACK_MAIN" \
        COMPATIBLE_API_KEY="$NC_KEY" \
        bash -s -- --non-interactive --yes-i-accept-third-party-software
    }
    log "kuruluyor: Node.js + OpenShell + CLI + kap — çıktının tamamı $LOGFILE"
    if stream nemoclaw nemoclaw_bootstrap; then
      ok "NemoClaw kurulumu bitti"
    else
      warn "NemoClaw kurulumu tamamlanamadı — spark-stack'in geri kalanı etkilenmedi"
      log "elle:  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash   sonra:  nemoclaw onboard"
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if have nemoclaw; then
    ok "nemoclaw $(nemoclaw --version 2>/dev/null | head -1 || echo '?')"
    nemoclaw list --json >>"$LOGFILE" 2>&1 || true
    NC_DASH="$(nemoclaw "$NEMOCLAW_SANDBOX" dashboard-url --quiet 2>/dev/null | tr -d '\r' | head -1 || true)"
    if [[ -n "$NC_DASH" ]]; then ok "panel: $NC_DASH"
    else log "panel adresi sonra:  nemoclaw $NEMOCLAW_SANDBOX dashboard-url"; fi
    grep -q '^NEMOCLAW_SANDBOX=' "$ENVF" || echo "NEMOCLAW_SANDBOX=$NEMOCLAW_SANDBOX" >> "$ENVF"
    log "bağlan:  nemoclaw $NEMOCLAW_SANDBOX connect   ·   log:  nemoclaw $NEMOCLAW_SANDBOX logs --follow"
  else
    warn "nemoclaw komutu PATH'te yok — yeni terminal aç ya da logu oku: $LOGFILE"
  fi
fi
send

# ── 12 DOĞRULAMA ────────────────────────────────────────────────────────────
sbegin 12
RESP="$(curl -s --max-time 180 http://localhost:4000/v1/messages \
  -H "x-api-key: ${LITELLM_KEY:-sk-spark}" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d "{\"model\":\"$FALLBACK_MAIN\",\"max_tokens\":30,\"messages\":[{\"role\":\"user\",\"content\":\"Sadece OK yaz.\"}]}" \
  | jq -r '.content[0].text // .error.message // "cevap yok"')"
[[ "$RESP" == *OK* ]] && ok "uçtan uca çalışıyor (Claude Code → kapı → $FALLBACK_MAIN)" || warn "beklenmedik cevap: $RESP"
send

T=$(( $(date +%s)-START_TS ))
printf '\n%s%s╔════════════════════════════════════════════════════════════════╗%s\n' "$B" "$GRN" "$R"
printf   '%s%s║                   KURULUM TAMAMLANDI  ✓                        ║%s\n' "$B" "$GRN" "$R"
printf   '%s%s╚════════════════════════════════════════════════════════════════╝%s\n\n' "$B" "$GRN" "$R"
printf '  Süre     : %d dk %d sn\n  GPU      : %s\n  Modeller : %s\n  Log      : %s\n\n' \
  $((T/60)) $((T%60)) "$(gpumem)" "$(du -sh "$MODELS" 2>/dev/null|cut -f1)" "$LOGFILE"
cat <<FIN
  ${B}DENE${R}
      source ~/.bashrc
      mkdir ~/deneme && cd ~/deneme && claude
      ${D}> bana bir python hesap makinesi yaz${R}

  ${B}KATMANLAR${R}  (claude içinde /model <ad> ile geç)
      haiku    ${HAIKU_REPO}
               ${D}hızlı Qwen · anlık cevap · commit mesajı · :8002${R}
      sonnet   ${SONNET_REPO}
               ${D}hızlı NVIDIA · günlük iş · ~108 tok/s · :8000${R}
      opus     ${OPUS_REPO}
               ${D}Qwen kalite · ciddi kod · varsayılan · :8888${R}
      fable    ${FABLE_REPO}
               ${D}NVIDIA ağır · spark up fable (diğerlerini kapatır) · :8001${R}

  ${B}AGENT CANVAS${R}  (--with-canvas veya --all ile kurulduysa)
      http://localhost:${CANVAS_PORT:-8300}/canvas
      ${D}panel anahtarı: .env içindeki CANVAS_KEY${R}

      İlk açılışta Settings → LLM'e bir kez şunları gir (env ile ayarlanamıyor):
        Model     litellm_proxy/${FALLBACK_MAIN}
        Base URL  http://litellm:4000
        API Key   ${LITELLM_KEY:-sk-spark}

      Claude Code'u alt ajan yapmak için: Settings → Agent → Preset: Claude Code
      ${D}kap zaten bizim kapıya bakıyor (ANTHROPIC_BASE_URL), abonelik token'ı verme${R}

  ${B}A2A KÖPRÜSÜ${R}  (--with-a2a veya --all ile kurulduysa)
      curl localhost:${A2A_PORT:-8400}/.well-known/agent-card.json
      ${D}roller protokolle adreslenebilir; başka makineden de çağrılabilir${R}
      spark a2a                        kartı ve rolleri göster

  ${B}KATMAN DEĞİŞİMİ${R}  (--with-swap veya --all ile kurulduysa)
      claude içinde /model fable        katman istek anında açılır
      ${D}ilk açılış ~3-4 dk sürer; llama-swap çakışanları kendi kapatır${R}
      spark swap                       hangi katman ayakta, ne kadar boşta
      spark up swap                    llama-swap düzenini (yeniden) aç

  ${B}YÖNETİM${R}  (hepsi konteyner)
      spark status              ne çalışıyor, bellek, disk
      spark up demo             haiku + sonnet (hafif)
      spark up daily            haiku + sonnet + opus
      spark up fable            en güçlü model (diğerlerini kapatır)
      spark up extras           Open WebUI (:3000) + Qdrant
      spark logs opus           canlı log
      spark ask "merhaba"       hızlı test
      spark down                hepsini kapat

  ${B}BİLGİ TABANI${R}  (--with-wiki ile kurulduysa)
      wiki                      vault'ta Claude Code aç
      wiki "X nasıldı?"         vault'a soru sor
      obsidian                  Obsidian uygulamasını aç
      ~/vault/inbox/            kaynak at, sonra /claude-obsidian:wiki-ingest

  ${B}NEMOCLAW${R}  (--with-nemoclaw veya --all ile kurulduysa)
      nemoclaw ${NEMOCLAW_SANDBOX} connect        kaba bağlan, ajanı çalıştır
      nemoclaw ${NEMOCLAW_SANDBOX} logs --follow  canlı log
      nemoclaw ${NEMOCLAW_SANDBOX} dashboard-url  tarayıcı paneli
      nemoclaw ${NEMOCLAW_SANDBOX} status         kap, model, ağ politikası
      nemoclaw ${NEMOCLAW_SANDBOX} policy list    ağ politikası kuralları
      ${D}model kapıdan gelir: ${FALLBACK_MAIN} @ localhost:4000 — bulut yok${R}

FIN
(( DEMO )) && printf '  %sopus sonradan:%s spark pull opus && spark up daily\n' "$D" "$R"
((WITH_FABLE)) || printf '  %sfable sonradan:%s bash install.sh --with-fable --resume\n' "$D" "$R"
printf '\n'

