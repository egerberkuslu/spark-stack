# spark-stack

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: DGX Spark](https://img.shields.io/badge/platform-DGX%20Spark%20(GB10)-76b900)](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)
[![Arch: aarch64](https://img.shields.io/badge/arch-aarch64-lightgrey)](#)

NVIDIA DGX Spark üzerinde tamamen yerel bir kod asistanı. Dört model katmanı (NVIDIA Nemotron + Qwen), tek API kapısı, Claude Code arayüzü. Buluta hiçbir istek gitmez.

```bash
git clone https://github.com/egerberkuslu/spark-stack
cd spark-stack
bash install.sh --all --token hf_xxx
```

1 Gbit hatta yaklaşık 50-70 dakika. Adım adım anlatım: **[SETUP.md](SETUP.md)**

Bunu tek kişilik asistan olarak değil, şirketin işlerini yürüten ajan altyapısı olarak
kuracaksan: **[docs/MIMARI.md](docs/MIMARI.md)** — ajan rolleri, ajan başına anahtar ve
bütçe, yalıtım seviyeleri, tek makinenin eşzamanlılık tavanı.

---

## Katmanlar

| Katman | HuggingFace deposu | Aile | Aktif param. | Kullanım | Bellek | Port |
|---|---|---|---|---|---|---|
| `haiku` | `unsloth/Qwen3.6-35B-A3B-NVFP4` | Qwen | 3B (MoE) | Anlık cevap, commit mesajı, dosya özeti | ~25 GB | 8002 |
| `sonnet` | `nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` + DSpark | NVIDIA | 3B (MoE) | Günlük iş, ajan döngüleri — **~108 tok/s** | ~20 GB | 8000 |
| `opus` | `unsloth/Qwen3.8-27B-NVFP4` + MTP | Qwen | 27B (dense) | Ciddi kod, ajan işleri — **varsayılan** | ~20 GB | 8888 |
| `fable` | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | NVIDIA | 12B (MoE) | En zor işler — **tek başına çalışır** | ~67 GB | 8001 |

İlk üç katman aynı anda açık durur (~65 GB ağırlık + KV cache). `fable` açıldığında diğerleri kapanır.

Claude Code içinde `/model haiku|sonnet|opus` ile geçilir. Kapalı bir katman istenirse LiteLLM isteği çalışan bir katmana yönlendirir — hata dönmez.

![Katman yönlendirmesi ve düşme zinciri](docs/figures/spark-katman-yonlendirme.png)

Depolar `.env` içinde `HAIKU_REPO`, `SONNET_REPO`, `OPUS_REPO`, `FABLE_REPO` olarak tanımlı. Hangi katmanın hangi modeli çalıştırdığı kurulum boyunca ekranda ve `spark models` çıktısında gösterilir.

### Neden bu dörtlü

**İki aile, iki düşünme tarzı.** Qwen ve NVIDIA Nemotron farklı eğitim felsefelerine sahip; biri takıldığında diğerine geçilir. Her katman kendi ailesinin resmî parser'ıyla çalışır (`hermes`/`qwen3` ve `qwen3_coder`/`nemotron_v3`), aile karışımı yok.

**sonnet = Nemotron 3.5 Lightning.** NVIDIA'nın model kartında DGX Spark için resmî DSpark reçetesi var; bayraklar oradan alındı. DSpark taslak modeliyle Spark'ta ölçülen ~108 tok/s, bu donanımda en yüksek tek-akış hızı. 1M bağlam, OpenMDW lisansı (ticari kullanım serbest).

**opus = Qwen3.8-27B.** Yoğun (dense) 27B; Spark'ın 273 GB/s bant genişliğinde spekülatif decode olmadan ~12 tok/s'de kalır. Checkpoint kendi MTP modülünü içerdiği için `--speculative-config` ile taslak olarak çalışır. Kodda en iyi kalite, ajan araçlarına "developer role" desteği.

**haiku = Qwen3.6-35B-A3B.** 3B aktif MoE, 2.54M indirme. Hafif işler ve sonnet'e Qwen alternatifi.

**fable = Nemotron-3-Super.** NVFP4 ile **ön eğitilmiş** (sonradan kuantize değil), MTP dahili. 12B aktif → ~20 tok/s; ajan döngüsü için değil, tek zor soru için.

**Depo kuralı:** yalnızca birinci taraf (NVIDIA, Qwen) ya da büyük kuantizasyoncu (Unsloth). Tek kişilik/deneysel depo kullanılmıyor — bozuk bir kuantizasyon Spark'ta sessizce anlamsız çıktı üretir ve fark etmesi zordur.

**Tüm katmanlar NVFP4 + Marlin.** GB10'da (sm_121) stok CUTLASS FP4 çekirdekleri bozuk çıktı üretir; `.env` içindeki `VLLM_NVFP4_GEMM_BACKEND=marlin` bunu engeller.

Alternatif depolar `.env` sonunda yorum olarak listelenmiştir.

---

## Mimari

![spark-stack mimarisi](docs/figures/spark-mimari.png)

Makineye kurulan tek bileşen Claude Code'dur (tek dosyalık CLI, terminalde çalışması gerekiyor). Model sunucuları, kapı, veritabanları ve MCP sunucularının tamamı konteynerde çalışır — sistem Python'una dokunulmaz, aarch64 wheel sorunu yaşanmaz.

---

## Kurulum seçenekleri

```bash
bash install.sh --demo      # haiku + sonnet            ~45 GB    15-20 dk
bash install.sh             # + opus                    ~65 GB    30-40 dk
bash install.sh --all       # dört katman + eklentiler ~132 GB    50-70 dk
```

![Kurulum profilleri](docs/figures/spark-kurulum-profilleri.png)

| Bayrak | Açıklama |
|---|---|
| `--token hf_xxx` | HuggingFace anahtarını komutla ver (sorulmaz) |
| `--with-fable` | Dördüncü katman |
| `--with-extras` | Open WebUI, Qdrant, Whisper |
| `--with-wiki` | Obsidian + claude-obsidian bilgi tabanı |
| `--with-nemoclaw` | NVIDIA NemoClaw ajan kabı (`--all` içinde) |
| `--with-swap` | llama-swap: katmanı istek anında aç (`--all` içinde) |
| `--with-canvas` | Agent Canvas ajan kontrol merkezi (`--all` içinde) |
| `--projects PATH` | Canvas ajanının göreceği klasör (varsayılan `~/projects`) |
| `--vault PATH` | Vault yolu (varsayılan `~/vault`) |
| `--resume` | Yarım kalan kurulumu sürdür |
| `--status` / `--uninstall` | Durum / kaldırma |

---

## Sıfır makineden başlar

Hiçbir şey kurulmamış bir Spark varsayılır. Script eksik olanı kurar, kurulu olanı atlar:

| Bileşen | Davranış |
|---|---|
| curl, jq, git, gnupg | Eksikse apt ile kurulur |
| NVIDIA sürücüsü | Eksikse kurulur, yeniden başlatma istenir, `--resume` ile devam edilir |
| Docker Engine + Compose v2 | Eksikse Docker'ın resmî deposundan kurulur |
| NVIDIA Container Toolkit | Eksikse kurulur, `nvidia-ctk` ile Docker'a tanıtılır |
| docker grubu | Kullanıcı eklenir; oturumda etkin değilse kurulum `sudo docker` ile sürdürülür |

Son adımda konteynerden `nvidia-smi` çalıştırılarak GPU erişimi fiilen doğrulanır.

> DGX OS bu bileşenlerin çoğunu hazır getirir; o durumda adım birkaç saniye sürer.

---

## Günlük kullanım

```bash
spark status                # servis durumu, bellek, disk
spark swap                  # llama-swap: hangi katman ayakta
spark canvas                # Agent Canvas adresi ve ayarları
spark up canvas             # kontrol merkezini aç
spark up swap               # llama-swap düzenini aç
spark up demo               # haiku + sonnet
spark up daily              # haiku + sonnet + opus
spark up fable              # yalnız fable
spark up extras             # Open WebUI :3000, Qdrant :6333
spark logs opus             # canlı log
spark ask "merhaba" sonnet  # hızlı test
spark pull opus             # katman ağırlığı indir
spark models                # katman → model eşlemesi ve durum
spark update                # imajları güncelle
spark down                  # tümünü durdur
```

---

## Ne kuruluyor

| Bileşen | Detay |
|---|---|
| Model katmanları | vLLM, NVFP4, Marlin backend, prefix caching, FP8 KV cache |
| LiteLLM | Tek adres, Anthropic ↔ OpenAI çevirisi, katman fallback'i, kullanım logu |
| llama-swap | Katmanı istek anında açar, çakışanı kapatır, boştayı düşürür — `--with-swap` |
| Claude Code | Yerel kapıya bağlı; telemetri ve bulut erişimi kapalı |
| MCP sunucuları | filesystem, git, fetch, context7, playwright, memory, sequential-thinking — hepsi konteyner |
| Skill'ler | Superpowers (TDD, sistematik hata ayıklama, plan çıkarma) |
| Bilgi tabanı | Obsidian + claude-obsidian (15 skill) — `--with-wiki` |
| Ajan kabı | NVIDIA NemoClaw + OpenShell, model yerel kapıdan — `--with-nemoclaw` |
| Kontrol merkezi | Agent Canvas: konuşmalar, otomasyonlar, ACP alt ajanları — `--with-canvas` |
| Ekstralar | Open WebUI, Qdrant, Whisper — `--with-extras` |

---

## Portlar

Hepsi varsayılan olarak `127.0.0.1`'e bağlıdır; hiçbiri kurulumdan sonra kendiliğinden ağa açılmaz.

| Port | Servis | Ne zaman açılır | Değiştir |
|---|---|---|---|
| `4000` | **LiteLLM kapı** — tek API adresi | her zaman | `GATEWAY_BIND` |
| `8002` | `haiku` (vLLM) | `demo`, `daily` | — |
| `8000` | `sonnet` (vLLM) | `demo`, `daily` | — |
| `8888` | `opus` (vLLM) | `daily` | — |
| `8001` | `fable` (vLLM) | `fable` | — |
| `8081` | llama-swap durum ucu | `--with-swap` | `SWAP_PORT` |
| `8300` | Agent Canvas paneli | `--with-canvas` | `CANVAS_PORT`, `CANVAS_BIND` |
| `8080` | NemoClaw OpenShell gateway | `--with-nemoclaw` | NemoClaw yönetir |
| `18789` | NemoClaw paneli | `--with-nemoclaw` | NemoClaw atar |
| `3000` | Open WebUI | `--with-extras` | `WEBUI_BIND` |
| `6333` | Qdrant | `--with-extras` | — |
| `9000` | Whisper | `stt` profili | — |

İki tanesi bilerek kaydırıldı. Agent Canvas kendi içinde 8000 dinler ama o portu `sonnet` kullandığı için dışarı 8300'den açılır. llama-swap da 8080 yerine 8081'e alındı, çünkü 8080 NemoClaw'ın OpenShell gateway'inin varsayılanı — `--all` ile ikisi birden kurulduğunda çakışırlardı.

---

## Bellek yönetimi

Spark'ta 128 GB bellek CPU ve GPU arasında paylaşılır. Sığmayan bir model makineyi kilitler; yavaşlatmaz, kilitler.

| Profil | Açık katmanlar | Yaklaşık |
|---|---|---|
| `demo` | haiku + sonnet | ~45 GB |
| `daily` | haiku + sonnet + opus | ~65 GB |
| `fable` | fable | ~67 GB |

`spark status` çıktısında kullanım 120 GB'yi geçmemeli. Geçerse `/srv/ai/compose/.env` içindeki ilgili `*_MEM` değeri 0.05 düşürülüp `spark up daily` çalıştırılır.

GB10'da `nvidia-smi --query-gpu=memory.*` çoğu sürümde `Not Supported` döner: bellek GPU'ya ayrılmış değil, CPU ile ortaktır. `spark` bunu görünce `/proc/meminfo` üzerinden okur, o yüzden `Bellek` satırı kimi makinede GiB cinsinden birleşik kullanım gösterir. Ölçtüğün sayı aynı sayıdır, yalnızca kaynağı değişir.

`gpu_memory_utilization` toplamı 0.75'in üzerine çıkarılmamalı; topluluk raporlarında 0.8 üstü değerler kilitlenmeye yol açıyor.

---

## Katman değişimi — llama-swap

`--with-swap` (ya da `--all`) ile [llama-swap](https://github.com/mostlygeek/llama-swap) kapı ile model sunucuları arasına girer. `spark up fable` yazmaya gerek kalmaz: Claude Code içinde `/model fable` dersin, llama-swap çakışan katmanları kapatır, fable'ı açar, boşta kalanı süresi dolunca düşürür.

![llama-swap ile katman değişimi](docs/figures/spark-llamaswap-dongu.png)

```bash
spark up swap     # llama-swap düzenini aç
spark swap        # hangi katman ayakta, bellek ne durumda
```

Kurulum bittiğinde ana katman bir kez ısıtılır, böylece ilk gerçek isteğin beklemez.

**Nasıl kurulu.** Konteynerleri compose oluşturur ama başlatmaz; llama-swap yalnızca `docker start` / `docker stop` eder. Böylece bütün vLLM bayrakları `docker-compose.yml` ve `.env` içinde tek yerde kalır, llama-swap tarafında kopyası olmaz. Grup kuralı belleğin gerçeğini yansıtır: `haiku + sonnet + opus` birlikte durur, `fable` açılınca üçü de düşer.

| Ayar | Varsayılan | Ne yapar |
|---|---|---|
| `SWAP_TTL` | `1800` | Bir katman kaç saniye boşta kalınca düşer |
| `SWAP_TTL_<KATMAN>` | — | Katman başına ayrı süre (`SWAP_TTL_FABLE=900`) |
| `SWAP_HEALTH_TIMEOUT` | `2100` | İlk açılışta çekirdek derlemesi için tanınan süre |
| `SWAP_BIND` | `127.0.0.1` | llama-swap'in dinlediği adres |

**Üç dürüst not.**

İlk açılış hâlâ 3-4 dakika sürüyor; llama-swap bunu ortadan kaldırmıyor, yalnızca ne zaman olacağına kendisi karar veriyor. Soğuk bir katmana ilk kez geçerken Claude Code kendi zaman aşımına takılabilir; o katmanı önce `spark ask "merhaba" fable` ile ısıtmak bu sorunu bitirir.

llama-swap'in Docker API istemcisi yok — komutu düz `exec` ediyor. Bu yüzden konteynere hem `docker.sock` hem de statik `docker` CLI ikilisi bağlanıyor ve konteyner host'un `docker` grubuna alınıyor. Soketi görebilen bir konteyner pratikte makinede root demektir; makineyi ekibe açıyorsan bunu bilerek yap.

llama-swap'te kimlik doğrulama yok. Bu yüzden `SWAP_BIND` varsayılan olarak `127.0.0.1`; kapı (LiteLLM) ona ağ içinden `llamaswap:8080` ile ulaştığı için dışarı açmaya gerek de yok. Ekibe açarken açman gereken tek şey kapının kendisi.

**Grup kuralı hakkında bir uyarı.** Aynı yığını kuran bir topluluk deposu grup kuralını kapatmış; gerekçesi, beklenmedik model değişimlerinin ölçüm koşularını bozmasıydı. Bizde grup kuralı asıl işi yapan şey (üç katmanın birlikte durabilmesi onunla mümkün), o yüzden açık bırakıldı. Uzun bir karşılaştırma koşusu yapacaksan `/srv/ai/compose/llamaswap.yaml` içindeki `routing:` bloğunu kaldır — llama-swap o zaman tek model kuralına döner, katmanlar birbirini beklemez ama aynı anda yalnız biri ayakta kalır.

---

## Ekibe açmak

Kapı varsayılan olarak yalnızca yerel makineden erişilebilir. Ağa açmak için `/srv/ai/compose/.env`:

```
GATEWAY_BIND=0.0.0.0
LITELLM_KEY=<uzun-bir-anahtar>
```

`spark up daily` ile yeniden başlatılır. İstemci tarafında: OpenAI uyumlu uç `http://<spark-ip>:4000/v1`, model adı `opus`. Claude Code için `ANTHROPIC_BASE_URL=http://<spark-ip>:4000`.

Ofis dışı erişim için Tailscale önerilir — port açmayı ve sabit IP'yi gerektirmez.

---

## Ajanlar arası işbirliği

Aynı kapıdan geçen iki ajan hâlâ birbirinden habersiz çalışabilir. İşbirliğini kuran şey ortak
bir sözleşmedir ve o sözleşme bilgi tabanında durur.

![İşbirliği akışı](docs/figures/spark-isbirligi-akisi.png)

Kurallar `~/vault/kurallar/` altında dört dosyadadır: `kod-standartlari.md`, `test-kurallari.md`,
`pr-kurallari.md`, `yazim-kurallari.md`. Kurulum bunları taslak olarak koyar, varsa üzerine
yazmaz. **Hiçbir ajan tanımı bu metni kopyalamaz, yerini gösterir** — kopya eskir, tek kaynak
eskimez. Bir kuralı vault'ta değiştirdiğinde bütün ajanlar o an yeni kurala bağlanır.

Üç rol kurulur ve kimse kendi işini onaylamaz:

| Rol | Yapar | Yapmaz |
|---|---|---|
| `spark-kod` | kod yazar, değiştirir | test yazmaz, kendini onaylamaz |
| `spark-test` | test yazar ve **çalıştırır** | kodu düzeltmez, geri devreder |
| `spark-denetci` | denetler, PR açıklaması hazırlar | kod yazmaz, **birleştirmez** |

**Aynı roller iki tarafta da çalışır.** Kurulum tek kaynaktan iki sürüm üretir: host'taki
Claude Code için `~/.claude/agents/`, Agent Canvas için `/srv/ai/data/canvas/agents/` (kabın
içinde `~/.openhands/agents/`). Canvas her konuşma başlarken bu dizini kendiliğinden tarayıp
rolleri devir kaydına yazar, yani `spark-kod`'a görev verilebilir. İki sürüm arasındaki tek
fark iki alan: kural yolu (`~/vault` / `/vault`) ve model adı (`opus` / `litellm_proxy/opus`).

**Kurulum gerekli ayarı kendi yapar.** Canvas ayağa kalkınca `PATCH /api/settings` ile iki şey
tohumlanır: alt ajan devri açılır (`enable_sub_agents`, varsayılanı kapalıdır ve kapalıyken
devir aracı hiç yüklenmez) ve model yerel kapıya bağlanır. Yazmakla yetinmeyip geri okuyup
doğrular; tutmazsa uyarır ve elle yapılacak adımı yazar. `spark canvas` bu ayarı her seferinde
canlı okuyup gösterir, yani "açık sanıyordum" durumu olmaz.

Kuralları düzenlemek için dosyaları doğrudan aç, ya da `wiki` komutuyla bilgi tabanında çalış.

İki dürüst sınır. Proje kökündeki `AGENTS.md` insan içindir; Canvas onu **otomatik okumaz**
(kaynak kodda yalnızca dosya listesi sıralamasında geçiyor), sözleşmeyi taşıyan şey rol
dosyalarının kendisidir. İkincisi, roller arasındaki devir **A2A değildir**: OpenHands
deposunda `a2a` araması sıfır sonuç veriyor, NemoClaw'da da yok. Devir tek makinede, tek
konuşma içinde, SDK'nın kendi devir kaydı üzerinden olur. Ayrıntı: [docs/MIMARI.md](docs/MIMARI.md)

---

## Agent Canvas — ajan kontrol merkezi

`--with-canvas` (ya da `--all`) ile [Agent Canvas](https://github.com/OpenHands/OpenHands) kurulur: konuşmalar, dosyalar, terminal, model ayarları ve otomasyonlar tek panelden yönetilir. Otomasyonlar webhook ve zamanlayıcıyla tetiklenir — PR incelemesi, depo gözcüsü gibi işleri buraya kurarsın.

```bash
spark up canvas    # aç
spark canvas       # adres, panel anahtarı, girilecek ayarlar
```

Panel `http://localhost:8300/canvas` adresinde (kendi portu 8000 ama onu `sonnet` kullanıyor).

**Ajan kabın içinde koşar**, makinenin dosya sistemini görmez; yalnızca `/projects` altına bağladığımız klasörü görür (varsayılan `~/projects`, `--projects PATH` ile değiştirilir). `docker.sock` gerekmez, `--privileged` gerekmez.

**Claude Code'u alt ajan yapabilirsin.** Settings → Agent → Preset: Claude Code. Sarmalayıcı imajın içinde hazır; kap zaten bizim kapıya bakacak şekilde kurulu:

```
Agent Canvas  →  Claude Code (ACP)  →  LiteLLM :4000  →  yerel katman
```

İki not. Model ayarı **env değişkeniyle yapılamıyor** — ilk açılışta Settings → LLM'e bir kez elle girilir (`spark canvas` tam olarak ne yazacağını gösterir): Model `litellm_proxy/opus`, Base URL `http://litellm:4000`, API Key `.env` içindeki `LITELLM_KEY`. İkincisi, Claude aboneliğinin OAuth token'ı bu kuruluma **verilmez**: üst akış belgeleri, `ANTHROPIC_BASE_URL` ile birlikte kullanıldığında token'ın kimlik doğrulamasının bozulduğunu söylüyor. Ya abonelik ya yerel kapı; burada tercih yerel kapı.

Ayrıntılı tasarım ve ajan rolleri: **[docs/MIMARI.md](docs/MIMARI.md)**

---

## NemoClaw ajan kabı

`--with-nemoclaw` (ya da `--all`) ile [NVIDIA NemoClaw](https://github.com/NVIDIA/NemoClaw) (Apache-2.0) kurulur: ajanı OpenShell sanal kabında çalıştırır, üstüne ağ politikası, anlık görüntü ve yaşam döngüsü yönetimi koyar. Varsayılan ajanı OpenClaw.

![NemoClaw kabı](docs/figures/spark-nemoclaw-kabi.png)

Model buluttan değil bizim kapımızdan gelir: LiteLLM `:4000`, NemoClaw'a OpenAI uyumlu uç (`NEMOCLAW_PROVIDER=custom`) olarak kaydedilir; kabın içinden `inference.local` adıyla görünür.

```bash
nemoclaw spark connect          # kaba bağlan, ajanı çalıştır
nemoclaw spark logs --follow    # canlı log
nemoclaw spark dashboard-url    # tarayıcı paneli
nemoclaw spark status           # kap, model, ağ politikası
nemoclaw spark policy list      # ağ politikası kuralları
```

İki dürüst not. Bu, projenin "makineye tek şey kurulur" kuralından tek sapmadır: NemoClaw kendi CLI'sini host'a bırakır (Node.js ≥22.19 + `~/.local/bin/nemoclaw`), çünkü dağıtım biçimi bu; ajanın kendisi, gateway ve kap yine konteynerde. İkincisi, Anthropic uyumlu yol da mevcut ama OpenClaw o yolda akışta native `tool_use`/`emit_ok` doğrulaması arıyor; yerel modellerde kırılgan olduğu için OpenAI uyumlu yol seçildi.

---

## Obsidian + bilgi tabanı

`--with-wiki` ile [AgriciDaniel/claude-obsidian](https://github.com/AgriciDaniel/claude-obsidian) (MIT) kurulur: Claude Code eklentisi ve 15 Agent Skill. Obsidian uygulaması ARM64 AppImage olarak yüklenir — Spark aarch64 olduğu için resmî `.deb` kullanılamaz.

```bash
wiki                        # vault'ta Claude Code aç
wiki "auth kararı neydi?"   # vault'a soru sor
obsidian                    # uygulamayı aç
```

Kaynak `~/vault/inbox/` altına konur, `/claude-obsidian:wiki-ingest` ile işlenir; `wiki-query` yalnızca vault'taki kanıttan cevap üretir.

Retrieval BM25 ile yerel ve deterministiktir — embedding modeli gerekmez, ek bellek kullanmaz. Mevcut bir vault varsa `adopt` akışıyla içeriğe dokunmadan devralınır.

Sınırlar: `autoresearch` skill'i internet erişimi ister; PDF/EPUB için metadata ve hash tutulur, semantik çıkarım yapılmaz; Obsidian uygulaması masaüstü oturumu gerektirir (headless kurulumda vault ve `wiki` komutu yine çalışır).

---

## Genişletme

Temel kurulum oturduktan sonra değerlendirilebilecek bileşenler:

1. **PR inceleme botu** — self-host, yerel kapıya bağlı; her PR'a otomatik inceleme yorumu
2. **Otonom kod ajanı** — issue'dan PR'a çalışan, sandbox'lı ajan
3. **Doküman arama (RAG)** — Qdrant + embedding modeli; ana katmanla birlikte çalışabilir
4. **Toplantı notları** — Whisper ile ses → yazı, ardından özet
5. **Gözlemlenebilirlik** — istek süreleri, kullanım, maliyet panosu
6. **Otomatik başlatma** — systemd birimiyle açılışta `spark up daily`

---

## Bilinen kısıtlar

- Dört katman aynı anda çalışamaz; `fable` diğerlerini kapatır. `--with-swap` bunu elle yapmaktan kurtarır ama fiziği değiştirmez.
- Soğuk bir katmanın ilk açılışı 3-4 dakika sürer (GPU çekirdeği derlemesi); llama-swap bunu gizlemez.
- NVFP4 çekirdekleri sm_121'de Marlin backend olmadan bozuk çıktı üretir.
- Yoğun (dense) 70B+ modeller bu donanımda kullanılamaz (~2-5 tok/s).
- Kullanılan vLLM imajı ve model reçeteleri topluluk tarafından sürdürülüyor; sürüm etiketleri `.env` içinde tek yerden güncellenir.

---

## Bileşenler

| Bileşen | Kaynak |
|---|---|
| vLLM (GB10 derlemesi) | `ghcr.io/aeon-7/aeon-vllm-ultimate` |
| LiteLLM | `ghcr.io/berriai/litellm` |
| llama-swap | `ghcr.io/mostlygeek/llama-swap` (`unified-cuda13`, arm64) |
| Agent Canvas | `ghcr.io/openhands/agent-canvas` (`1.19.0`, arm64) |
| MCP sunucuları | `mcp/*` Docker kataloğu |
| Skill kütüphanesi | `obra/superpowers` |
| Bilgi tabanı | `AgriciDaniel/claude-obsidian` |
| Ajan kabı | `NVIDIA/NemoClaw` + `NVIDIA/OpenShell` |
