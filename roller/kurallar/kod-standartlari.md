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
