# Kismet · Private Detector (TFLite)

Bu dosya, Bumble'ın açık kaynak **Private Detector** modelinin telefonda çalışacak şekilde dönüştürülmüş halidir.

- Kaynak: https://github.com/bumble-tech/private-detector (Apache License 2.0, © Bumble)
- Mimari: EfficientNetV2-M, giriş 480×480 RGB
- Değişiklik: SavedModel → TensorFlow Lite (TFLITE_BUILTINS), ağırlıklar dinamik aralıklı int8 nicemlemeyle küçültüldü (213 MB → 56 MB).
  Giriş float32 [1, 480, 480, 3] olacak şekilde sarıldı; çıktı [1, 2], 0. değer müstehcenlik olasılığı.
- Ön işleme: en-boy oranı korunarak 480 kenara küçült, ortalayıp 128 griyle doldur, (piksel − 128) / 128.
- Doğrulama: aynı görüntülerde orijinal modelle en büyük fark 0,0033.
- Kullanım: Kismet uygulaması görüntüyü yalnızca telefonda tarar; görüntü cihazdan çıkmaz.

Lisans metni: LICENSE-private-detector.txt
