# Supabase Setup Guide

Bu dokümantasyon, Daily Flow uygulamasına Supabase entegrasyonunu nasıl yapacağınızı açıklar.

## Adım 1: Supabase Projesi Oluşturma

1. [Supabase](https://supabase.com) hesabı oluşturun (ücretsiz)
2. Yeni bir proje oluşturun
3. Proje oluşturulduktan sonra **Settings > API** sayfasına gidin
4. Şu bilgileri not edin:
   - **Project URL** (örn: `https://abcdefghijklmnop.supabase.co`)
   - **anon/public key** (JWT token)

## Adım 2: Database Şemasını Oluşturma

1. Supabase Dashboard'da **SQL Editor**'a gidin
2. `supabase_schema.sql` dosyasının içeriğini kopyalayın
3. SQL Editor'a yapıştırın ve **Run** butonuna tıklayın
4. Tüm tablolar ve RLS politikaları oluşturulacak

## Adım 3: Sign in with Apple Ayarları

1. Supabase Dashboard'da **Authentication > Providers** sayfasına gidin
2. **Apple** provider'ını bulun ve **Enable** edin
3. Apple Developer Console'dan:
   - **Services ID** oluşturun
   - **Callback URL** ekleyin: `https://YOUR_PROJECT.supabase.co/auth/v1/callback`
   - **Key ID** ve **Private Key** oluşturun
4. Bu bilgileri Supabase Apple provider ayarlarına girin

## Adım 4: Flutter Config Dosyasını Güncelleme

1. `lib/config/supabase_config.dart` dosyasını açın
2. `YOUR_SUPABASE_URL` ve `YOUR_SUPABASE_ANON_KEY` değerlerini gerçek değerlerle değiştirin:

```dart
class SupabaseConfig {
  static const String supabaseUrl = 'https://abcdefghijklmnop.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';
}
```

## Adım 5: Paketleri Yükleme

Terminal'de şu komutu çalıştırın:

```bash
flutter pub get
```

## Adım 6: iOS Ayarları (Sign in with Apple için)

1. Xcode'da `ios/Runner.xcodeproj` dosyasını açın
2. **Signing & Capabilities** sekmesine gidin
3. **+ Capability** butonuna tıklayın
4. **Sign in with Apple** ekleyin

## Adım 7: Test Etme

1. Uygulamayı çalıştırın
2. Sign in with Apple ile giriş yapın
3. Task'ların Supabase'e kaydedildiğini kontrol edin

## Sorun Giderme

### Supabase bağlantı hatası
- Config dosyasındaki URL ve key'lerin doğru olduğundan emin olun
- Supabase projenizin aktif olduğunu kontrol edin

### RLS (Row Level Security) hatası
- SQL şemasının tamamının çalıştırıldığından emin olun
- RLS politikalarının doğru oluşturulduğunu kontrol edin

### Sign in with Apple hatası
- Apple Developer Console ayarlarını kontrol edin
- Supabase Apple provider ayarlarını kontrol edin
- iOS capabilities'in doğru eklendiğini kontrol edin

## Notlar

- İlk 1,000 kullanıcıya kadar **ücretsiz** plan yeterli
- Veriler hem local (Hive) hem remote (Supabase) olarak saklanır
- Offline modda local cache kullanılır, online olunca sync yapılır
