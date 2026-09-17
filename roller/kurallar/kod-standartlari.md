# Kod standartları

Bu dosya şirketin kod kurallarının tek kaynağıdır. Bütün ajanlar — makinedeki Claude Code,
Agent Canvas kabındaki ajan, NemoClaw kabındaki ajan — kod yazmadan önce burayı okur.
Kural değişikliği burada yapılır; ajan tanımlarında ya da skill dosyalarında kopyası tutulmaz.

## Dil ve isimlendirme

Değişken, fonksiyon, sınıf ve dosya adları İngilizce. Yorumlar ve commit mesajları Türkçe.
Kısaltma kullanma: `usr` değil `user`, `calc` değil `calculate`. Tek harfli ad yalnızca
döngü sayacında kabul edilir.

## Yapı

Bir fonksiyon tek iş yapar. Elli satırı geçen fonksiyon parçalanır. Dört seviyeden derin
girinti, yanlış kurgulanmış bir akışın işaretidir; erken dönüşle düzleştir.

Yeni bağımlılık eklemeden önce sor. Standart kütüphaneyle üç satırda çözülen bir iş için
paket kurulmaz.

## Hata yönetimi

Yutulan istisna yasak. Yakalıyorsan ya işliyorsundur ya da bağlam ekleyip yeniden
fırlatıyorsundur. Boş `except:` bloğu incelemede geri döner.

Kullanıcıya gösterilen hata mesajı ne olduğunu ve ne yapılacağını söyler. "Bir hata oluştu"
yeterli değildir.

## Sınırlar

Dış girdi sınırda doğrulanır: API ucu, dosya okuma, ortam değişkeni. İçeride doğrulanmış
veri dolaştığı varsayılır.

Sır kodda durmaz. Ortam değişkeni ya da sır deposu kullanılır; `.env` depoya girmez.

## Python

Anaconda yerine proje sanal ortamı (`.venv/`). Biçimlendirme `black`, içe aktarma sırası
`isort`. Tip ipucu yeni yazılan her fonksiyonda zorunlu, eski koda dokunurken eklenir.

## Mekanik denetim

Aşağıdaki satırlar kural kapısında kendiliğinden denetlenir: commit, itme ve PR bu kapıdan
geçmeden ilerlemez. Kapıya sığmayan kurallar `spark-denetci` incelemesinde okunarak bakılır.

| Kural | Nasıl denetlenir | Kim |
|---|---|---|
| Boş `except`, yutulan istisna, bağlamsız yeniden fırlatma | ruff E722, S110, BLE001, B904 | kapı |
| Elli satırı geçen fonksiyon, dört seviyeden derin girinti | ruff PLR0915 (50 ifade), PLR1702 (4 blok), C901 | kapı |
| Kodda sır, `.env` depoda | ruff S105 S106 S107, kapının sır taraması; `.env` dosyası engellenir | kapı |
| Tip ipucu, black biçimi, isort sırası | ruff ANN, `ruff format --check`, ruff I | kapı |
| Tek harfli ad, PEP8 adlandırma | ruff E741, N | kapı |
| Kabuk betiklerinde gerçek hata | shellcheck, uyarı düzeyi (`KURAL_KAPISI_SHELLCHECK=info` ile sıkılaşır) | kapı |
| İngilizce ad, kısaltma yasağı, Türkçe yorum | okunarak | spark-denetci |
| Yeni bağımlılık sorulur, sınırda doğrulama, hata mesajı içeriği | okunarak | spark-denetci |

Ayar dosyası bu klasörde: `denetim/ruff.toml`. Kural değişince önce bu metin, sonra o dosya değişir.
