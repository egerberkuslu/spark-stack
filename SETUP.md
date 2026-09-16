# Kurulum

DGX Spark'ta sıfırdan çalışan bir kuruluma kadar adım adım.
Üniversite hattında (1 Gbit) süreler aşağıdaki gibidir.

| Kurulum | Katmanlar | İndirme | Süre |
|---|---|---|---|
| `--demo` | haiku + sonnet | ~45 GB | 15-20 dk |
| varsayılan | + opus | ~65 GB | 30-40 dk |
| `--all` | + fable, Obsidian, Open WebUI | ~132 GB | 50-70 dk |

Süreler indirmeyi ve ilk açılıştaki GPU çekirdeği derlemesini kapsar.

---

## Katmanlar ve modeller

| Katman | HuggingFace deposu | Aile | Aktif param. | Kullanım | Bellek | Port |
|---|---|---|---|---|---|---|
| `haiku` | `unsloth/Qwen3.6-35B-A3B-NVFP4` | Qwen | 3B (MoE) | Anlık cevap, commit mesajı, dosya özeti | ~25 GB | 8002 |
| `sonnet` | `nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4` + DSpark | NVIDIA | 3B (MoE) | Günlük iş, ajan döngüleri — **~108 tok/s** | ~20 GB | 8000 |
| `opus` | `unsloth/Qwen3.8-27B-NVFP4` + MTP | Qwen | 27B (dense) | Ciddi kod, ajan işleri — **varsayılan** | ~20 GB | 8888 |
| `fable` | `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` | NVIDIA | 12B (MoE) | En zor işler — **tek başına çalışır** | ~67 GB | 8001 |

Depolar `/srv/ai/compose/.env` içinde `HAIKU_REPO`, `SONNET_REPO`, `OPUS_REPO`, `FABLE_REPO` olarak tanımlıdır; başka bir model denemek için tek yerden değiştirilir.

Claude Code içinde `/model haiku`, `/model sonnet`, `/model opus` ile geçiş yapılır. `fable` için önce terminalde `spark up fable` — diğer katmanlar otomatik kapanır.

---

## Ön hazırlık: HuggingFace anahtarı

Model ağırlıkları HuggingFace'ten iniyor; ücretsiz bir erişim anahtarı gerekiyor.

1. [huggingface.co](https://huggingface.co) — hesabın yoksa üye ol
2. Sağ üst profil → **Settings** → **Access Tokens**
3. **+ Create new token** → Token type: **Read** → isim ver → **Create token**
4. `hf_` ile başlayan değeri kopyala

Script kurulum sırasında sorar; önceden vermek için `--token hf_xxx`.

> Anahtarı yapıştırdığında ekranda görünmez — güvenlik gereği gizlenir. Enter'a bas.

---

## Kurulum

```bash
git clone https://github.com/egerberkuslu/spark-stack
cd spark-stack
bash install.sh --all --token hf_xxx
```

Yalnızca demo için:

```bash
bash install.sh --demo --token hf_xxx
```

Script 12 adımda ilerler. Model adımında hangi katmanın hangi modeli indirdiği açıkça listelenir:

```
┌─ [5/12] Model ağırlıkları
  │
  │  KATMAN  MODEL                                  BOYUT   KULLANIM
  │  ──────  ─────                                  ─────   ────────
  │  haiku   unsloth/Qwen3.6-35B-A3B-NVFP4                    ~25 GB  hızlı Qwen · anlık cevap
  │  sonnet  nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4 ~20 GB  hızlı NVIDIA · ~108 tok/s
  │  opus    unsloth/Qwen3.8-27B-NVFP4                        ~20 GB  Qwen kalite · ciddi kod
  │
  │ ✓ haiku indi — 24.9G
  │ ✓ sonnet indi — 19.6G
  │ ✓ sonnet taslak indi — spekülatif decode aktif
  │ opus ← unsloth/Qwen3.8-27B-NVFP4  (~20 GB)
└─ [████████████████············]  58%  1840s · toplam 34:12 · kalan 7 adım
```

Tüm ayrıntı `/srv/ai/install.log` dosyasına yazılır.

Kurulum kesilirse `--resume` ile kaldığı yerden devam eder; indirilmiş ağırlıklar tekrar indirilmez.

---

## Doğrulama

```bash
source ~/.bashrc
spark status
```

Beklenen çıktı:

```
  haiku    ÇALIŞIYOR  127.0.0.1:8002  unsloth/Qwen3.6-35B-A3B-NVFP4
  sonnet   ÇALIŞIYOR  127.0.0.1:8000  nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4
  opus     ÇALIŞIYOR  127.0.0.1:8888  unsloth/Qwen3.8-27B-NVFP4
  fable    kapalı     nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
  kapı     ÇALIŞIYOR  http://localhost:4000

  GPU belleği : 78420 MiB, 122570 MiB
```

İlk kullanım:

```bash
mkdir ~/proje && cd ~/proje && claude
```

Örnek istek:

```
FastAPI ile küçük bir todo servisi yaz, pytest testlerini ekle ve çalıştırıp doğrula
```

---

## Günlük kullanım

```bash
spark status              # servis durumu, bellek, disk
spark models              # katman → model eşlemesi ve durum
spark up demo             # haiku + sonnet
spark up daily            # haiku + sonnet + opus
spark up fable            # yalnız fable
spark logs opus           # canlı log
spark ask "merhaba"       # hızlı test
spark down                # tüm servisleri durdur
```

Sonradan ekleme:

```bash
spark pull opus && spark up daily          # katman ekle
bash install.sh --with-fable --resume      # dördüncü katman
bash install.sh --with-wiki --resume       # Obsidian + bilgi tabanı
bash install.sh --with-extras --resume     # Open WebUI + Qdrant + Whisper
```

---

## Obsidian + bilgi tabanı

`--with-wiki` (veya `--all`) ile kurulur:

- **Obsidian** uygulaması — ARM64 AppImage, çünkü Spark aarch64 ve resmî `.deb` yalnızca amd64 için yayınlanıyor
- **claude-obsidian** — Claude Code eklentisi + 15 Agent Skill
- Vault: `~/vault` (değiştirmek için `--vault ~/notlar`)

```bash
wiki                        # vault'ta Claude Code aç
wiki "auth kararı neydi?"   # vault'a soru sor
obsidian                    # uygulamayı aç
```

Kaynak eklemek için dosyayı `~/vault/inbox/` altına koy, `wiki` çalıştır, `/claude-obsidian:wiki-ingest` gir.

Mevcut bir Obsidian vault'un varsa script `adopt` akışını kullanır ve içeriğe dokunmaz.

---

## Sorun giderme

| Belirti | Çözüm |
|---|---|
| Servis 10 dakikadır açılmıyor | Beklenen davranış — ilk açılışta GPU çekirdekleri derleniyor. Sonraki açılışlar 3-5 dk. |
| `docker: permission denied` | `newgrp docker`, ardından `bash install.sh --resume` |
| `docker --gpus all çalışmıyor` | NVIDIA Container Toolkit eksik. Script kurmayı dener; başarısızsa `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker` |
| Sürücü kuruldu, yeniden başlatma istendi | `sudo reboot`, sonra `cd spark-stack && bash install.sh --resume` |
| İndirme takıldı | Ctrl+C → `bash install.sh --resume`. Sürmezse `.env` içindeki `HF_WORKERS` değerini 4'e düşür. |
| Model anlamsız karakter üretiyor | `.env` içinde `VLLM_NVFP4_GEMM_BACKEND=marlin` olduğunu doğrula |
| Makine kilitlendi | Bellek taşmış. `.env` içindeki ilgili `*_MEM` değerini 0.05 düşür, `spark up daily` |
| Servis açılmıyor | `spark logs <katman>` |

Ayrıntılı kayıt: `/srv/ai/install.log`

---

## Kaldırma

```bash
bash install.sh --uninstall
```

Konteynerleri, model ağırlıklarını ve `/srv/ai` dizinini siler. Vault ve proje dosyaları korunur.
