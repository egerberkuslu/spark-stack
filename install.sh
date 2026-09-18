#!/usr/bin/env bash
###############################################################################
#  spark-stack: DGX Spark yerel kod asistanı · Docker tabanlı kurulum         #
#                                                                             #
#    bash install.sh --demo             haiku + sonnet           ~45 GB       #
#    bash install.sh                    + opus                   ~65 GB       #
#    bash install.sh --all              dört katman + eklentiler ~132 GB      #
#                                                                             #
#    HER KURULUM HuggingFace anahtarı ister: modeller oradan iner.            #
#    Ücretsiz: huggingface.co → Settings → Access Tokens → Read               #
#    Komutla ver:  bash install.sh --all --token hf_xxx                       #
#    Vermezsen kurulum sorar; 'hf_' ile başlamayan değer kabul edilmez.       #
#                                                                             #
#    --token hf_xxx      HuggingFace anahtarını komutla ver                   #
#    --with-fable        dördüncü katman (en yüksek kalite)                   #
#    --with-extras       Open WebUI + Qdrant + Whisper                        #
#    --with-wiki         bilgi tabanı (varsayılan motor: obsidian)            #
#    --bilgi MOTOR       obsidian (kaynak→wiki) | graphify (kod→graf)         #
#    --with-nemoclaw     NVIDIA NemoClaw ajan kabı (--all dahil)              #
#    --with-swap         llama-swap: katmanı istek anında aç (--all dahil)    #
#    --with-canvas       Agent Canvas ajan kontrol merkezi (--all dahil)      #
#    --with-a2a          A2A köprüsü: rolleri protokolle aç (--all dahil)     #
#    --with-agency       agency-agents kataloğu + 15 uzman rol (--all dahil)  #
#    --projects PATH     Canvas ajanının göreceği klasör (vars. ~/projects)   #
#    --sandbox AD        NemoClaw kabının adı (varsayılan spark)              #
#    --no-<parça>        --all içinden çıkar: fable/swap/canvas/a2a/wiki      #
#    --vault PATH        vault yolu (varsayılan ~/vault)                      #
#    --resume            yarım kalan kurulumu sürdür                          #
#    --status            servis durumu     --uninstall   tümünü kaldır        #
#                                                                             #
#  Makineye kurulan tek şey: Claude Code (tek dosya CLI).                     #
#  Modeller, sunucular, veritabanları, MCP sunucuları: hepsi konteynerde.     #
###############################################################################
set -Eeuo pipefail
VERSION="3.1-yonetisim"
START_TS=$(date +%s)
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

AI_ROOT="${AI_ROOT:-/srv/ai}"
MODELS="$AI_ROOT/models"; DATA="$AI_ROOT/data"; CDIR="$AI_ROOT/compose"
FDIR="$AI_ROOT/qwen38-flash-dgx"   # Flash-Next reçetesi: yamalı imaj ve hazırlık betiği
STATE="$DATA/.state"; LOGFILE="$AI_ROOT/install.log"
ENVF="$CDIR/.env"
WITH_FABLE=0; WITH_EXTRAS=0; WITH_WIKI=0; WITH_NEMOCLAW=0; WITH_SWAP=0; WITH_CANVAS=0; WITH_A2A=0
# Bilgi tabanı motoru: iki farklı soruyu yanıtlarlar, biri seçilir.
#   obsidian  kaynak at → alıntılı wiki (claude-obsidian); insan kapılı, kaynak izi tutar
#   graphify  kod ve belge → sorgulanabilir graf; tree-sitter ile yerel ve deterministik
BILGI="${BILGI:-obsidian}"
WITH_AGENCY=0
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
           "MCP sunucuları" "Skill'ler" "Obsidian + bilgi tabanı" "NemoClaw ajan kabı" \
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
trap 'die "beklenmedik hata: satır $LINENO"' ERR

# ── Kesinti temizliği ──────────────────────────────────────────────────────
#  Ctrl+C'de arkada iş bırakmıyoruz. İki şey kaçabiliyordu: ilerlemeyi basan
#  alt süreç ve indirmeyi yapan konteyner. Docker istemcisini öldürmek
#  konteyneri durdurmaz, o yüzden konteynere ad veriyoruz ve burada adıyla
#  durduruyoruz. Çalışan alt süreç ve konteyner adı bu iki değişkende durur.
#  Uzun süren indirme ön planda değil arka planda koşup `wait` ile beklenir:
#  bash ön plandaki bir komut çalışırken trap işletmez, `wait` sırasında ise
#  işletir. Kesintiye anında tepki vermesinin şartı bu.
ARKA_PID=""; INDIR_KAP=""; ISLEM_PID=""
temizle(){
  trap - INT TERM HUP
  for pid in "$ISLEM_PID" "$ARKA_PID"; do
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  done
  ARKA_PID=""; ISLEM_PID=""
  kurulum_kilidi_birak
  printf '\r\033[K'
  printf '\n%s  Kesildi.%s\n' "$YLW" "$R"
  if [[ -n "$INDIR_KAP" ]] && [[ -n "${DKR:-}" ]] \
     && dk ps -q --filter "name=^${INDIR_KAP}$" 2>/dev/null | grep -q .; then
    printf '  indirme konteyneri durduruluyor: %s\n' "$INDIR_KAP"
    dk stop -t 5 "$INDIR_KAP" >/dev/null 2>&1
    dk rm -f "$INDIR_KAP" >/dev/null 2>&1
  fi
  INDIR_KAP=""
  # Kurulmuş servisler bilerek ayakta bırakılıyor: yarıda kesilen bir kurulumda
  # da kapı ve katmanlar çalışır durumda kalsın isteriz. Kapatmak istersen:
  printf '  yarım kalan yerden devam:  %sbash install.sh --resume%s\n' "$B" "$R"
  printf '  %sayakta kalan servisler:  spark status   ·  hepsini kapat:  spark down%s\n' "$D" "$R"
  printf '  %sbir imaj çekimi başladıysa Docker onu arka planda bitirir (zararsız, önbelleğe girer)%s\n\n' "$D" "$R"
  exit 130
}
trap temizle INT TERM HUP

# Kesilen bir önceki kurulumdan kalan indirme konteynerlerini kapatır. Yalnız
# bizim açtığımız adlara (sk-indir-*) dokunuyoruz; yarım inen dosyalara elimizi
# sürmüyoruz, çünkü hf download aynı klasöre tekrar koştuğunda kaldığı yerden
# devam ediyor. Başka bir kurulum aynı anda koşuyorsa onun indirmesini kesmemek
# için önce kilide bakıyoruz.
eski_indirme_kapat(){
  [[ -n "${DKR:-}" ]] || return 0
  local kaplar adet
  kaplar="$(dk ps -q --filter 'name=^sk-indir-' 2>/dev/null)"
  [[ -n "$kaplar" ]] || return 0
  adet="$(printf '%s\n' "$kaplar" | grep -c .)"
  if kurulum_kilidi_canli; then
    warn "$adet indirme sürüyor ama başka bir kurulum çalışıyor (PID $(cat "$KILIT" 2>/dev/null)), dokunulmadı"
    die "aynı anda iki kurulum çalıştırma; önce onu bitir ya da durdur"
  fi
  warn "önceki kurulumdan kalan $adet indirme konteyneri çalışıyor, kapatılıyor"
  dk ps --filter 'name=^sk-indir-' --format '{{.Names}}  {{.Status}}' 2>/dev/null \
    | while IFS= read -r satir; do [[ -n "$satir" ]] && log "   $satir"; done
  # shellcheck disable=SC2086  # kaplar birden çok kimlik taşır, bölünmesi gerek
  dk stop -t 10 $kaplar >>"$LOGFILE" 2>&1 || true
  # shellcheck disable=SC2086
  dk rm -f $kaplar >>"$LOGFILE" 2>&1 || true
  ok "kalan indirmeler durduruldu; yarım inen dosyalar duruyor, kurulum kaldığı yerden sürdürür"
}

# Kurulum kilidi: aynı anda iki kurulum .env ve konteynerler üzerinde çakışır.
KILIT="$AI_ROOT/install.pid"
kurulum_kilidi_canli(){
  local pid
  [[ -f "$KILIT" ]] || return 1
  pid="$(cat "$KILIT" 2>/dev/null)"
  [[ -n "$pid" && "$pid" != "$$" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # PID geri dönüşmüş olabilir: gerçekten install.sh mi
  grep -qa 'install\.sh' "/proc/$pid/cmdline" 2>/dev/null
}
kurulum_kilidi_birak(){
  [[ -f "$KILIT" && "$(cat "$KILIT" 2>/dev/null)" == "$$" ]] && rm -f "$KILIT"
  return 0
}
trap kurulum_kilidi_birak EXIT
kurulum_kilidi_al(){
  if kurulum_kilidi_canli; then
    die "başka bir kurulum çalışıyor (PID $(cat "$KILIT")); ikisi birden .env ve konteynerlere yazar"
  fi
  echo "$$" > "$KILIT" 2>/dev/null || true
}
# Adım içi iş sayacı: sbegin'in ikinci argümanı o adımda kaç iş olduğunu söyler
# (bayraklara göre hesaplanır), her iş başlamadan önce is "başlık" çağrılır.
# Sayaç bildirilenden fazla iş görürse toplamı büyütür, yani yanlış bir sayı
# yüzünden çıktı bozulmaz.
IS_TOPLAM=0; IS_SAYAC=0
sbegin(){ CUR=$1; IS_TOPLAM=${2:-0}; IS_SAYAC=0; STEP_START=$(date +%s)
  local ek=""; (( IS_TOPLAM )) && ek="$D · $IS_TOPLAM iş$R"
  printf '\n%s┌─ [%d/%d] %s%s%s%s\n' "$BLU" $((CUR+1)) ${#STEP_KEYS[@]} "$B" "${STEP_NAME[$CUR]}" "$R" "$ek"
  _w ""; _w "=== [$((CUR+1))/${#STEP_KEYS[@]}] ${STEP_NAME[$CUR]} (${IS_TOPLAM} iş) ==="; }
is(){ IS_SAYAC=$((IS_SAYAC+1)); (( IS_SAYAC > IS_TOPLAM )) && IS_TOPLAM=$IS_SAYAC
  printf '  %s│%s %s▸ [%d/%d]%s %s\n' "$D" "$R" "$B" "$IS_SAYAC" "$IS_TOPLAM" "$R" "$1"
  _w "-- iş [$IS_SAYAC/$IS_TOPLAM] $1"; }
send(){ DONE_WEIGHT=$((DONE_WEIGHT+${STEP_WEIGHT[$CUR]})); echo "${STEP_KEYS[$CUR]}" >>"$STATE"
  local isk=""; (( IS_TOPLAM )) && isk="$IS_SAYAC/$IS_TOPLAM iş · "
  printf '%s└─%s %s  %s%s%ss · toplam %s · kalan %d adım%s\n' "$BLU" "$R" "$(bar "$(pctnow)")" \
    "$D" "$isk" $(( $(date +%s)-STEP_START )) "$(elapsed)" $(( ${#STEP_KEYS[@]}-CUR-1 )) "$R"
  IS_TOPLAM=0; IS_SAYAC=0; }
# Not: --resume adım ATLAMAZ. Her adım kendi içinde yeniden çalıştırılabilir
# (indirilmiş ağırlık tekrar inmez, kurulu paket atlanır, var olan kural dosyası
# korunur) ve sonraki adımlar önceki adımların değişkenlerine bağlı olduğu için
# atlamak zaten yanlış olurdu. --resume yalnız durum dosyasını sıfırlamaz.

spin(){ local m="$1"; shift; local tmp; tmp=$(mktemp)
  ( "$@" >"$tmp" 2>&1 ) & local pid=$! mk='-\|/' i=0 t0; t0=$(date +%s)
  ARKA_PID=$pid
  while kill -0 $pid 2>/dev/null; do
    printf '\r  %s│%s %s %s %s(%ss)%s ' "$D" "$R" "${mk:i++%4:1}" "$m" "$D" $(( $(date +%s)-t0 )) "$R"; sleep 0.4
  done; wait $pid; local rc=$?; ARKA_PID=""
  printf '\r\033[K'; cat "$tmp" >>"$LOGFILE"; rm -f "$tmp"; return $rc; }

# Uzun süren dış kurulumlar (curl|bash gibi) için. spin()'in aksine çıktıyı
# gizlemez: her satır loga tam, ekrana soluk ve kırpılmış düşer; dakikalarca
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
  fable)  echo "Qwen Flash-Next · 6B aktif · çok kipli · tek başına" ;;
esac; }
tier_port(){ case "$1" in haiku) echo 8002;; sonnet) echo 8000;; opus) echo 8888;; fable) echo 8001;; esac; }
tier_size(){ case "$1" in haiku) echo "~27 GB";; sonnet) echo "~22 GB";; opus) echo "~23 GB";; fable) echo "~133 GB";; esac; }
DC(){ $DKR compose --env-file "$ENVF" -f "$CDIR/docker-compose.yml" "$@"; }

while [[ $# -gt 0 ]]; do case "$1" in
  --demo) DEMO=1; TIERS=(haiku sonnet) ;;
  --all)  WITH_FABLE=1; WITH_EXTRAS=1; WITH_WIKI=1; WITH_NEMOCLAW=1; WITH_SWAP=1
          WITH_CANVAS=1; WITH_A2A=1; WITH_AGENCY=1 ;;
  --with-fable) WITH_FABLE=1 ;; --no-fable) WITH_FABLE=0 ;;
  --with-extras) WITH_EXTRAS=1 ;; --no-extras) WITH_EXTRAS=0 ;;
  --no-wiki) WITH_WIKI=0 ;;
  --with-nemoclaw) WITH_NEMOCLAW=1 ;; --no-nemoclaw) WITH_NEMOCLAW=0 ;;
  --with-swap) WITH_SWAP=1 ;; --no-swap) WITH_SWAP=0 ;;
  --with-canvas) WITH_CANVAS=1 ;; --no-canvas) WITH_CANVAS=0 ;;
  --with-a2a) WITH_A2A=1 ;; --no-a2a) WITH_A2A=0 ;;
  --with-agency) WITH_AGENCY=1 ;; --no-agency) WITH_AGENCY=0 ;;
  --projects) shift; CANVAS_PROJECTS="${1:-}" ;; --projects=*) CANVAS_PROJECTS="${1#--projects=}" ;;
  --sandbox) shift; NEMOCLAW_SANDBOX="${1:-spark}" ;; --sandbox=*) NEMOCLAW_SANDBOX="${1#--sandbox=}" ;;
  --with-wiki) WITH_WIKI=1 ;; --vault) shift; OBSIDIAN_VAULT="${1:-}"; WITH_WIKI=1 ;;
  --bilgi) shift; BILGI="${1:-obsidian}"; WITH_WIKI=1 ;;
  --bilgi=*) BILGI="${1#--bilgi=}"; WITH_WIKI=1 ;;
  --with-graphify) BILGI=graphify; WITH_WIKI=1 ;;
  --vault=*) OBSIDIAN_VAULT="${1#--vault=}"; WITH_WIKI=1 ;;
  --resume) RESUME=1 ;; --token) shift; HF_TOKEN="${1:-}" ;; --token=*) HF_TOKEN="${1#--token=}" ;;
  --status) MODE=status ;; --uninstall) MODE=uninstall ;;
  -h|--help) sed -n '5,28p' "$0" | sed 's/^# \?//; s/ *#$//'; exit 0 ;;
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
    nemoclaw uninstall --yes >/dev/null 2>&1 || echo "  ! olmadı, elle: nemoclaw uninstall --yes"
  fi
  # Kurduğumuz rolleri ve skill'i geri alıyoruz. SENİN içeriğine dokunmuyoruz:
  # vault, kurallar ve proje klasörü olduğu gibi kalır, çünkü onlar senin yazdığın
  # şeyler, kurulumun ürettiği dosya değil.
  for r in spark-kod spark-test spark-denetci; do rm -f "$HOME/.claude/agents/$r.md"; done
  rm -f "$HOME/.claude/agents"/ajans-*.md
  rm -rf "$HOME/.claude/skills/sirket-kurallari" "$HOME/.claude/skills/graphify"
  echo "  roller ve sirket-kurallari skill'i kaldırıldı"
  [[ "$(git config --global core.hooksPath 2>/dev/null)" == "$AI_ROOT/denetim/hooks" ]] && git config --global --unset core.hooksPath
  sudo rm -rf "$AI_ROOT"; sudo rm -f /usr/local/bin/spark /usr/local/bin/wiki
  sed -i '/# >>> spark-stack >>>/,/# <<< spark-stack <<</d' ~/.bashrc
  VK="${OBSIDIAN_VAULT:-$HOME/vault}"
  echo "  silindi"
  echo
  echo "  Dokunulmayanlar (senin içeriğin):"
  [[ -d "$VK" ]] && echo "    $VK  (bilgi tabanı ve kurallar)"
  [[ -f "$HOME/projects/AGENTS.md" ]] && echo "    $HOME/projects  (projeler ve AGENTS.md)"
  echo
  exit 0
fi

case "$BILGI" in obsidian|graphify) ;; *) die "bilinmeyen bilgi tabanı motoru: $BILGI  (obsidian|graphify)" ;; esac
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
$( ((DEMO)) && echo "    ${D}opus    (demo modunda atlandı, sonra: spark pull opus)${R}" \
            || echo "    ${B}opus${R}    ~20 GB  :8888   Qwen3.8-27B + MTP        ${D}Qwen kalite · varsayılan${R}" )
$( ((WITH_FABLE)) && echo "    ${B}fable${R}   ~67 GB  :8001   Nemotron-3-Super-120B    ${D}NVIDIA ağır · tek başına${R}" )
    ${B}kapı${R}     LiteLLM                   tek API adresi            :4000
$( ((WITH_EXTRAS)) && echo "    ${B}ekstra${R}   Open WebUI + Qdrant + Whisper                       :3000" )
$( ((WITH_WIKI))   && { [[ "$BILGI" == graphify ]] \
     && echo "    ${B}graf${R}     graphify: kod ve belge → sorgulanabilir bilgi grafı" \
     || echo "    ${B}vault${R}    Obsidian + claude-obsidian (15 skill)"; } )
$( ((WITH_SWAP))   && echo "    ${B}swap${R}     llama-swap: katmanı istek anında açar, boştayı düşürür" )
$( ((WITH_CANVAS)) && echo "    ${B}canvas${R}   Agent Canvas: ajan kontrol merkezi + otomasyonlar    :8300" )
$( ((WITH_A2A))    && echo "    ${B}a2a${R}      A2A köprüsü: roller protokolle adreslenebilir       :8400" )
$( ((WITH_NEMOCLAW)) && echo "    ${B}nemoclaw${R} NVIDIA NemoClaw: ajan OpenShell kabında, model kapıdan" )

  ${B}İNDİRME${R}  $( ((DEMO)) && echo "~50 GB" || { ((WITH_FABLE)) && echo "~206 GB" || echo "~73 GB"; } )
  ${D}1 Gbit hatta $( ((DEMO)) && echo "15-20 dk" || { ((WITH_FABLE)) && echo "50-70 dk" || echo "30-40 dk"; } ) \
(indirme + ilk açılışta GPU çekirdeği derleme dahil)${R}
BANNER
printf '\n'
sudo -v || die "sudo gerekiyor"
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
sudo mkdir -p "$AI_ROOT" "$DATA" "$CDIR"
# Sahipliği kullanıcıya veriyoruz ama veritabanı dizinine DOKUNMUYORUZ.
# Postgres o dosyaları kendi kullanıcısıyla (kapta uid 70) açıyor; biz sahipliği
# çevirirsek ÇALIŞAN veritabanı kendi dosyalarını okuyamaz hale geliyor ve
# "PostgresError 42501: could not open file ... Permission denied" veriyor.
# Bu her --resume'da tekrarlanan sessiz bir bozma idi.
sudo find "$AI_ROOT" -path "$DATA/litellm-db" -prune -o -exec chown "$USER:$USER" {} +
# Daha önceki bir koşu bozduysa geri al: kaptaki postgres uid 70.
if [[ -d "$DATA/litellm-db" ]] && [[ "$(stat -c %u "$DATA/litellm-db" 2>/dev/null)" != 70 ]]; then
  sudo chown -R 70:70 "$DATA/litellm-db" 2>/dev/null \
    && warn "veritabanı dosyalarının sahipliği onarıldı (postgres uid 70)"
  DB_ONARILDI=1
fi
touch "$LOGFILE"; [[ $RESUME == 1 ]] || : >"$STATE"
_w "════ spark-stack $VERSION · $(date) ════"

# ── 0 ÖN KONTROL ────────────────────────────────────────────────────────────
sbegin 0 4
is "donanım: mimari ve GPU"
[[ "$(uname -m)" == aarch64 ]] && ok "mimari aarch64" || warn "mimari $(uname -m): Spark imajları uymayabilir"
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
  ok "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
else
  warn "NVIDIA sürücüsü görünmüyor: sonraki adımda kurulacak"
fi
is "disk ve ağ"
FREE=$(df -BG --output=avail "$AI_ROOT" | tail -1 | tr -dc '0-9')
NEED=$(( WITH_FABLE ? 290 : 130 ))
(( WITH_NEMOCLAW )) && NEED=$(( NEED + 10 ))    # OpenShell gateway + kap imajları
ok "boş disk ${FREE}GB (gereken ~${NEED}GB)"
(( FREE < NEED )) && die "disk yetersiz"
curl -sf https://huggingface.co >/dev/null || die "internet yok"

# Port çakışması: kurulumun ortasında anlaşılmaz bir hatayla düşmek yerine
# burada söyleyelim. Yalnız kuracağımız parçaların portlarına bakıyoruz.
is "port çakışması"
port_busy(){ (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&-; return 0; } || return 1; }
PORT_LIST=("4000:kapı" "8000:sonnet" "8002:haiku")
[[ " ${TIERS[*]} " == *" opus "* ]] && PORT_LIST+=("8888:opus")
(( WITH_FABLE ))   && PORT_LIST+=("8001:fable")
(( WITH_SWAP ))    && PORT_LIST+=("${SWAP_PORT:-8081}:llama-swap")
(( WITH_CANVAS ))  && PORT_LIST+=("${CANVAS_PORT:-8300}:Agent Canvas")
(( WITH_A2A ))     && PORT_LIST+=("${A2A_PORT:-8400}:A2A köprüsü")
(( WITH_EXTRAS ))  && PORT_LIST+=("3000:Open WebUI" "6333:Qdrant")
(( WITH_NEMOCLAW )) && PORT_LIST+=("8080:NemoClaw gateway")
DOLU=()
for spec in "${PORT_LIST[@]}"; do
  if port_busy "${spec%%:*}"; then DOLU+=("${spec%%:*} (${spec#*:})"); fi
done
if (( ${#DOLU[@]} )); then
  warn "şu portlar şu an dolu: ${DOLU[*]}"
  log "   kurulumun kendi konteynerleriyse sorun değil; başka bir şeyse çakışacak"
  log "   bakmak için:  ss -ltnp | grep -E '$(printf '%s|' "${DOLU[@]%% *}" | sed 's/|$//')'"
else
  ok "gereken portlar boş (${#PORT_LIST[@]} port kontrol edildi)"
fi

is "HuggingFace anahtarı"
TOKSRC=""
[[ -n "${HF_TOKEN:-}" ]] && TOKSRC="komut satırı/ortam"
# shellcheck source=/dev/null
[[ -z "${HF_TOKEN:-}" && -f "$SRC_DIR/.env" ]] && { set -a; source "$SRC_DIR/.env"; set +a; [[ -n "${HF_TOKEN:-}" ]] && TOKSRC="./.env"; }
# shellcheck source=/dev/null
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
  && ok "anahtar geçerli: $(jq -r '.name // "?"' /tmp/.hfw 2>/dev/null || echo ok) (kaynak: $TOKSRC)" \
  || die "anahtar reddedildi (süresi dolmuş ya da yanlış)"
rm -f /tmp/.hfw
send

# ── 1 DOCKER + GPU ALTYAPISI ────────────────────────────────────────────────
#  Makinede hiçbir şey olmadığı varsayımıyla çalışır:
#  temel paketler → NVIDIA sürücüsü → Docker Engine → NVIDIA Container Toolkit.
#  Zaten kurulu olanlar atlanır (DGX OS çoğunu hazır getirir).
sbegin 1 6

# 1.1 temel araçlar
is "temel araçlar (curl, jq, git, gnupg)"
MISSING=()
for p in curl ca-certificates gnupg jq git; do have "$p" || MISSING+=("$p"); done
# ca-certificates komut değil, dosya kontrolü
[[ -d /etc/ssl/certs ]] || MISSING+=(ca-certificates)
if (( ${#MISSING[@]} )); then
  apt_up; spin "temel paketler: ${MISSING[*]}" apt_get "${MISSING[@]}" || die "temel paketler kurulamadı"
fi
ok "temel araçlar hazır (curl, jq, git, gnupg)"

# 1.2 NVIDIA sürücüsü
is "NVIDIA sürücüsü"
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
  ok "NVIDIA sürücüsü: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
else
  warn "NVIDIA sürücüsü yok: kuruluyor (kurulum sonrası YENİDEN BAŞLATMA gerekir)"
  apt_up
  if apt-cache show nvidia-driver-580-open >/dev/null 2>&1; then DRV=nvidia-driver-580-open
  elif apt-cache show nvidia-driver-570-open >/dev/null 2>&1; then DRV=nvidia-driver-570-open
  else DRV=""; fi
  if [[ -n "$DRV" ]]; then
    spin "sürücü kuruluyor: $DRV" apt_get "$DRV" || die "sürücü kurulamadı"
    printf '\n%s  Sürücü kuruldu. Makineyi yeniden başlat, sonra devam et:%s\n\n    sudo reboot\n    cd %s && bash install.sh --resume\n\n' "$YLW" "$R" "$SRC_DIR"
    exit 0
  else
    die "uygun sürücü paketi bulunamadı: DGX OS güncel mi? 'sudo apt update && sudo apt full-upgrade' deneyip tekrar çalıştır"
  fi
fi

# 1.3 Docker Engine
is "Docker Engine + compose v2"
if have docker && docker compose version >/dev/null 2>&1; then
  ok "docker $(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1) + compose v2 zaten kurulu"
else
  warn "Docker yok (ya da compose v2 eksik): resmi depodan kuruluyor"
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
is "docker erişimi"
groups "$USER" | grep -qw docker || { sudo usermod -aG docker "$USER"; warn "docker grubuna eklendin: bu kurulum sudo ile devam edecek"; }
detect_docker
[[ -n "$DKR" ]] || die "docker çalışmıyor: 'sudo systemctl status docker' ile bak"
[[ "$DKR" == "sudo docker" ]] && log "not: bu oturumda 'sudo docker' kullanılıyor; yeni terminalde sudo'suz çalışacak"
# Kurulum ya da --resume: kesilen bir koşudan kalan indirme varsa burada kapanır
kurulum_kilidi_al
eski_indirme_kapat

# 1.5 NVIDIA Container Toolkit: konteynerlerin GPU'yu görmesi için
is "NVIDIA Container Toolkit"
if dk info 2>/dev/null | grep -qi nvidia; then
  ok "NVIDIA Container Toolkit zaten yapılandırılmış"
else
  warn "NVIDIA Container Toolkit yok: kuruluyor"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    || die "nvidia anahtarı alınamadı"
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  APT_UPDATED=0; apt_up
  spin "nvidia-container-toolkit kuruluyor" apt_get nvidia-container-toolkit || die "toolkit kurulamadı"
  # shellcheck disable=SC2024  # log dosyası kullanıcıya ait, sudo yönlendirmeyi etkilemese de olur
  sudo nvidia-ctk runtime configure --runtime=docker >>"$LOGFILE" 2>&1 || die "nvidia-ctk yapılandırması başarısız"
  spin "docker yeniden başlatılıyor" sudo systemctl restart docker
  sleep 3; detect_docker
  ok "NVIDIA Container Toolkit kuruldu"
fi

# 1.6 gerçek test
is "konteynerden GPU testi"
spin "konteynerden GPU testi" dk run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi -L \
  || die "konteyner GPU'yu göremiyor: 'sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker' deneyip --resume"
ok "konteynerler GPU'yu görüyor"

sudo swapoff -a 2>/dev/null || true
ok "swap kapatıldı (birleşik bellekte kilitlenmeyi gizler)"
send

# ── 2 DOSYA DÜZENİ ──────────────────────────────────────────────────────────
sbegin 2 $(( 6 + WITH_AGENCY ))
is "dizinler, compose ve .env"
mkdir -p "$MODELS/hf" "$DATA"/{cache-haiku,cache-sonnet,cache-opus,cache-fable,webui,qdrant,canvas} \
         "$CDIR" "$AI_ROOT/bin"
cp "$SRC_DIR/docker-compose.yml" "$CDIR/"
[[ -f "$SRC_DIR/a2a/server.py" ]] && cp "$SRC_DIR/a2a/server.py" "$CDIR/a2a-server.py"
[[ -f "$SRC_DIR/roller/uyarla.py" ]] && cp "$SRC_DIR/roller/uyarla.py" "$CDIR/uyarla.py"
[[ -f "$SRC_DIR/roller/skill-birlestir.sh" ]] && cp "$SRC_DIR/roller/skill-birlestir.sh" "$CDIR/skill-birlestir.sh"
if [[ ! -f "$ENVF" ]]; then cp "$SRC_DIR/.env.example" "$ENVF"; fi
sed -i "s|^HF_TOKEN=.*|HF_TOKEN=$HF_TOKEN|; s|^AI_ROOT=.*|AI_ROOT=$AI_ROOT|" "$ENVF"
grep -q '^VLLM_IMAGE=' "$ENVF" || echo "VLLM_IMAGE=ghcr.io/aeon-7/aeon-vllm-ultimate:latest" >> "$ENVF"
# llama-swap sokete root olmadan erişsin diye host'un docker grup kimliği
DOCKER_GID="$(getent group docker | cut -d: -f3)"; DOCKER_GID="${DOCKER_GID:-999}"
sed -i '/^DOCKER_GID=/d' "$ENVF"; echo "DOCKER_GID=$DOCKER_GID" >> "$ENVF"

# Agent Canvas: kabı senin kullanıcı kimliğinle çalıştırıyoruz. Alternatifi,
# proje klasörünü kabın kullanıcısına devretmekti, o da senin kendi
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
grep -q '^LITELLM_DB_PASSWORD=' "$ENVF" || echo "LITELLM_DB_PASSWORD=$(rnd 24)" >> "$ENVF"
grep -q '^LITELLM_SALT_KEY='    "$ENVF" || echo "LITELLM_SALT_KEY=sk-salt-$(rnd 24)" >> "$ENVF"

# ── Mevcut .env'i yeni anahtarlarla tamamla ────────────────────────────────
#  Var olan bir kurulumda .env korunuyor (senin değerlerin duruyor), ama yeni
#  sürümün getirdiği anahtarlar orada olmaz. Eksikleri .env.example'daki
#  değerle ekliyoruz; tek kaynak orası, burada değer tekrarlamıyoruz.
env_tamamla(){
  local a v
  for a in "$@"; do
    grep -q "^$a=" "$ENVF" && continue
    v="$(grep -m1 "^$a=" "$SRC_DIR/.env.example" 2>/dev/null || true)"
    [[ -n "$v" ]] && { printf '%s\n' "$v" >> "$ENVF"; log "   .env'e eklendi: $a"; }
  done
}
env_tamamla FABLE_REPO FABLE_MEM FABLE_CTX FABLE_SEQS FABLE_RESIDENT_GB \
            FABLE_HYBRID FABLE_PLE_WORKERS FABLE_PLE_MADVISE FABLE_PLE_PREWARM

# fable modeli değişti: eski varsayılanı kullananları yeni varsayılana taşıyoruz.
# Kendi modelini seçmiş olanın tercihine dokunmuyoruz, yalnız durumu söylüyoruz.
FABLE_ESKI="nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4"
FABLE_YENI="$(grep -m1 '^FABLE_REPO=' "$SRC_DIR/.env.example" 2>/dev/null | cut -d= -f2-)"
FABLE_SIMDI="$(grep -m1 '^FABLE_REPO=' "$ENVF" 2>/dev/null | cut -d= -f2-)"
if [[ -n "$FABLE_YENI" && "$FABLE_SIMDI" == "$FABLE_ESKI" ]]; then
  sed -i "s|^FABLE_REPO=.*|FABLE_REPO=$FABLE_YENI|" "$ENVF"
  sed -i "s|^FABLE_MEM=.*|FABLE_MEM=0.80|; s|^FABLE_CTX=.*|FABLE_CTX=262144|" "$ENVF"
  warn "fable modeli güncellendi: Nemotron-3-Super → ${FABLE_YENI##*/}"
  log "   eskisine dönmek istersen .env içinde FABLE_REPO=$FABLE_ESKI yaz"
elif [[ -n "$FABLE_SIMDI" && "$FABLE_SIMDI" != "$FABLE_YENI" ]]; then
  log "fable modeli senin seçtiğin gibi bırakıldı: ${FABLE_SIMDI##*/}"
fi
# fable imajı modele göre: Flash-Next yamalı imaj ister, diğerleri stok vLLM.
# Flash-Next'e özgü ayarlar da başka bir modele geçildiyse temizlenir.
FABLE_SIMDI="$(grep -m1 '^FABLE_REPO=' "$ENVF" 2>/dev/null | cut -d= -f2-)"
sed -i '/^FABLE_IMAGE=/d' "$ENVF"
if [[ "$FABLE_SIMDI" == *Flash-Next* ]]; then
  echo "FABLE_IMAGE=${FABLE_IMAGE:-qwen38-flash-dgx:latest}" >> "$ENVF"
else
  echo "FABLE_IMAGE=${VLLM_IMAGE:-ghcr.io/aeon-7/aeon-vllm-ultimate:latest}" >> "$ENVF"
  sed -i '/^FABLE_SNAPSHOT=/d;/^FABLE_FP8_HYBRID=/d;/^FABLE_DEEP_GEMM=/d' "$ENVF"
  sed -i '/^FABLE_PLE_MMAP=/d;/^FABLE_DET_TOPK=/d;/^FABLE_DET_LIB=/d;/^FABLE_DRAFT_VOCAB=/d' "$ENVF"
fi
chmod 600 "$ENVF"
set -a
# shellcheck source=/dev/null
source "$ENVF"
set +a
# ── Ortak sözleşme: kurallar vault'ta, roller ajanlarda ────────────────────
#  Kuralların metni tek yerde (bilgi tabanında) durur. Skill ve rol dosyaları
#  onun metnini KOPYALAMAZ, yerini gösterir: kopya eskir, tek kaynak eskimez.
#  Böylece bir kuralı vault'ta değiştirdiğinde host'taki Claude Code da, Agent
#  Canvas kabındaki ajan da aynı anda yeni kurala bağlanmış olur.
KURALLAR="$VAULT_PATH/kurallar"
if [[ -d "$SRC_DIR/roller" ]]; then
  is "şirket kuralları ve denetim ayarı"
  mkdir -p "$KURALLAR"
  YENI=0
  for f in "$SRC_DIR/roller/kurallar/"*.md; do
    [[ -e "$f" ]] || continue
    if [[ -f "$KURALLAR/$(basename "$f")" ]]; then continue; fi
    cp "$f" "$KURALLAR/"; YENI=$((YENI+1))
  done
  if (( YENI )); then ok "kural taslakları bilgi tabanına kondu: $KURALLAR ($YENI dosya)"
  else ok "kurallar zaten var, üzerine yazılmadı: $KURALLAR"; fi
  # Mekanik denetim ayarı kuralların yanında durur: kural değişince o da orada değişir
  mkdir -p "$KURALLAR/denetim"
  [[ -f "$KURALLAR/denetim/ruff.toml" ]] || cp "$SRC_DIR/roller/kurallar/denetim/ruff.toml" "$KURALLAR/denetim/"

  is "roller ve kural skill'i (host + Canvas)"
  # Skill: kuralların yerini söyler, metnini taşımaz
  mkdir -p "$HOME/.claude/skills/sirket-kurallari"
  sed -e "s|__KURALLAR__|$KURALLAR|g" -e "s|__VAULT__|$VAULT_PATH|g" "$SRC_DIR/roller/SKILL.md" \
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
    sed -e "s|__KURALLAR__|$KURALLAR|g" -e "s|__VAULT__|$VAULT_PATH|g" \
        -e "s|__MODEL_OPUS__|opus|g" -e "s|__MODEL_SONNET__|sonnet|g" \
        "$f" > "$HOME/.claude/agents/$(basename "$f")"
    # canvas: kapı üstünden litellm_proxy öneki, kural yolu kabın içindeki bağlama
    sed -e "s|__KURALLAR__|/vault/kurallar|g" -e "s|__VAULT__|/vault|g" \
        -e "s|__MODEL_OPUS__|litellm_proxy/opus|g" \
        -e "s|__MODEL_SONNET__|litellm_proxy/sonnet|g" \
        "$f" > "$CANVAS_AGENTS/$(basename "$f")"
    ROL=$((ROL+1))
  done
  ok "$ROL rol kuruldu, host: ~/.claude/agents · Canvas: $CANVAS_AGENTS"
  log "   Canvas her konuşmada bu dizini kendiliğinden tarar (~/.openhands/agents)"

  # ── Kural kapısı: kurallar mekanik olarak zorlanır ────────────────────────
  #  Git kancaları (pre-commit, commit-msg, pre-push) ve PR kapısı. Makinedeki
  #  her depo core.hooksPath ile kapıdan geçer; Canvas kabı aynı dizini
  #  /opt/spark-denetim olarak görür, ruff ve shellcheck ikilileri oradadır.
  is "kural kapısı: git kancaları ve araçlar"
  if bash "$SRC_DIR/roller/denetim/kur.sh" "$AI_ROOT" "$SRC_DIR/roller/denetim" >>"$LOGFILE" 2>&1; then
    ok "kural kapısı kuruldu, git kancaları: $AI_ROOT/denetim/hooks (core.hooksPath)"
    log "   PR kapısı: spark kural pr · projeye CI: spark kural kur <proje>"
  else
    warn "kural kapısı kurulamadı, sonra: bash $SRC_DIR/roller/denetim/kur.sh $AI_ROOT $SRC_DIR/roller/denetim"
  fi

  # Kural skill'i Canvas tarafında da dursun (yönlendiren ajan için)
  CSK="$DATA/canvas/skills/installed/sirket-kurallari"
  mkdir -p "$CSK"
  sed -e "s|__KURALLAR__|/vault/kurallar|g" -e "s|__VAULT__|/vault|g" "$SRC_DIR/roller/SKILL.md" > "$CSK/SKILL.md"
  ok "kural skill'i Canvas tarafına da yazıldı"

  is "ortak skill dizini ve proje sözleşmesi"
  # Ortak skill dizini: Canvas kabı bunu ~/.agents/skills olarak görür.
  # Dizin her seferinde sıfırdan derlenir (silinen skill kapta kalmasın diye).
  # Bu yüzden daha önce kurulmuş bir claude-obsidian varsa onu bu koşuda da
  # veriyoruz: yoksa "--with-fable --resume" gibi bilgi tabanı seçili olmayan
  # bir koşu, kurulu 15 skill'i sessizce düşürürdü. Bilgi tabanı bu koşuda
  # kuruluyorsa 10. adım dizini zaten bir kez daha derliyor.
  CO_VAR=""; [[ -d "$AI_ROOT/claude-obsidian/skills" ]] && CO_VAR="$AI_ROOT/claude-obsidian"
  bash "$SRC_DIR/roller/skill-birlestir.sh" "$DATA/canvas/agents-skills" \
    "$KURALLAR" "$CO_VAR" "$HOME/.claude/skills" >>"$LOGFILE" 2>&1 || true

  # Proje sözleşmesi: AGENTS.md'yi hem Claude Code hem Agent Canvas kendiliğinden
  # okur ve tam metin sistem istemine koyar (SDK onu tetikleyicisiz bir skill'e
  # çevirir). CLAUDE.md de tanınır ama model ailesi Anthropic değilse elenir;
  # yerel modellerle çalıştığımız için sözleşme AGENTS.md adında duruyor.
  PROJ="${CANVAS_PROJECTS:-$HOME/projects}"
  mkdir -p "$PROJ"
  if [[ -f "$PROJ/AGENTS.md" ]]; then
    log "AGENTS.md zaten var, dokunulmadı: $PROJ/AGENTS.md"
  else
    sed -e "s|__VAULT__|/vault|g" "$SRC_DIR/roller/AGENTS.md" > "$PROJ/AGENTS.md"
    ok "proje sözleşmesi: $PROJ/AGENTS.md"
  fi
  # ── Katalogtan uzman roller (isteğe bağlı) ──────────────────────────────
  #  agency-agents (MIT) kataloğundaki personalar bizim rol biçimimizle aynı
  #  Markdown yapısında. İçe aktarıcı üçünü değiştirir: adı slug'a çevirir,
  #  katman adını ekler, gövdeye şirket kurallarını bağlar. "ajans-" öneki
  #  kendi rollerimizle karışmasını önler.
  if (( WITH_AGENCY )); then
    is "katalogtan uzman roller"
    # Kataloğun kendisini kuruyoruz, tek tek dosya çekmiyoruz: resmî kurucusu
    # (scripts/install.sh) listeleme, etkileşimli seçici ve 16 araç hedefi
    # getiriyor. Masaüstü uygulamasına gerek yok, çünkü onun Claude Code biçimi
    # "identity", yani aynı dosyayı aynı yere kopyalıyor; üstelik Linux
    # ikilileri yalnız amd64, Spark aarch64.
    AADIR="$AI_ROOT/agency-agents"
    if [[ -d "$AADIR/.git" ]]; then
      spin "agency-agents güncelleniyor" git -C "$AADIR" pull -q || true
    else
      spin "agency-agents kataloğu indiriliyor" git clone -q --depth 1 \
        https://github.com/msitarzewski/agency-agents "$AADIR" || warn "katalog indirilemedi"
    fi
    if [[ -d "$AADIR" ]]; then
      ok "katalog: $AADIR ($(ls -1 "$AADIR"/*/*.md 2>/dev/null | wc -l) ajan)"
      SECIM="backend-architect,frontend-developer,software-architect,database-optimizer"
      SECIM="$SECIM,devops-automator,sre-site-reliability-engineer,incident-response-commander"
      SECIM="$SECIM,git-workflow-master,technical-writer,minimal-change-engineer"
      SECIM="$SECIM,codebase-onboarding-engineer,api-platform-engineer,product-manager"
      SECIM="$SECIM,sprint-prioritizer,meeting-notes-specialist"
      if (cd "$AADIR" && CLAUDE_CONFIG_DIR="$HOME/.claude" \
            bash scripts/install.sh --tool claude-code --agent "$SECIM" \
            --no-interactive) >>"$LOGFILE" 2>&1; then
        # Resmî kurucu araçtan bağımsız dosya bırakır: model adı yok, kural yok.
        # Uyarlayıcı ikisini ekler ve Canvas kopyasını üretir.
        python3 "$SRC_DIR/roller/uyarla.py" --host "$HOME/.claude/agents" \
          --canvas "$CANVAS_AGENTS" --kurallar "$KURALLAR" >>"$LOGFILE" 2>&1 || true
        AJANS=$(ls -1 "$HOME/.claude/agents"/ajans-*.md 2>/dev/null | wc -l)
        ok "$AJANS uzman rol kuruldu ve kurallara bağlandı (ajans-* önekiyle)"
      else
        warn "katalog rolleri kurulamadı, sonra: spark agents --onerilen"
      fi
    fi
  fi
else
  warn "roller/ klasörü bulunamadı: kurallar ve roller kurulmadı"
fi

is "spark komutu"
sudo install -m0755 "$SRC_DIR/spark" /usr/local/bin/spark
ok "$CDIR hazır · kurallar, roller ve 'spark' komutu kuruldu"
send

# ── 3 İMAJLAR ───────────────────────────────────────────────────────────────
# Flash-Next seçiliyse fable kendi yamalı imajını ister, o da bir iş sayılır
FABLE_IMAJ_IS=0
(( WITH_FABLE )) && [[ "${FABLE_REPO:-}" == *Flash-Next* ]] && FABLE_IMAJ_IS=1
sbegin 3 $(( 3 + WITH_SWAP * 2 + WITH_CANVAS + WITH_EXTRAS * 2 + FABLE_IMAJ_IS ))
# Docker API akışını katman bazında toplayıp tek satır ilerleme basan yardımcı
mkdir -p "$AI_ROOT/bin"
cat > "$AI_ROOT/bin/imaj-ilerleme.py" <<'PYEOF'
import json, sys, time

# Docker /images/create akisi: her satir bir JSON olay. Katman basina
# current/total toplanir; yuzde, hiz, kalan sure ve katman sayisi basilir.
label = sys.argv[1] if len(sys.argv) > 1 else "imaj"
cur, tot, seen, done = {}, {}, set(), set()
t0 = prev_t = time.time(); prev_b = 0; last = 0.0; rate = 0.0

def fmt(b):
    return f"{b/1e9:.1f} GB" if b >= 1e9 else f"{b/1e6:.0f} MB"

for line in sys.stdin:
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if "error" in ev:
        sys.stderr.write("\r\033[K"); print("HATA:", ev["error"]); sys.exit(1)
    st, lid, pd = ev.get("status", ""), ev.get("id"), ev.get("progressDetail") or {}
    if lid: seen.add(lid)
    if st == "Downloading" and pd.get("total"):
        tot[lid] = pd["total"]; cur[lid] = pd.get("current", 0)
    elif st in ("Download complete", "Pull complete", "Already exists") and lid:
        if lid in tot: cur[lid] = tot[lid]
        if st != "Download complete": done.add(lid)
    now = time.time()
    if now - last < 0.5:
        continue
    last = now
    b, T = sum(cur.values()), sum(tot.values())
    inst = (b - prev_b) / max(now - prev_t, 1e-6); prev_b, prev_t = b, now
    rate = rate * 0.7 + inst * 0.3 if rate else inst
    pct = min(100, 100 * b / T) if T else 0
    eta = (T - b) / rate if rate > 0 and T else 0
    sys.stderr.write(f"\r  \033[2m│\033[0m ⏳ {label:<24} %{pct:3.0f}  {fmt(b)} / {fmt(T)}  {rate/1e6:.1f} MB/s"
                     f"  kalan {eta:.0f}s  \033[2m(katman {len(done)}/{len(seen)})\033[0m   ")
    sys.stderr.flush()
sys.stderr.write("\r\033[K")
T = sum(tot.values())
print(f"{fmt(T)} indi, {time.time()-t0:.0f}s" if T else "zaten güncel")
PYEOF
pull_image(){ # <imaj[:etiket]> → Docker API ile çeker, ilerlemeyi basar
  local img=$1 name tag rc son tmp
  is "imaj: ${img##*/}"
  if [[ "${img##*/}" == *:* ]]; then name="${img%:*}"; tag="${img##*:}"; else name="$img"; tag="latest"; fi
  local -a sock=(curl -sN --unix-socket /var/run/docker.sock)
  [[ "$DKR" == sudo* ]] && sock=(sudo curl -sN --unix-socket /var/run/docker.sock)
  tmp=$(mktemp)
  "${sock[@]}" -X POST "http://localhost/images/create?fromImage=${name}&tag=${tag}" 2>>"$LOGFILE" \
    | python3 "$AI_ROOT/bin/imaj-ilerleme.py" "${img##*/}" >"$tmp"
  rc=${PIPESTATUS[1]}
  son="$(tail -1 "$tmp")"; rm -f "$tmp"
  _w "imaj ${img}: ${son}"
  if (( rc == 0 )) && dk image inspect "$img" >/dev/null 2>&1; then ok "${img##*/}: ${son}"; return 0; fi
  # API akışı bozulduysa klasik yol (ilerleme yok)
  spin "indiriliyor: ${img##*/}" dk pull "$img" && ok "${img##*/}"
}
for img in "$VLLM_IMAGE" ghcr.io/berriai/litellm-database:main-latest postgres:16-alpine; do
  pull_image "$img" || die "imaj indirilemedi: $img"
done
if (( WITH_SWAP )); then
  SWAP_IMG="ghcr.io/mostlygeek/llama-swap:${LLAMASWAP_TAG:-unified-cuda13}"
  pull_image "$SWAP_IMG" || die "llama-swap imajı indirilemedi: $SWAP_IMG"
  # llama-swap'in Docker API istemcisi yok, komutu düz exec ediyor. Konteynerleri
  # başlatabilmesi için statik docker CLI ikilisi imajın içine bağlanır.
  if [[ -x "$AI_ROOT/bin/docker" ]]; then
    is "statik docker CLI"
    ok "docker CLI hazır ($("$AI_ROOT/bin/docker" --version 2>/dev/null | head -1 || echo '?'))"
  else
    is "statik docker CLI"
    DCLI_VER="${DOCKER_CLI_VERSION:-28.5.1}"; DCLI_ARCH="$(uname -m)"
    spin "statik docker CLI ($DCLI_VER · $DCLI_ARCH)" bash -c \
      "curl -fsSL 'https://download.docker.com/linux/static/stable/$DCLI_ARCH/docker-$DCLI_VER.tgz' \
       | tar -xz -C '$AI_ROOT/bin' --strip-components=1 docker/docker" \
      && chmod +x "$AI_ROOT/bin/docker" && ok "docker CLI indirildi" \
      || die "statik docker CLI indirilemedi: .env içinde DOCKER_CLI_VERSION dene"
  fi
fi
if (( WITH_FABLE )) && [[ "${FABLE_REPO:-}" == *Flash-Next* ]]; then
  # Flash-Next'in 51 GB'lık PLE tablosunu diskten sunma yeteneği upstream vLLM'de
  # yok. Resmî önizleme imajının üstüne yamayı ekleyen yapıyı burada kuruyoruz;
  # onsuz katman belleğe sığmaz. Yapı imajı çekip yamaları uygular, ~1 dk sürer.
  is "fable imajı: vLLM + PLE yaması"
  FIMG="${FABLE_IMAGE:-qwen38-flash-dgx:latest}"
  if dk image inspect "$FIMG" >/dev/null 2>&1; then
    ok "fable imajı zaten kurulu: $FIMG"
  else
    if [[ -d "$FDIR/.git" ]]; then spin "PLE yaması güncelleniyor" git -C "$FDIR" pull -q || true
    else spin "PLE yaması indiriliyor" git clone -q --depth 1 \
           https://github.com/blazux/qwen3.8-Flash-DGX "$FDIR" || warn "yama deposu indirilemedi"; fi
    if [[ -f "$FDIR/Dockerfile" ]]; then
      stream "fable-imaj" dk build -t "$FIMG" "$FDIR" \
        && ok "fable imajı kuruldu: $FIMG" \
        || { warn "fable imajı kurulamadı; katman PLE yaması olmadan açılmaz"
             log "   elle:  cd $FDIR && docker build -t $FIMG ."; }
    else
      warn "Dockerfile bulunamadı: $FDIR"
    fi
  fi
fi
if (( WITH_CANVAS )); then
  CANVAS_IMG="ghcr.io/openhands/agent-canvas:${CANVAS_TAG:-1.19.0}"
  pull_image "$CANVAS_IMG" || die "Agent Canvas imajı indirilemedi: $CANVAS_IMG"
  mkdir -p "${CANVAS_PROJECTS:-$HOME/projects}"
  ok "proje klasörü: ${CANVAS_PROJECTS:-$HOME/projects}  (ajan yalnız burayı görür)"
fi
((WITH_EXTRAS)) && for img in ghcr.io/open-webui/open-webui:main qdrant/qdrant:latest; do
  pull_image "$img" || warn "$img indirilemedi"; done
send

# ── İndirme ilerlemesi ─────────────────────────────────────────────────────
#  Modeller: toplam boyut HuggingFace API'sinden alınır, hedef klasör iki
#  saniyede bir ölçülür (du -sb); yüzde, hız ve kalan süre tek satırda
#  yenilenir. hf_transfer yarım dosyaları da klasörün içine yazdığı için ölçüm
#  gerçek ilerlemeyi gösterir. İmajlar: Docker API'sinin JSON akışı katman
#  bazında toplanır (current/total), aynı biçimde basılır.
insan_boyut(){ awk -v b="${1:-0}" 'BEGIN{ if (b>=1e9) printf "%.1f GB", b/1e9; else printf "%.0f MB", b/1e6 }'; }
sure_metni(){ local s=${1:-0}
  if (( s >= 3600 )); then printf '%dsa %ddk' $((s/3600)) $((s%3600/60))
  elif (( s >= 60 )); then printf '%ddk %ds' $((s/60)) $((s%60))
  else printf '%ds' "$s"; fi; }
declare -A HF_BOYUT=()
hf_toplam_bayt(){ # <repo> → bayt; API cevap vermezse 0. Sonuç önbelleğe alınır.
  local repo=$1 v
  [[ -n "${HF_BOYUT[$repo]:-}" ]] && { echo "${HF_BOYUT[$repo]}"; return 0; }
  local -a auth=(); [[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")
  v="$(curl -sf --max-time 30 "${auth[@]}" "https://huggingface.co/api/models/$repo/tree/main?recursive=true" 2>/dev/null \
    | jq -r '[.[] | select(.type=="file") | (.lfs.size // .size // 0)] | add // 0' 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  HF_BOYUT[$repo]=$v; echo "$v"; }

# Ağırlıklar bu makinenin belleğine sığıyor mu? İndirmeden önce söylüyoruz:
# yüz gigabaytı indirip açılışta OOM almak pahalı bir öğrenme yolu. Engellemiyor,
# çünkü hangi modeli istediğine sen karar veriyorsun; yalnız sonucu önden yazıyor.
# Spark'ta CPU ile GPU aynı belleği paylaşır, bu yüzden MemTotal doğru ölçüt.
#
# Diskteki boyut her zaman yerleşik boyut değildir: Flash-Next'in 51 GB'lık PLE
# tablosu NVMe'den okunuyor, yerleşik kısım ~75 GB. Böyle bir katman için
# .env'e <KATMAN>_RESIDENT_GB yazılır ve karşılaştırma onunla yapılır.
bellek_uyar(){ # <katman> <repo>
  local t=$1 repo=$2 T RAM kb res yer
  T="$(hf_toplam_bayt "$repo")"; (( T > 0 )) || return 0
  kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"; kb="${kb:-0}"
  RAM=$(( kb * 1024 )); (( RAM > 0 )) || return 0
  res="${t^^}_RESIDENT_GB"; res="${!res:-}"
  if [[ "$res" =~ ^[0-9]+$ ]]; then
    yer=$(( res * 1000000000 ))
    (( yer * 100 < RAM * 85 )) && { log "$t: diskte $(insan_boyut "$T"), bellekte ~${res} GB (kalanı diskten okunur)"; return 0; }
  else
    yer=$T
  fi
  (( yer * 100 < RAM * 85 )) && return 0
  warn "$t ağırlıkları $(insan_boyut "$yer"), makinenin toplam belleği $(insan_boyut "$RAM")"
  log "   ağırlıklar + KV cache + işletim sistemi aynı belleği paylaşır"
  log "   bu katman açılmayabilir; açılmazsa .env içinde ${t^^}_REPO satırını değiştir"
  log "   indirme yine de sürüyor: model seçimi senin"; }

# Bir katman gerçekten tam indi mi? Tek başına config.json'a bakmak yanlıştı:
# o küçük dosya ilk inenlerden biri, indirme ortasında kesilince katman "zaten
# var" sanılıyor ve gigabaytlarca ağırlık eksik kalıyordu. Üç işarete bakıyoruz:
#   1) config.json duruyor mu
#   2) yarım kalan parça var mı (hf tamamlanmamış dosyayı .incomplete tutar)
#   3) yereldeki toplam boyut depodaki toplamın en az %97'si mi
# Üçüncüsü API'ye bağlı; API susarsa ilk ikisiyle yetiniyoruz.
#
# İki düzeni de destekliyor. Düz klasörde dosyalar gerçek; HF önbellek düzeninde
# anlık görüntüdeki her dosya blobs/ içine sembolik bağ ve yarım parçalar orada
# durur. Bu yüzden boyut -L ile (bağları izleyerek) ölçülüyor ve .incomplete
# taraması üçüncü argümanla verilen köke kadar genişletilebiliyor.
model_tam_mi(){ # <klasör> <repo> [tarama kökü] → 0 tam, 1 eksik
  local d=$1 repo=$2 kok="${3:-$1}" T b
  [[ -f "$d/config.json" ]] || return 1
  find "$kok" -name '*.incomplete' -type f -print -quit 2>/dev/null | grep -q . && return 1
  # Ağırlık dosyası hiç yoksa kesin eksik: config.json ilk inenlerden biri ve
  # API susmuş olsa bile bu işaret o durumu yakalıyor.
  find -L "$d" -maxdepth 2 \( -name '*.safetensors' -o -name '*.bin' -o -name '*.gguf' \
    -o -name '*.pt' -o -name '*.pth' \) -type f -print -quit 2>/dev/null | grep -q . || return 1
  T="$(hf_toplam_bayt "$repo")"
  (( T > 0 )) || return 0
  b="$(du -sbL "$d" 2>/dev/null | cut -f1)"; b="${b:-0}"
  (( b * 100 >= T * 97 )); }
klasor_izle(){ # <etiket> <klasör> <toplam bayt>  (arka planda çalışır, öndeki iş bitince öldürülür)
  set +e; trap - ERR
  local l=$1 d=$2 T=${3:-0} t0 b0 t1 b1 dt inst rate=0 pct eta
  t0=$(date +%s); b0=$(du -sb "$d" 2>/dev/null | cut -f1); b0=${b0:-0}
  local bp=$b0 tp=$t0
  while :; do
    sleep 2
    b1=$(du -sb "$d" 2>/dev/null | cut -f1); b1=${b1:-0}; t1=$(date +%s)
    dt=$(( t1 - tp )); (( dt < 1 )) && dt=1
    inst=$(( (b1 - bp) / dt )); (( inst < 0 )) && inst=0
    if (( rate == 0 )); then rate=$inst; else rate=$(( (rate * 3 + inst) / 4 )); fi   # üstel ortalama
    if (( T > 0 )); then
      pct=$(( b1 * 100 / T )); (( pct > 100 )) && pct=100
      eta=$(( rate > 0 ? (T - b1) / rate : 0 )); (( eta < 0 )) && eta=0
      printf '\r  %s│%s ⏳ %-9s %%%3d  %s / %s  %s/s  kalan %s  %s(%s)%s   ' "$D" "$R" "$l" "$pct" \
        "$(insan_boyut "$b1")" "$(insan_boyut "$T")" "$(insan_boyut "$rate")" "$(sure_metni "$eta")" \
        "$D" "$(sure_metni $((t1 - t0)))" "$R"
    else
      printf '\r  %s│%s ⏳ %-9s %s indi  %s/s  %s(%s · toplam bilinmiyor)%s   ' "$D" "$R" "$l" \
        "$(insan_boyut "$b1")" "$(insan_boyut "$rate")" "$D" "$(sure_metni $((t1 - t0)))" "$R"
    fi
    bp=$b1; tp=$t1
  done; }
hf_indir(){ # <etiket> <repo> <hedef klasör>  → ilerleme satırıyla indirir
  local l=$1 repo=$2 d=$3 T t0 t1 b wpid rc kap
  T=$(hf_toplam_bayt "$repo"); mkdir -p "$d"
  t0=$(date +%s)
  # Konteynere ad veriyoruz ki kesintide adıyla durdurulabilsin
  kap="sk-indir-${l//[^a-zA-Z0-9_.-]/-}"
  dk rm -f "$kap" >/dev/null 2>&1 || true
  klasor_izle "$l" "$d" "$T" & wpid=$!
  ARKA_PID=$wpid; INDIR_KAP=$kap
  dk run --rm --name "$kap" -e HF_TOKEN="$HF_TOKEN" -e HF_HUB_ENABLE_HF_TRANSFER=1 \
    -v "$MODELS":/models --entrypoint bash "$VLLM_IMAGE" \
    -c "hf download '$repo' --local-dir /models/${d##*/} --max-workers ${HF_WORKERS:-16}" >>"$LOGFILE" 2>&1 &
  ISLEM_PID=$!
  wait "$ISLEM_PID"; rc=$?
  ISLEM_PID=""; INDIR_KAP=""
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; ARKA_PID=""; printf '\r\033[K'
  t1=$(( $(date +%s) - t0 )); (( t1 < 1 )) && t1=1
  b=$(du -sb "$d" 2>/dev/null | cut -f1); b=${b:-0}
  INDIRME_OZETI="$(insan_boyut "$b"), ort. $(insan_boyut $(( b / t1 )))/s, $(sure_metni "$t1")"
  # Klasörde hangi deponun indiği yazılı kalsın: .env'de depo değişince
  # eskisinin dosyalarıyla karışmasın diye bir sonraki koşu buna bakıyor.
  (( rc == 0 )) && printf '%s\n' "$repo" > "$d/.spark-repo" 2>/dev/null
  return $rc; }

hf_indir_onbellek(){ # <etiket> <repo> <hf önbellek kökü>  → HF önbellek düzenine indirir
  # Flash-Next reçetesi ağırlıkları HuggingFace önbellek düzeninde bekliyor:
  # hub/models--<depo>/snapshots/<sürüm>/ ve blobs/. prepare-hybrid.sh o düzenin
  # refs/ ve blobs/ yapısına doğrudan bağlı, düz klasörle çalışmıyor. Bu yüzden
  # fable'ı reçetenin düzeninde tutuyoruz; diğer katmanlar düz klasörde kalıyor.
  local l=$1 repo=$2 kok=$3 T t0 t1 b wpid rc kap
  T=$(hf_toplam_bayt "$repo"); mkdir -p "$kok"
  t0=$(date +%s)
  kap="sk-indir-${l//[^a-zA-Z0-9_.-]/-}"
  dk rm -f "$kap" >/dev/null 2>&1 || true
  klasor_izle "$l" "$kok" "$T" & wpid=$!
  ARKA_PID=$wpid; INDIR_KAP=$kap
  dk run --rm --name "$kap" -e HF_TOKEN="$HF_TOKEN" -e HF_HUB_ENABLE_HF_TRANSFER=1 \
    -e HF_HOME=/hf -v "$kok":/hf --entrypoint bash "$VLLM_IMAGE" \
    -c "hf download '$repo' --max-workers ${HF_WORKERS:-16}" >>"$LOGFILE" 2>&1 &
  ISLEM_PID=$!
  wait "$ISLEM_PID"; rc=$?
  ISLEM_PID=""; INDIR_KAP=""
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; ARKA_PID=""; printf '\r\033[K'
  t1=$(( $(date +%s) - t0 )); (( t1 < 1 )) && t1=1
  b=$(du -sb "$kok" 2>/dev/null | cut -f1); b=${b:-0}
  INDIRME_OZETI="$(insan_boyut "$b"), ort. $(insan_boyut $(( b / t1 )))/s, $(sure_metni "$t1")"
  return $rc; }

anlik_goruntu(){ # <hf kök> <repo> → anlık görüntü dizini (host yolu)
  local kok=$1 repo=$2 rd rev p yeni=""
  rd="$kok/hub/models--${repo//\//--}"
  # Önce refs: reçetenin serve.sh'i de aynı sırayla çözüyor, ikisi aynı
  # anlık görüntüde buluşmalı.
  for ref in main master; do
    rev="$(cat "$rd/refs/$ref" 2>/dev/null || true)"
    [[ -n "$rev" && -d "$rd/snapshots/$rev" ]] && { echo "$rd/snapshots/$rev"; return 0; }
  done
  # refs yoksa en yeni görüntü; hazırlanmış (-fp8hybrid) kopya aday değil
  for p in "$rd"/snapshots/*/; do
    [[ -d "$p" && "$p" != *-fp8hybrid/ ]] || continue
    [[ -z "$yeni" || "$p" -nt "$yeni" ]] && yeni="$p"
  done
  # Bulamayınca boş dönüyoruz ama çıkış kodu 0 olmalı: çağrı yeri
  # snap="$(anlik_goruntu ...)" biçiminde ve set -e sıfır olmayan kodu hata sayar.
  [[ -n "$yeni" ]] && echo "${yeni%/}"
  return 0; }

# Klasörde başka bir depo duruyorsa temizle: .env'de model değiştirdiğinde iki
# modelin dosyaları aynı klasörde karışır ve vLLM açılmaz. İşaret dosyası yoksa
# (eski kurulumdan kalma) dokunmuyoruz, boyut kontrolü zaten devrede.
depo_degistiyse_temizle(){ # <klasör> <repo>
  local d=$1 repo=$2 eski
  [[ -f "$d/.spark-repo" ]] || return 0
  eski="$(cat "$d/.spark-repo" 2>/dev/null)"
  [[ "$eski" == "$repo" ]] && return 0
  warn "$d içinde başka bir model var: $eski"
  log "   yeni depo istendi: $repo, karışmaması için eski dosyalar siliniyor"
  rm -rf "${d:?}"/* "${d:?}"/.cache "${d:?}"/.spark-repo 2>/dev/null || true
  ok "eski model temizlendi, yeni depo baştan inecek"; }

# ── fable · Flash-Next reçetesi ─────────────────────────────────────────────
#  Ağırlıklar HF önbellek düzeninde iner, çünkü reçetenin hazırlık betiği o
#  düzenin refs/ ve blobs/ yapısına bağlı. Anlık görüntü yolu .env'e yazılır,
#  compose oradan okur. Her adım tekrar çalıştırılabilir: inen tekrar inmez,
#  hazırlanmış düzen tekrar hazırlanmaz, yani --resume aynı komuttur.
fable_flashnext(){
  local repo="$FABLE_REPO" kok="$MODELS/hf-cache" snap
  bellek_uyar fable "$repo"
  snap="$(anlik_goruntu "$kok" "$repo")"
  if [[ -n "$snap" ]] && model_tam_mi "$snap" "$repo" "$kok"; then
    is "fable: zaten indirilmiş"
    ok "fable = $repo ($(du -sh "$kok" 2>/dev/null|cut -f1), bütünlük doğrulandı)"
  else
    if [[ -n "$snap" ]]; then
      is "fable: yarım kalmış ($(du -sh "$kok" 2>/dev/null|cut -f1) indi), kaldığı yerden sürüyor"
    else
      is "fable ← $repo  ($(tier_size fable))"
    fi
    hf_indir_onbellek fable "$repo" "$kok" || true
    snap="$(anlik_goruntu "$kok" "$repo")"
    [[ -n "$snap" ]] && model_tam_mi "$snap" "$repo" "$kok" \
      || die "fable eksik indi ($repo); tekrar denemek için: bash install.sh --resume"
    ok "fable indi: $INDIRME_OZETI"
  fi

  # İsteğe bağlı hazırlık: yan katmanlar bf16'dan blok-fp8'e, +%20 çözme hızı,
  # +%8 KV havuzu. Bir kerelik ~10 dk ve ~13 GB. Hazırsa tekrar çalıştırılmaz.
  local snap_ad hib_host
  snap_ad="$(basename "$snap")"
  hib_host="$(dirname "$snap")/${snap_ad}-fp8hybrid"
  if [[ "${FABLE_HYBRID:-1}" == 1 ]]; then
    is "fable hazırlığı: yan katmanlar fp8'e (+%20 çözme)"
    if [[ -f "$hib_host/config.json" ]]; then
      ok "hazırlanmış düzen zaten var: ${snap_ad}-fp8hybrid"
    elif [[ -x "$FDIR/scripts/prepare-hybrid.sh" ]]; then
      if stream "fable-hibrit" env MODEL="$repo" IMAGE="${FABLE_IMAGE:-qwen38-flash-dgx:latest}" \
           HF_CACHE="$kok" bash "$FDIR/scripts/prepare-hybrid.sh"; then
        ok "hazırlık bitti: ${snap_ad}-fp8hybrid"
      else
        warn "hazırlık yapılamadı; fable yayınlandığı düzenle çalışır (~%20 daha yavaş)"
      fi
    else
      warn "prepare-hybrid.sh bulunamadı: $FDIR"
    fi
  else
    log "fable hazırlığı atlandı (FABLE_HYBRID=0); yayınlanan düzen kullanılacak"
  fi

  # Compose'un kaptan göreceği yol. Hazırlanmış düzen varsa onu kullanıyoruz.
  is "fable yolu compose'a yazılıyor"
  local ic="/hf/hub/models--${repo//\//--}/snapshots/$snap_ad"
  local hib=0
  [[ -f "$hib_host/config.json" ]] && { ic="${ic}-fp8hybrid"; hib=1; }
  # Bu katmanı Flash-Next'e ayarlayan bütün anahtarlar burada yazılır.
  # compose'daki varsayılanlar kapalı olduğu için başka bir modele geçersen
  # bu satırları silmek yeterli, ayar kendiliğinden stok vLLM'e döner.
  sed -i '/^FABLE_SNAPSHOT=/d;/^FABLE_FP8_HYBRID=/d;/^FABLE_DEEP_GEMM=/d' "$ENVF"
  sed -i '/^FABLE_PLE_MMAP=/d;/^FABLE_DET_TOPK=/d;/^FABLE_DET_LIB=/d;/^FABLE_DRAFT_VOCAB=/d' "$ENVF"
  { echo "FABLE_SNAPSHOT=$ic"
    echo "FABLE_FP8_HYBRID=$hib"
    echo "FABLE_DEEP_GEMM=0"
    echo "FABLE_PLE_MMAP=1"
    echo "FABLE_DET_TOPK=1"
    echo "FABLE_DET_LIB=/opt/llm/kernel-det/_C_det.so"
    echo "FABLE_DRAFT_VOCAB=/opt/llm/draft_vocab_65536.npy"; } >> "$ENVF"
  export FABLE_SNAPSHOT="$ic" FABLE_FP8_HYBRID="$hib"
  ok "fable yolu: $ic  ·  hazırlanmış düzen: $( ((hib)) && echo evet || echo hayır )"
}

# ── Model indirme yardımcısı ────────────────────────────────────────────────
#  Konteyner içinden indiriyoruz: makineye python/pip kurmuyoruz.
pull_model(){ # pull_model <katman>
  local t=$1 repo_var="${1^^}_REPO" repo
  repo="${!repo_var}"
  if [[ "$t" == fable && "$repo" == *Flash-Next* ]]; then fable_flashnext; return 0; fi
  depo_degistiyse_temizle "$MODELS/$t" "$repo"
  bellek_uyar "$t" "$repo"
  if model_tam_mi "$MODELS/$t" "$repo"; then
    is "$t: zaten indirilmiş"
    ok "$t = $(tier_repo "$t") ($(du -sh "$MODELS/$t"|cut -f1), bütünlük doğrulandı)"; return 0; fi
  if [[ -f "$MODELS/$t/config.json" ]]; then
    is "$t: yarım kalmış ($(du -sh "$MODELS/$t" 2>/dev/null|cut -f1) indi), kaldığı yerden sürüyor"
  else
    is "$t ← $repo  ($(tier_size "$t"))"
  fi
  hf_indir "$t" "$repo" "$MODELS/$t" || true
  model_tam_mi "$MODELS/$t" "$repo" \
    || die "$t eksik indi ($repo); tekrar denemek için: bash install.sh --resume"
  ok "$t indi: $INDIRME_OZETI"

  # Spekülatif decode taslak modeli varsa (ör. sonnet için DSpark) onu da çek
  local draft_var="${1^^}_DRAFT"
  local draft="${!draft_var:-}"
  [[ -n "$draft" ]] && depo_degistiyse_temizle "$MODELS/$t-draft" "$draft"
  if [[ -n "$draft" ]] && ! model_tam_mi "$MODELS/$t-draft" "$draft"; then
    if [[ -f "$MODELS/$t-draft/config.json" ]]; then
      is "$t taslak modeli yarım kalmış, kaldığı yerden sürüyor"
    else
      is "$t taslak modeli ← $draft  (~1 GB)"
    fi
    hf_indir "$t-taslak" "$draft" "$MODELS/$t-draft" || true
    model_tam_mi "$MODELS/$t-draft" "$draft" \
      || die "$t taslak modeli eksik indi ($draft); tekrar: bash install.sh --resume"
    ok "$t taslak indi: $INDIRME_OZETI, spekülatif decode aktif"
  fi
}

# ── 4 MODEL AĞIRLIKLARI ─────────────────────────────────────────────────────
#  Sıra önemli: küçükten büyüğe. Böylece ilk model erken hazır olur ve
#  büyükler inerken bile makine test edilebilir durumda olur.
ALL_TIERS=("${TIERS[@]}"); ((WITH_FABLE)) && ALL_TIERS+=(fable)
# İş sayısı: her katman bir iş, spekülatif decode taslağı olan katman iki.
# Flash-Next üç iş yapar: indirme, hazırlık, compose yolunu yazma.
MODEL_IS=${#ALL_TIERS[@]}
for t in "${ALL_TIERS[@]}"; do dv="${t^^}_DRAFT"; [[ -n "${!dv:-}" ]] && MODEL_IS=$((MODEL_IS+1)); done
(( WITH_FABLE )) && [[ "${FABLE_REPO:-}" == *Flash-Next* ]] && MODEL_IS=$((MODEL_IS+2))
sbegin 4 "$MODEL_IS"
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
sbegin 5 $(( 2 + WITH_SWAP ))
is "kapı ayarı (litellm.yaml)"
FALLBACK_MAIN=opus; [[ " ${TIERS[*]} " == *" opus "* ]] || FALLBACK_MAIN=sonnet

# Kapı katmanlara doğrudan mı bakacak, yoksa llama-swap üzerinden mi? Tek fark
# adres: llama-swap varsa dört katman da onun arkasında, o da istek geldiğinde
# ilgili konteyneri açıyor.
tier_base(){
  if (( WITH_SWAP )); then echo "http://llamaswap:8080/v1"
  else echo "http://host.docker.internal:$(tier_port "$1")/v1"; fi
}
{
  # Nominal maliyet: yerel modelin parası yok ama bütçe token sayarak çalışsın
  # diye 1e-6 $/token yazıyoruz; kapıda 1 $ = 1M token demek.
  MALIYET='input_cost_per_token: 0.000001, output_cost_per_token: 0.000001'
  echo "model_list:"
  for t in haiku sonnet opus fable; do
    cat <<YAML
  - model_name: $t
    litellm_params: {model: openai/$t, api_base: $(tier_base "$t"), api_key: x, $MALIYET}
YAML
    # Eş makineler: aynı katman adı, başka adres → kapı isteği dağıtır (SPARK_PEERS=spark2:8081,spark3:8081)
    IFS=',' read -ra PEERS <<< "${SPARK_PEERS:-}"
    for peer in "${PEERS[@]}"; do
      [[ -n "$peer" ]] || continue
      cat <<YAML
  - model_name: $t
    litellm_params: {model: openai/$t, api_base: http://$peer/v1, api_key: x, $MALIYET}
YAML
    done
  done
  cat <<YAML
  # Araçlar "claude-sonnet-4-5" gibi isimler gönderirse ana modele düşsün
  - model_name: "claude-*"
    litellm_params: {model: openai/$FALLBACK_MAIN, api_base: $(tier_base "$FALLBACK_MAIN"), api_key: x, $MALIYET}

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
  is "llama-swap ayarı"
  SWAP_HEALTH="${SWAP_HEALTH_TIMEOUT:-2100}"   # ilk açılışta GPU çekirdeği derlenir
  SWAP_UNLOAD="${SWAP_UNLOAD_TIMEOUT:-60}"     # durdurmanın bitmesini bekle
  {
    cat <<YAML
# spark-stack: llama-swap ayarı (install.sh üretir; elle düzenleme, üzerine yazılır)
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
  ok "llama-swap ayarı yazıldı: katmanlar istek anında açılacak"
  log "   ısınma payı ${SWAP_HEALTH}s · boşta düşme ${SWAP_TTL:-1800}s · kapı → llamaswap:8080"
fi

is "katman durumu"
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
# ── Ajan başına anahtar ────────────────────────────────────────────────────
#  Kapının artık veritabanı var: her çalışma zamanı kendi anahtarıyla bağlanır.
#  insan: bütün katmanlar (fable dahil). canvas/nemoclaw/a2a: fable YOK (açılınca
#  günlük katmanları düşürür) ve günlük token bütçesi var (döngüye giren ajan
#  bütçesi bitince durur, 429). Anahtarlar veritabanında kalıcı; kopyaları .env'de.
# Anahtar üretimi HİÇBİR ZAMAN sıfır dışında dönmemeli: çağrı yeri
# KEY_X="$(anahtar_uret ...)" biçiminde ve set -e ile pipefail, başarısız bir
# curl'ü ölümcül hataya çevirir. Oysa altta "üretilemedi, ana anahtarla devam"
# diye çalışan bir yedek yol var; ölürsek oraya hiç varamıyoruz.
# Kapı ayağa kalkmış olsa da veritabanı göçü bitmemiş olabilir, o yüzden
# birkaç kez deniyoruz ve son cevabı loga yazıyoruz.
anahtar_uret(){ # <alias> <modeller json> [bütçe]
  local body cevap kod deneme
  body="{\"key_alias\":\"$1\",\"models\":$2,\"metadata\":{\"spark\":\"$VERSION\"}"
  [[ -n "${3:-}" ]] && body+=",\"max_budget\":$3,\"budget_duration\":\"1d\",\"rpm_limit\":120"
  body+="}"
  for deneme in 1 2 3 4 5; do
    cevap="$(curl -s --max-time 20 -w '\n%{http_code}' -X POST http://127.0.0.1:4000/key/generate \
      -H "Authorization: Bearer ${LITELLM_KEY:-sk-spark}" -H 'Content-Type: application/json' \
      -d "$body" 2>/dev/null || true)"
    kod="$(tail -1 <<<"$cevap")"; cevap="$(sed '$d' <<<"$cevap")"
    if [[ "$kod" == 2?? ]]; then
      jq -r '.key // empty' <<<"$cevap" 2>/dev/null || true
      return 0
    fi
    _w "anahtar '$1' denemesi $deneme: HTTP ${kod:-yok} · ${cevap:0:200}"
    sleep 5
  done
  return 0
}
anahtar_gecerli(){ [[ -n "${1:-}" ]] && curl -sf --max-time 10 "http://127.0.0.1:4000/key/info?key=$1" \
    -H "Authorization: Bearer ${LITELLM_KEY:-sk-spark}" >/dev/null 2>&1; }
anahtarlari_uret(){
  local OTO BUTCE k
  OTO="[$(printf '"%s",' "${TIERS[@]}")\"claude-*\"]"   # fable ALL_TIERS'ta, burada yok; claude-* ana katmana düşer
  BUTCE="${OTOMASYON_GUNLUK_MTOKEN:-20}"
  if anahtar_gecerli "${KEY_CANVAS:-}" && anahtar_gecerli "${KEY_INSAN:-}"; then
    ok "ajan anahtarları zaten var (.env: KEY_INSAN KEY_CANVAS KEY_NEMOCLAW KEY_A2A)"; return 0
  fi
  KEY_INSAN="$(anahtar_uret insan '["all-proxy-models"]')"
  KEY_CANVAS="$(anahtar_uret canvas "$OTO" "$BUTCE")"
  KEY_NEMOCLAW="$(anahtar_uret nemoclaw "$OTO" "$BUTCE")"
  KEY_A2A="$(anahtar_uret a2a "$OTO" "$BUTCE")"
  if [[ -z "$KEY_INSAN" || -z "$KEY_CANVAS" || -z "$KEY_NEMOCLAW" || -z "$KEY_A2A" ]]; then
    warn "ajan anahtarları üretilemedi: kapı veritabanı ayakta mı? (spark logs litellm-db)"
    log "   herkes ana anahtarla devam ediyor; bütçe ve fable yasağı DEVRE DIŞI"
    KEY_INSAN="${LITELLM_KEY:-sk-spark}"; KEY_CANVAS="$KEY_INSAN"; KEY_NEMOCLAW="$KEY_INSAN"; KEY_A2A="$KEY_INSAN"
    return 0
  fi
  for k in KEY_INSAN KEY_CANVAS KEY_NEMOCLAW KEY_A2A; do
    sed -i "/^$k=/d" "$ENVF"; echo "$k=${!k}" >> "$ENVF"
  done
  sed -i '/^A2A_KEY=/d' "$ENVF"; echo "A2A_KEY=$KEY_A2A" >> "$ENVF"
  ok "ajan anahtarları üretildi: insan (fable dahil) · canvas · nemoclaw · a2a (fable yok, ${BUTCE}M token/gün)"
  log "   harcama ve kalan bütçe: spark anahtarlar"
}
sbegin 6 $(( 2 + WITH_CANVAS + WITH_A2A + WITH_EXTRAS ))
is "servisler başlatılıyor ve kapı bekleniyor"
# Sahiplik onarıldıysa çalışan veritabanının açık dosya tanıtıcıları hâlâ eski
# durumda; yeniden başlatmadan düzelmiyor.
if [[ "${DB_ONARILDI:-0}" == 1 ]]; then
  spin "kapı veritabanı yeniden başlatılıyor (sahiplik onarımı sonrası)" \
    DC --profile daily restart litellm-db || true
fi
if (( WITH_SWAP )); then
  # Konteynerler oluşturulur ama başlatılmaz; açma işini llama-swap üstlenir.
  CREATE_PROFILES=(--profile demo --profile daily)
  (( WITH_FABLE )) && CREATE_PROFILES+=(--profile fable)
  spin "model konteynerleri oluşturuluyor (kapalı)" DC "${CREATE_PROFILES[@]}" create \
    || die "model konteynerleri oluşturulamadı"
  ok "konteynerler hazır ve kapalı: açmayı llama-swap üstlenecek"
  DC --profile swap up -d || die "kapı ve llama-swap açılmadı"
  wait_http "http://127.0.0.1:${SWAP_PORT:-8081}/health" 180 llama-swap || die "llama-swap açılmadı: spark logs llamaswap"
  wait_http http://127.0.0.1:4000/health/liveliness 300 kapı || die "kapı açılmadı"
  # İlk istek ısınmayı beklemesin diye ana katmanı burada açıyoruz. Claude Code
  # kendi zaman aşımına takılmasın diye bu bekleme kuruluma alındı.
  log "ana katman ısıtılıyor: $FALLBACK_MAIN, ilk açılışta GPU çekirdeği derlenir"
  if curl -s --max-time "${SWAP_HEALTH_TIMEOUT:-2100}" http://localhost:4000/v1/chat/completions \
       -H "Authorization: Bearer ${LITELLM_KEY:-sk-spark}" -H 'Content-Type: application/json' \
       -d "{\"model\":\"$FALLBACK_MAIN\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"OK\"}]}" \
       >>"$LOGFILE" 2>&1; then
    ok "$FALLBACK_MAIN ısındı: bundan sonra /model <katman> yeter, spark up gerekmez"
  else
    warn "ilk ısıtma tamamlanmadı: 'spark ask \"merhaba\" $FALLBACK_MAIN' ile tekrar dene"
  fi
  log "   bellek: $(gpumem)"
else
  PROFILE=daily; (( DEMO )) && PROFILE=demo
  DC --profile "$PROFILE" up -d || die "servisler açılmadı"
  for t in "${TIERS[@]}"; do
    log "$t başlatılıyor: $(tier_repo "$t")"
    wait_http "http://127.0.0.1:$(tier_port "$t")/v1/models" 1800 "$t" || die "$t açılmadı: spark logs $t"
    log "   bellek: $(gpumem)"
  done
  wait_http http://127.0.0.1:4000/health/liveliness 300 kapı || die "kapı açılmadı"
fi
is "ajan anahtarları (model izni ve bütçe)"
anahtarlari_uret
if (( WITH_CANVAS )); then
  is "Agent Canvas"
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
    #  alt ajan devrinin açılması. İkincisi kritik: varsayılanı KAPALI ve
    #  kapalıyken devir aracı hiç yüklenmiyor, yani roller görev alamıyor.
    CAPI="http://127.0.0.1:$CP/api/settings"
    SEED=$(cat <<JSON
{"agent_settings_diff":{"enable_sub_agents":true,
 "llm":{"model":"litellm_proxy/$FALLBACK_MAIN","base_url":"http://litellm:4000","api_key":"${KEY_CANVAS:-${LITELLM_KEY:-sk-spark}}"}}}
JSON
)
    if curl -sf -X PATCH "$CAPI" -H "X-Session-API-Key: ${CANVAS_KEY:-}" \
         -H 'Content-Type: application/json' -d "$SEED" >>"$LOGFILE" 2>&1; then
      # Yazdık demek yetmez; geri okuyup gerçekten oturmuş mu bakıyoruz.
      CCHK="$(curl -sf "$CAPI" -H "X-Session-API-Key: ${CANVAS_KEY:-}" 2>/dev/null \
              | jq -r '[(.. | objects | select(has("enable_sub_agents")) | .enable_sub_agents)] | first // "yok"' 2>/dev/null)"
      if [[ "$CCHK" == "true" ]]; then
        ok "Canvas ayarlandı: alt ajan devri AÇIK, model litellm_proxy/$FALLBACK_MAIN"
        log "   roller kendiliğinden yüklenir: spark-kod · spark-test · spark-denetci"
      else
        warn "ayar yazıldı ama doğrulanamadı (okunan: $CCHK), 'spark canvas' ile bak"
      fi
    else
      warn "Canvas ayarı tohumlanamadı, panelden elle: Settings → Agent → Sub-agents açık,"
      log "   Settings → LLM: litellm_proxy/$FALLBACK_MAIN · http://litellm:4000 · ${KEY_CANVAS:-${LITELLM_KEY:-sk-spark}}"
    fi
  else
    warn "Agent Canvas açılmadı: spark logs canvas"
  fi
fi
if (( WITH_A2A )); then
  is "A2A köprüsü"
  AP="${A2A_PORT:-8400}"
  if DC --profile a2a up -d >>"$LOGFILE" 2>&1 && wait_http "http://127.0.0.1:$AP/health" 90 "A2A köprüsü"; then
    A2AR="$(curl -sf --max-time 10 "http://127.0.0.1:$AP/health" 2>/dev/null | jq -r '.roles|join(", ")' 2>/dev/null)"
    ok "A2A köprüsü: http://localhost:$AP/.well-known/agent-card.json"
    log "   protokolle açılan roller: ${A2AR:-?}"
  else
    warn "A2A köprüsü açılmadı: spark logs a2a"
  fi
fi
((WITH_EXTRAS)) && { is "ekstralar (Open WebUI, Qdrant)"; DC --profile extras up -d && ok "Open WebUI: http://localhost:3000" || warn "ekstralar açılmadı"; }
send

# ── 7 CLAUDE CODE ───────────────────────────────────────────────────────────
sbegin 7 2
is "Claude Code CLI"
# Tek host kurulumu bu: Claude Code senin terminalinde çalışan bir CLI,
# konteynerde çalıştırmak dosya/git erişimini gereksiz zorlaştırırdı.
have claude || spin "Claude Code indiriliyor" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
export PATH="$HOME/.local/bin:$PATH"; have claude || die "claude komutu bulunamadı"
is "yerel kapıya bağlama (.bashrc)"
sed -i '/# >>> spark-stack >>>/,/# <<< spark-stack <<</d' ~/.bashrc
cat >> ~/.bashrc <<EOF
# >>> spark-stack >>>
export PATH="\$HOME/.local/bin:\$PATH"
export ANTHROPIC_BASE_URL=http://localhost:4000
export ANTHROPIC_AUTH_TOKEN=${KEY_INSAN:-${LITELLM_KEY:-sk-spark}}
export ANTHROPIC_API_KEY=${KEY_INSAN:-${LITELLM_KEY:-sk-spark}}
export ANTHROPIC_DEFAULT_OPUS_MODEL=$FALLBACK_MAIN
export ANTHROPIC_DEFAULT_SONNET_MODEL=$FALLBACK_MAIN
export ANTHROPIC_DEFAULT_HAIKU_MODEL=haiku
export ANTHROPIC_MODEL=$FALLBACK_MAIN
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
# <<< spark-stack <<<
EOF
export ANTHROPIC_BASE_URL=http://localhost:4000 ANTHROPIC_AUTH_TOKEN="${KEY_INSAN:-${LITELLM_KEY:-sk-spark}}" ANTHROPIC_API_KEY="${KEY_INSAN:-${LITELLM_KEY:-sk-spark}}"
ok "Claude Code yerel kapıya bağlandı (bulut kapalı)"
send

# ── 8 MCP · hepsi konteyner ────────────────────────────────────────────────
sbegin 8 8
addmcp(){ local n=$1; shift
  is "MCP: $n"
  if claude mcp list 2>/dev/null | grep -q "^$n"; then ok "$n (zaten ekli)"
  elif claude mcp add --scope user "$n" -- "$@" >>"$LOGFILE" 2>&1; then ok "$n"
  else warn "$n eklenemedi"; fi; }
# Docker MCP imajları: makineye node/python kurmuyoruz.
# Bu komutlar Claude Code ayarına kaydediliyor ve SONRA çalışacak; o zaman
# kullanıcı docker grubunda olacağı için düz 'docker' doğru (sudo değil).
addmcp filesystem docker run -i --rm --mount "type=bind,src=$HOME,dst=$HOME" mcp/filesystem "$HOME"
addmcp fetch      docker run -i --rm mcp/fetch
addmcp git        docker run -i --rm --mount "type=bind,src=$HOME,dst=$HOME" mcp/git
addmcp memory     docker run -i --rm -v "$DATA/mcp-memory:/app/dist" mcp/memory
addmcp sequential-thinking docker run -i --rm mcp/sequentialthinking
addmcp context7   docker run -i --rm mcp/context7
addmcp playwright docker run -i --rm --init --pull=always mcr.microsoft.com/playwright/mcp
is "MCP imajları indiriliyor (7 imaj)"
for i in mcp/filesystem mcp/fetch mcp/git mcp/memory mcp/sequentialthinking mcp/context7 mcr.microsoft.com/playwright/mcp; do
  spin "MCP imajı: ${i##*/}" dk pull "$i" || warn "${i} indirilemedi"; done
send

# ── 9 SKILL'LER ────────────────────────────────────────────────────────────
sbegin 9 1
is "superpowers skill paketi"
mkdir -p "$HOME/.claude/skills"
if claude plugin marketplace add obra/superpowers-marketplace >>"$LOGFILE" 2>&1 \
 && claude plugin install superpowers@superpowers-marketplace >>"$LOGFILE" 2>&1; then
  ok "superpowers eklentisi kuruldu"
else
  warn "eklenti CLI'si kullanılamadı: skill'ler kopyalanıyor"
  T=$(mktemp -d)
  if dk run --rm -v "$T:/out" alpine/git clone -q --depth 1 https://github.com/obra/superpowers /out/sp >>"$LOGFILE" 2>&1 \
     && [[ -d "$T/sp/skills" ]]; then
    cp -r "$T/sp/skills/." "$HOME/.claude/skills/" && ok "$(ls "$T/sp/skills"|wc -l) skill kopyalandı"
  else warn "superpowers alınamadı, sonra: /plugin install superpowers@superpowers-marketplace"; fi
  sudo rm -rf "$T"
fi
send

# ── 10 OBSIDIAN + BİLGİ TABANI ──────────────────────────────────────────────
#  AgriciDaniel/claude-obsidian: Claude Code eklentisi + 15 Agent Skill.
#  Kaynak at → Claude okur, bağlar, Obsidian vault'una kaydeder. Kanıt/alıntı
#  takibi yapar, BM25 ile arar (embedding gerekmez), düz Markdown bırakır.
#  Kod yazarken notlarına bakabilmen için: /claude-obsidian:wiki-query
BILGI_IS=0; (( WITH_WIKI )) && { [[ "$BILGI" == graphify ]] && BILGI_IS=4 || BILGI_IS=6; }
# ── graphify motoru ────────────────────────────────────────────────────────
#  Obsidian motoru kaynaktan alıntılı wiki üretir; graphify kod ve belgeden
#  sorgulanabilir bir graf çıkarır. Kod ayrıştırma tree-sitter ile yapılır:
#  yerel, deterministik, modele gitmez. Yalnız belge/PDF taraması bir modele
#  ihtiyaç duyar, onu da kendi kapımıza bağlıyoruz.
#
#  Kendi sanal ortamı var: sistem python'una dokunmuyoruz ve graphify'ın
#  belgelerindeki "pip ile kurma, yorumlayıcı karışır" uyarısı da böylece
#  aşılıyor (venv, pipx'in yaptığı yalıtımın aynısı).
graphify_kur(){
  local GDIR="$AI_ROOT/graphify" GPY GBIN
  is "graphify paketi (kendi sanal ortamında)"
  if [[ ! -x "$GDIR/.venv/bin/graphify" ]]; then
    python3 -m venv "$GDIR/.venv" || { warn "graphify sanal ortamı kurulamadı"; return 1; }
    "$GDIR/.venv/bin/pip" install -q --upgrade pip >>"$LOGFILE" 2>&1
    spin "graphifyy indiriliyor (tree-sitter dilbilgileri dahil)" \
      "$GDIR/.venv/bin/pip" install -q "graphifyy[pdf,mcp,anthropic]" \
      || { warn "graphify kurulamadı, log: $LOGFILE"; return 1; }
  fi
  GBIN="$GDIR/.venv/bin/graphify"; GPY="$GDIR/.venv/bin/python"
  ok "$("$GBIN" --version 2>/dev/null | head -1 || echo graphify)  ·  $GDIR"

  is "Claude Code skill kaydı"
  # Kayıt ~/.claude/skills/graphify altına yazılır; ortak skill dizini onu
  # zaten topluyor, yani Canvas tarafı da skill metnini görüyor.
  if (cd "$HOME" && PATH="$GDIR/.venv/bin:$PATH" "$GBIN" install) >>"$LOGFILE" 2>&1; then
    ok "skill kuruldu: ~/.claude/skills/graphify  ·  kullanım: /graphify ."
  else
    warn "skill kaydı yapılamadı, elle: $GBIN install"
  fi

  is "kapıya bağlama ve wiki komutu"
  # Belge/PDF taraması için model: Anthropic uyumlu uç olarak kendi kapımız.
  # Kod ayrıştırma bu ayardan bağımsız, zaten modelsiz çalışıyor.
  sed -i '/^GRAPHIFY_/d' "$ENVF"
  { echo "GRAPHIFY_BIN=$GBIN"
    echo "GRAPHIFY_BACKEND=claude"; } >> "$ENVF"
  sudo tee /usr/local/bin/wiki >/dev/null <<WEOF
#!/usr/bin/env bash
# wiki: bilgi grafına sor (motor: graphify)
#   wiki                 bulunduğun projenin grafını kur ya da tazele
#   wiki "soru"          grafa soru sor
#   wiki yol A B         iki şey arasındaki bağlantıyı izle
#   wiki anlat X         tek bir kavramı açıkla
# Graf projenin içinde durur: ./graphify-out/  (depoya girmesi tasarım gereği)
# Anahtar .env'den okunur: kurulum sırasında değil, çalışma anında geçerli olanı
set -a; [[ -f "$CDIR/.env" ]] && . "$CDIR/.env"; set +a
export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_API_KEY="\${KEY_INSAN:-\${LITELLM_KEY:-sk-spark}}"
export ANTHROPIC_AUTH_TOKEN="\$ANTHROPIC_API_KEY"
G="$GBIN"
case "\${1:-}" in
  "")      # iki aşama: AST çıkarımı (modelsiz) + kümeleme ve rapor
           "\$G" . --backend claude || exit 1
           exec "\$G" cluster-only . --backend claude ;;
  yol)     shift; exec "\$G" path "\$@" ;;
  anlat)   shift; exec "\$G" explain "\$@" ;;
  *)       exec "\$G" query "\$*" ;;
esac
WEOF
  sudo chmod +x /usr/local/bin/wiki
  ok "'wiki' komutu kuruldu (graphify motoru)"

  is "ortak skill dizini"
  if bash "$SRC_DIR/roller/skill-birlestir.sh" "$DATA/canvas/agents-skills" \
       "$KURALLAR" "" "$HOME/.claude/skills" >>"$LOGFILE" 2>&1; then
    ok "ortak skill dizini derlendi: $(find "$DATA/canvas/agents-skills" -maxdepth 1 -mindepth 1 | wc -l) girdi"
  else
    warn "ortak skill dizini derlenemedi"
  fi
  log "kullanım:  wiki  ·  wiki \"soru\"  ·  wiki yol A B  ·  graf: <proje>/graphify-out/"
  log "   Canvas tarafı grafın çıktısını /projects/<proje>/graphify-out/ altından okur"
  log "   sorgu ucunu kaba açmak istersen:  $GPY -m graphify.serve <proje>/graphify-out/graph.json \\"
  log "     --transport http --host 0.0.0.0 --port 8500 --api-key \"\$LITELLM_KEY\""
}

sbegin 10 "$BILGI_IS"
if (( WITH_WIKI == 0 )); then
  log "atlandı, sonradan:  bash install.sh --with-wiki --resume  (motor: --bilgi obsidian|graphify)"
elif [[ "$BILGI" == graphify ]]; then
  graphify_kur
else
  PYV="$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo 0)"
  if [[ "$(printf '%s\n3.11\n' "$PYV" | sort -V | head -1)" != "3.11" ]]; then
    warn "python3 $PYV < 3.11: bilgi tabanı atlanıyor (claude-obsidian 3.11+ ister)"
  else
    is "python3 sürümü ve Obsidian uygulaması"
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
        warn "Obsidian sürümü öğrenilemedi: uygulama atlanıyor (vault yine de çalışır)"
      else
        OBS_URL="https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBS_VER}/Obsidian-${OBS_VER}-arm64.AppImage"
        spin "libfuse2 kuruluyor (AppImage için)" apt_get libfuse2t64 || apt_get libfuse2 || warn "libfuse2 kurulamadı"
        sudo mkdir -p /opt/obsidian
        if spin "Obsidian $OBS_VER indiriliyor (ARM64 AppImage)" \
             sudo curl -fsSL -o /opt/obsidian/Obsidian.AppImage "$OBS_URL"; then
          sudo chmod +x /opt/obsidian/Obsidian.AppImage
          # PATH sarmalayıcı: AppImage'ı doğru bayraklarla açar
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
            log "   masaüstü oturumu yok: uygulama şimdilik açılmaz, vault dosyaları yine çalışır"
        else
          warn "Obsidian indirilemedi: vault yine de çalışır"
        fi
      fi
    fi

    is "claude-obsidian eklentisi (15 skill)"
    WIKI_DIR="$AI_ROOT/claude-obsidian"
    if [[ -d "$WIKI_DIR/.git" ]]; then spin "claude-obsidian güncelleniyor" git -C "$WIKI_DIR" pull -q || true
    else spin "claude-obsidian indiriliyor" git clone -q https://github.com/AgriciDaniel/claude-obsidian "$WIKI_DIR" || die "claude-obsidian indirilemedi"; fi
    ok "ürün: $WIKI_DIR ($(git -C "$WIKI_DIR" describe --tags --always 2>/dev/null || echo main))"

    is "vault hazırlığı (init/adopt, iki aşamalı onay)"
    # Kasa yolu: --vault ile verilmediyse varsayılan
    VAULT="${OBSIDIAN_VAULT:-$HOME/vault}"

    # init (yeni vault) mı adopt (mevcut Obsidian vault'u) mı?
    if [[ -f "$VAULT/.claude-obsidian.json" ]]; then
      ok "vault zaten hazır: $VAULT"
    else
      WOP="init"; [[ -d "$VAULT/.obsidian" ]] && WOP="adopt"
      log "vault hazırlanıyor ($WOP): $VAULT"
      # İki aşamalı onay: önce plan, plandaki sha256 ile uygula.
      # Bu projenin güvenlik sözleşmesi: hiçbir yazma onaysız yapılmaz.
      GEN="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; OPID="spark-stack-$(date +%s)"
      PLAN="$(cd "$WIKI_DIR" && python3 scripts/claude-obsidian.py "$WOP" "$VAULT" \
                --generated-at "$GEN" --operation-id "$OPID" 2>>"$LOGFILE")" || die "vault planı üretilemedi"
      echo "$PLAN" >>"$LOGFILE"
      SHA="$(jq -r '.approved_plan_sha256 // empty' <<<"$PLAN" 2>/dev/null)"
      [[ -n "$SHA" ]] || die "plan hash'i okunamadı, elle: cd $WIKI_DIR && python3 scripts/claude-obsidian.py $WOP $VAULT"
      log "plan onayı: ${SHA:0:16}…"
      (cd "$WIKI_DIR" && python3 scripts/claude-obsidian.py "$WOP" "$VAULT" \
         --generated-at "$GEN" --operation-id "$OPID" \
         --approved-plan-sha256 "$SHA" --apply) >>"$LOGFILE" 2>&1 || die "vault oluşturulamadı"
      ok "vault hazır: $VAULT"
    fi

    is "ortak skill dizini yeniden derleniyor"
    # Ortak skill dizinini yeniden derle: claude-obsidian'ın 15 skill'i artık
    # burada, PRODUCT_ROOT kaptaki /opt/claude-obsidian'a sabitleniyor. Böylece
    # Canvas'taki ajan da wiki-query/wiki-retrieve kullanabiliyor, yani vault
    # araması iki tarafta da aynı hattan geçiyor.
    if bash "$SRC_DIR/roller/skill-birlestir.sh" "$DATA/canvas/agents-skills" \
         "$KURALLAR" "$WIKI_DIR" "$HOME/.claude/skills" >>"$LOGFILE" 2>&1; then
      SKS=$(find "$DATA/canvas/agents-skills" -maxdepth 1 -mindepth 1 | wc -l)
      ok "ortak skill dizini derlendi: $SKS girdi (Canvas da aynı skill'leri görüyor)"
    else
      warn "ortak skill dizini derlenemedi"
    fi

    is "wiki komutu"
    # 'wiki' komutu: vault'a girip Claude Code'u eklentiyle açar
    sudo tee /usr/local/bin/wiki >/dev/null <<WIKIEOF
#!/usr/bin/env bash
# wiki: vault'ta Claude Code aç (claude-obsidian eklentisiyle)
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

    is "vault MCP kaydı"
    # Kod yazarken notlara bakabilmek için: vault'u MCP olarak ekle
    if claude mcp list 2>/dev/null | grep -q '^vault'; then ok "vault MCP zaten ekli"
    elif claude mcp add --scope user vault -- docker run -i --rm \
           --mount "type=bind,src=$VAULT,dst=$VAULT" mcp/filesystem "$VAULT" >>"$LOGFILE" 2>&1; then
      ok "vault MCP eklendi: her projede notlarına erişebilirsin"
    else warn "vault MCP eklenemedi"; fi

    sed -i '/^OBSIDIAN_VAULT=/d' "$ENVF"; echo "OBSIDIAN_VAULT=$VAULT" >> "$ENVF"
    log "kullanım:  wiki  ·  wiki \"soru\"  ·  obsidian  ·  kaynak at: $VAULT/inbox/"
  fi
fi
send

# ── 11 NEMOCLAW · yalıtılmış ajan kabı ──────────────────────────────────────
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
sbegin 11 $(( WITH_NEMOCLAW ? 2 : 0 ))
if (( WITH_NEMOCLAW == 0 )); then
  log "atlandı, sonradan:  bash install.sh --with-nemoclaw --resume"
else
  NC_KEY="${KEY_NEMOCLAW:-${LITELLM_KEY:-sk-spark}}"
  NC_URL="http://localhost:4000/v1"
  log "kaynak : https://www.nvidia.com/nemoclaw.sh  (NVIDIA/NemoClaw · Apache-2.0)"
  log "kap    : $NEMOCLAW_SANDBOX"
  log "model  : $FALLBACK_MAIN  ←  $NC_URL"

  # Onboarding ucu gerçekten yokluyor; kapı kapalıysa orada takılır.
  if curl -sf --max-time 10 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1; then
    ok "kapı ayakta: NemoClaw modeli doğrulayabilecek"
  else
    warn "kapı (:4000) cevap vermiyor, onboarding model doğrulamasında düşebilir"
  fi
  if have node; then log "node $(node -v 2>/dev/null || echo '?')  (NemoClaw en az v22.19 ister)"
  else log "node yok: NemoClaw kendi kuracak (nvm ile)"; fi

  is "NemoClaw kurulumu (Node.js + OpenShell + kap)"
  export PATH="$HOME/.local/bin:$PATH"
  if have nemoclaw; then
    ok "nemoclaw zaten kurulu: $(nemoclaw --version 2>/dev/null | head -1 || echo '?')"
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
    log "kuruluyor: Node.js + OpenShell + CLI + kap, çıktının tamamı $LOGFILE"
    if stream nemoclaw nemoclaw_bootstrap; then
      ok "NemoClaw kurulumu bitti"
    else
      warn "NemoClaw kurulumu tamamlanamadı: spark-stack'in geri kalanı etkilenmedi"
      log "elle:  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash   sonra:  nemoclaw onboard"
    fi
    export PATH="$HOME/.local/bin:$PATH"
  fi

  if have nemoclaw; then
    is "kap kaydı ve panel adresi"
    ok "nemoclaw $(nemoclaw --version 2>/dev/null | head -1 || echo '?')"
    nemoclaw list --json >>"$LOGFILE" 2>&1 || true
    NC_DASH="$(nemoclaw "$NEMOCLAW_SANDBOX" dashboard-url --quiet 2>/dev/null | tr -d '\r' | head -1 || true)"
    if [[ -n "$NC_DASH" ]]; then ok "panel: $NC_DASH"
    else log "panel adresi sonra:  nemoclaw $NEMOCLAW_SANDBOX dashboard-url"; fi
    grep -q '^NEMOCLAW_SANDBOX=' "$ENVF" || echo "NEMOCLAW_SANDBOX=$NEMOCLAW_SANDBOX" >> "$ENVF"
    log "bağlan:  nemoclaw $NEMOCLAW_SANDBOX connect   ·   log:  nemoclaw $NEMOCLAW_SANDBOX logs --follow"
  else
    warn "nemoclaw komutu PATH'te yok, yeni terminal aç ya da logu oku: $LOGFILE"
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

# Kurduğumuz her parçayı tek tek yokluyoruz. "Kuruldu" demek yetmez; neyin
# gerçekten cevap verdiğini kurulum bitmeden görmek gerekir.
EKSIK=0
v_ok(){ ok "$1"; }
v_no(){ warn "$1"; EKSIK=$((EKSIK+1)); }

KSAY=$(ls -1 "$KURALLAR"/*.md 2>/dev/null | wc -l)
(( KSAY )) && v_ok "kurallar: $KSAY dosya · $KURALLAR" || v_no "kural dosyası yok: $KURALLAR"
if [[ -n "${KEY_CANVAS:-}" && "$KEY_CANVAS" != "${LITELLM_KEY:-sk-spark}" ]]; then
  FRC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:4000/v1/chat/completions \
        -H "Authorization: Bearer $KEY_CANVAS" -H 'Content-Type: application/json' \
        -d '{"model":"fable","max_tokens":1,"messages":[{"role":"user","content":"x"}]}')
  [[ "$FRC" == 403 ]] && v_ok "yönetişim: otomasyon anahtarı fable'a erişemiyor (403)" \
                      || v_no "yönetişim: canvas anahtarı fable'a $FRC döndü, 403 bekleniyordu"
else
  v_no "ajan anahtarları yok: herkes ana anahtarla; bütçe ve fable yasağı devre dışı"
fi
if [[ -x "$AI_ROOT/denetim/bin/ruff" && "$(git config --global core.hooksPath 2>/dev/null)" == "$AI_ROOT/denetim/hooks" ]]; then
  v_ok "kural kapısı: kancalar bağlı · ruff $("$AI_ROOT/denetim/bin/ruff" --version 2>/dev/null | cut -d' ' -f2) · shellcheck $([[ -x "$AI_ROOT/denetim/bin/shellcheck" ]] && echo var || echo yok)"
else
  v_no "kural kapısı eksik: bash $SRC_DIR/roller/denetim/kur.sh $AI_ROOT $SRC_DIR/roller/denetim"
fi

RSAY=$(ls -1 "$HOME/.claude/agents"/spark-*.md 2>/dev/null | wc -l)
(( RSAY == 3 )) && v_ok "roller (Claude Code): $RSAY/3" || v_no "roller eksik (Claude Code): $RSAY/3"

if (( WITH_CANVAS )); then
  CSAY=$(ls -1 "$DATA/canvas/agents"/spark-*.md 2>/dev/null | wc -l)
  (( CSAY == 3 )) && v_ok "roller (Canvas): $CSAY/3" || v_no "roller eksik (Canvas): $CSAY/3"
  CP="${CANVAS_PORT:-8300}"
  CSUB="$(curl -sf --max-time 10 "http://127.0.0.1:$CP/api/settings" -H "X-Session-API-Key: ${CANVAS_KEY:-}" 2>/dev/null \
          | jq -r '[(.. | objects | select(has("enable_sub_agents")) | .enable_sub_agents)] | first // "?"' 2>/dev/null)"
  [[ "$CSUB" == "true" ]] && v_ok "Agent Canvas: alt ajan devri açık" \
                          || v_no "Agent Canvas alt ajan devri kapalı (okunan: $CSUB), Settings → Agent → Sub-agents"
fi

if (( WITH_A2A )); then
  AP="${A2A_PORT:-8400}"
  ASK="$(curl -sf --max-time 10 "http://127.0.0.1:$AP/.well-known/agent-card.json" 2>/dev/null | jq -r '[.skills[].id]|join(", ")' 2>/dev/null)"
  [[ -n "$ASK" ]] && v_ok "A2A köprüsü yayında: $ASK" || v_no "A2A kartı okunamadı: spark logs a2a"
fi

if (( WITH_CANVAS )); then
  SKD="$DATA/canvas/agents-skills"
  SKN=$(find "$SKD" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
  WQ=$([[ -f "$SKD/wiki-query/SKILL.md" ]] && echo var || echo yok)
  if [[ "$BILGI" == graphify ]]; then
    [[ -x "$AI_ROOT/graphify/.venv/bin/graphify" ]] \
      && v_ok "bilgi tabanı: graphify $("$AI_ROOT/graphify/.venv/bin/graphify" --version 2>/dev/null | head -1)" \
      || v_no "graphify kurulu değil: bash install.sh --bilgi graphify --resume"
  fi
  if (( SKN )); then v_ok "ortak skill dizini: $SKN girdi · wiki-query $WQ"
  else v_no "ortak skill dizini boş: Canvas host'takı skill'leri görmez"; fi
fi
(( WITH_AGENCY )) && { ASAY=$(ls -1 "$HOME/.claude/agents"/ajans-*.md 2>/dev/null | wc -l)
  (( ASAY )) && v_ok "katalog rolleri: $ASAY adet" || v_no "katalog rolleri kurulmadı"; }
(( WITH_NEMOCLAW )) && { have nemoclaw && v_ok "NemoClaw CLI hazır" || v_no "nemoclaw komutu yok"; }
(( WITH_SWAP )) && { curl -sf --max-time 5 "http://127.0.0.1:${SWAP_PORT:-8081}/health" >/dev/null 2>&1 \
  && v_ok "llama-swap cevap veriyor" || v_no "llama-swap cevap vermiyor: spark logs llamaswap"; }

if (( EKSIK )); then
  warn "$EKSIK başlık eksik kaldı: yukarıdaki satırlara bak, $LOGFILE içinde ayrıntı var"
else
  ok "kurulan her parça doğrulandı"
fi
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
        API Key   ${KEY_CANVAS:-${LITELLM_KEY:-sk-spark}}

      Claude Code'u alt ajan yapmak için: Settings → Agent → Preset: Claude Code
      ${D}kap zaten bizim kapıya bakıyor (ANTHROPIC_BASE_URL), abonelik token'ı verme${R}

  ${B}UZMAN ROLLER${R}  (--with-agency ile kurulduysa)
      spark agents --liste       katalogdaki bütün ajanlar
      spark agents --onerilen    seçilmiş seti (yeniden) kur
      ${D}claude içinde: "ajans-backend-architect'e devret" de, ya da tarif et${R}

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
      ${D}model kapıdan gelir: ${FALLBACK_MAIN} @ localhost:4000, bulut yok${R}

FIN
(( DEMO )) && printf '  %sopus sonradan:%s spark pull opus && spark up daily\n' "$D" "$R"
((WITH_FABLE)) || printf '  %sfable sonradan:%s bash install.sh --with-fable --resume\n' "$D" "$R"
printf '\n'

