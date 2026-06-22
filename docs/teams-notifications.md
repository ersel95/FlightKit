# Teams Bildirimleri — Yayın Sonrası Otomatik Mesaj

> Bir yayın (batch) tamamlandığında, çıkılan sürüm bilgisini Microsoft Teams'teki
> bir sohbete otomatik gönderen özelliğin tam dökümü. FlightKit'te uygulandı.

## Amaç

Bir uygulama TestFlight / App Store'a yüklendikten sonra ekibi haberdar etmek
için Teams'e elle mesaj atmak gerekiyordu. Bu özellik, **batch'in tüm yüklemeleri
bittiğinde** seçili Teams sohbetine yayınlanan sürümü **tek bir özet mesajla**
otomatik gönderir.

Gönderilen mesaj örneği:

```
🚀 <App adı> sürümü yayınlandı
• Test → TestFlight · 1.2.0 (45)
• Prod → App Store · 1.2.0 (45)
```

## Neden "yerel uygulamayı sürükleme" yöntemi?

Teams'e dışarıdan mesaj atmanın olağan yolları **Incoming Webhook** veya **Power
Automate Workflows**'tur. Kurumsal Teams'lerde bunların ikisi de org politikasıyla
kapatılmış olabilir (webhook connector'ları engelli, Power Automate portalına
erişim yok). Böyle bir ortamda sunucu tarafı bir yol kalmaz.

FlightKit bu yüzden **yerel Teams masaüstü uygulamasını sürükler**:

1. Mesajı panoya (clipboard) koyar — kullanıcının mevcut panosunu önce yedekler.
2. Bir Teams **deep link**'i (`https://teams.microsoft.com/l/chat/…`) ile doğru
   sohbeti açar; bu, compose (yazma) kutusunu otomatik odaklar.
3. Teams'i öne getirir, kısa bir gecikme sonrası `⌘V` + `Return` tuşlarını
   **CGEvent** ile sentezler → mesaj yapışır ve gönderilir.
4. Panoyu eski içeriğiyle geri yükler.

> Bu UI seviyesinde, **en iyi çaba (best-effort)** bir yöntemdir; Teams arayüzü
> veya kısayolları değişirse bozulabilir. Pipeline'a asla hata fırlatmaz — sadece
> log'a yazar.

## Gereksinim: Erişilebilirlik (Accessibility) izni

Sentetik tuş göndermek için FlightKit'in **Accessibility** iznine ihtiyacı vardır.
FlightKit sandbox'lı değildir, bu yüzden izin verilince çalışır.

- İlk denemede izin yoksa FlightKit System Settings'i açar; oradan
  **System Settings → Privacy & Security → Accessibility** altında FlightKit'i
  işaretleyin.
- Xcode'dan çalışan **geliştirme** build'ine verilen izin her yeniden derlemede
  sıfırlanabilir; **notarize edilmiş yayın** sürümünde kalıcıdır.

## Kurulum

1. Teams'te haber vermek istediğiniz **sohbetin bağlantısını** alın: sohbet
   menüsündeki **⋯ → Kopyalama bağlantısı**. (Grup sohbeti veya kanal linki olur:
   `https://teams.microsoft.com/l/chat/19:…@thread.v2/conversations?context=…`)
2. FlightKit'te projeyi düzenleyin → **Teams** bölümü:
   - **Yayın sonrası Teams bildirimi**'ni açın.
   - **Teams sohbet bağlantısı** alanına linki yapıştırın.
   - **Test mesajı gönder** ile izni ve akışı bir kez doğrulayın.
3. Bundan sonra her batch'in tüm yüklemeleri bitince bildirim otomatik düşer.

## Saklama ve gizlilik

- Link, proje kataloğunda (`~/Library/Application Support/FlightKit/projects.json`)
  **yerel olarak** saklanır; repoya asla yazılmaz.
- Link o sohbete mesaj atma yetkisi verdiği için bir sır gibi değerlendirilir.

## İlgili kod

- `Services/TeamsNotifier.swift` — pano/deep-link/CGEvent akışı ve izin kontrolü.
- `Models/AppProject.swift` — `teamsChatLink`, `teamsNotifyEnabled`,
  `teamsNotificationsActive` (alanlar opsiyonel; eski `projects.json` bozulmadan
  açılır).
- `Views/ProjectEditorView.swift` — Teams bölümü ve Test butonu.
- `Views/ProjectDetailView.swift` — `notifyTeamsIfNeeded`, batch başına tek mesaj.

## Sınırlamalar

- Bildirim, batch'in **tüm bloklayıcı yüklemeleri** bittikten sonra (ASC işlemesini
  beklemeden) gönderilir; mesaj "yüklendi" bilgisidir, "işleme tamamlandı" değil.
- Tuş enjeksiyonu odağı bir an için Teams'e alır; bu yüzden env başına değil,
  **batch başına tek kez** gönderilir.
- Teams yavaş açılırsa `TeamsNotifier.focusDelay` (varsayılan 2.5 sn) artırılabilir.
