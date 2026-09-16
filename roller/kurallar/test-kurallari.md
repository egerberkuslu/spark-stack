# Test kuralları

Testi yazan ajan, kodu yazan ajandan başkasıdır. Bu bilerek böyledir: kodu yazan, kendi
varsayımını test etmeye eğilimlidir. Test eden ajan kodu değil **davranışı** okur.

## Ne test edilir

Her yeni fonksiyon için en az bir test. Düzeltilen her hata için, o hatayı yeniden üreten
bir test — önce kırmızı olduğunu gör, sonra düzelt.

Sınır durumları asıl testtir: boş girdi, tek eleman, sıfır, negatif, çok büyük değer,
eşzamanlı çağrı. Mutlu yol tek başına test sayılmaz.

## Ne test edilmez

Dış servisin kendi davranışı taklit edilir, doğrulanmaz. Üçüncü taraf kütüphanenin işini
test etme; kendi kodunun o kütüphaneyi doğru çağırdığını test et.

Gerçek ağ çağrısı, gerçek veritabanı ve gerçek saat testte kullanılmaz. Saat enjekte edilir,
ağ taklit edilir.

## Biçim

Test adı ne yaptığını söyler: `test_returns_empty_list_when_no_match` gibi. `test_1`,
`test_case_a` incelemede geri döner.

Bir test tek şey doğrular. Üç iddia (assert) içeren bir test, aslında üç testtir.

Testler birbirinden bağımsızdır; sıradan etkilenmez, paylaşılan durum bırakmaz.

## Geçme ölçütü

Test takımı yeşil olmadan iş bitmiş sayılmaz. "Bende çalışıyordu" kabul edilmez; test eden
ajan komutu çalıştırır ve çıktıyı rapora koyar.

Atlanan (skip) test bir borçtur: neden atlandığı ve ne zaman açılacağı yazılır.
