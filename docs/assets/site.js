(() => {
  const root = document.documentElement;
  const themeButton = document.getElementById('theme-toggle');
  const themeIcon = document.getElementById('theme-icon');
  const languageButton = document.getElementById('language-toggle');
  const languageCode = document.getElementById('language-code');
  const menuButton = document.getElementById('menu-toggle');
  const mobileMenu = document.getElementById('mobile-menu');
  const year = document.getElementById('year');
  if (year) year.textContent = new Date().getFullYear();

  const renderTheme = (theme) => {
    root.dataset.theme = theme;
    document.querySelectorAll('[data-theme-light][data-theme-dark]').forEach((preview) => {
      const url = theme === 'dark' ? preview.dataset.themeDark : preview.dataset.themeLight;
      if (preview.tagName === 'IMG') preview.src = url;
      else if (preview.tagName === 'A') preview.href = url;
    });
    if (themeIcon) themeIcon.textContent = theme === 'light' ? '☀' : '☾';
    if (themeButton) themeButton.setAttribute('aria-label', theme === 'light' ? 'Switch to dark theme' : 'Switch to light theme');
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'light' ? '#f4f4f4' : '#111111');
  };
  const storedTheme = localStorage.getItem('vamp-theme');
  renderTheme(storedTheme === 'light' ? 'light' : 'dark');
  themeButton?.addEventListener('click', () => {
    const next = root.dataset.theme === 'light' ? 'dark' : 'light';
    localStorage.setItem('vamp-theme', next);
    renderTheme(next);
  });

  const setMobileMenu = (open) => {
    if (!menuButton || !mobileMenu) return;
    mobileMenu.hidden = !open;
    mobileMenu.dataset.open = String(open);
    menuButton.setAttribute('aria-expanded', String(open));
    menuButton.setAttribute('aria-label', open ? 'Close navigation menu' : 'Open navigation menu');
    menuButton.textContent = open ? '×' : '☰';
  };
  menuButton?.addEventListener('click', () => setMobileMenu(mobileMenu.dataset.open !== 'true'));
  mobileMenu?.querySelectorAll('a').forEach((link) => link.addEventListener('click', () => setMobileMenu(false)));

  const translations = {
    tr: {
      'sync.surfaceKicker': 'Odaklı arayüz',
      'sync.permissionsKicker': 'macOS izinleri',
      'sync.footer': "Vamp Control ve Vamp Stream için Mac host’u.",
      'sync.getControl': "Vamp Control’u al",
      'sync.clientCopy': "Başka bir Mac, iPhone veya iPad’de Vamp Control kullan. iPhone ve iPad’de odaklı uygulama deneyimi için Vamp Stream’i seç.",
      'sync.clientTitle': "İstemcini seç.",
      'sync.downloadDmg': "DMG’yi indir",
      'sync.macCopy': "Kendi paketi, izinleri ve güvenilen cihaz deposu olan bir menü çubuğu uygulaması.",
      'sync.macTitle': "Mac’in bağlanmaya hazır.",
      'sync.downloadLead': "Ulaşmak istediğin Mac’e Vamp Sync’i kur, gerekli izinleri ver ve kimliğini doğruladıktan sonra istemcini onayla.",
      'sync.downloadTitle': "Sync’i Control veya Stream ile eşleştir.",
      'sync.accessCopy': "Klavye ve işaretçi kontrolü açık Erişilebilirlik izni gerektirir.",
      'sync.accessTitle': "Kontrol için gerekli.",
      'sync.screenCopy': "Ekran Kaydı, Sync’in seçilen uygulama penceresini eşleştirilmiş istemcinle paylaşmasını sağlar.",
      'sync.screenTitle': "Video için gerekli.",
      'sync.permissionsLead': "İzinleri doğrudan Vamp Sync’e ver. Hazır oluşu bildirir; macOS onayını asla atlamaz.",
      'sync.permissionsTitle': "İki izin, iki net iş.",
      'sync.inputCopy': "Klavye ve işaretçi komutlarını yalnız güven ve Erişilebilirlik onayından sonra ilet.",
      'sync.inputTitle': "İzin verildiğinde kontrol et",
      'sync.videoCopy': "Paylaşılacak Mac uygulamasını Control veya Stream’den seç. Sync o uygulama penceresini yakalar.",
      'sync.videoTitle': "Bir uygulama penceresi paylaş",
      'sync.pairCopy': "Vamp Control veya Vamp Stream’i onaylamadan önce cihazın tam parmak izini karşılaştır.",
      'sync.pairTitle': "Her yeni cihazı doğrula",
      'sync.surfaceLead': "Erişilebilirliği, izinleri, eşleme isteklerini, onaylı cihazları ve çalışma kontrollerini tek bir menü çubuğu arayüzünde gör.",
      'sync.surfaceTitle': "Tek host. İki istemci.",

      'sync.statTrust': "güven sınırı",
      'sync.statPermissions': "macOS izinleri",
      'sync.statTransport': "imzalı aktarım",
      'sync.statMenu': "menü çubuğu arayüzü",
      'sync.statLight': "Hafif",
      'sync.note': "macOS · menü çubuğu uygulaması · yalnız özel LAN veya Tailscale.",
      'sync.getStream': "Vamp Stream’i al",
      'sync.download': "Vamp Sync’i indir",
      'sync.heroCopy': "Vamp Sync, Vamp Control ve Vamp Stream için Mac host’undur. Bir kez eşleştir, bir uygulama penceresi seç ve başka bir Mac, iPhone veya iPad’den kullan. Her şey güvenilir LAN veya özel Tailscale ağında kalır.",
      'sync.title2': "senkron tut.",
      'sync.title1': "Host’u",
      'sync.eyebrow': "Mac host’u · Control + Stream",
      'sync.get': "Vamp Sync’i al",
      'sync.navDownload': "İndir",
      'sync.navPermissions': "İzinler",
      'sync.navSurface': "Yüzey",
      'stream.appWindow': "Bir uygulama penceresi",
      'sync.sceneHeading': 'Mac’in, bağlantıda.',
      'sync.scenePrivate': 'Özel',
      'sync.sceneHost': 'Erişmek istediğin Mac’te',
      'sync.sceneCaption': 'Bir uygulama penceresi. Her yerden.',
      'sync.diagram': "Tek Mac host’u. Ekranına uygun istemciyi seç.",
      'home.statSync': "Mac host’u",

      'nav.download': 'İndir',

      'footer.meta': 'yerel öncelikli · eş onaylı · barındırılan aktarıcı yok',
      'nav.assistant': 'Assistant', 'nav.stream': 'Stream',
      'nav.security': 'Güvenlik', 'nav.explore': 'Ürünleri keşfet',
      'home.eyebrow': "Tek Mac host’u · İstemcini seç",
      'home.title1': 'Mac’inle çalış.', 'home.title2': 'Her yerden.',
      'home.filmEyebrow': 'Vamp Stream · Ürün filmi',
      'home.filmTitle': 'Tek uygulama. Tam ihtiyacın olan yerde.',
      'home.filmCopy': 'Mac’indeki uygulama listesinden iPhone veya iPad’de odaklı canlı pencereye geç—Vamp Sync üzerinden, özel olarak.',
      'home.filmCaption': 'Mac’in. Yalnızca ihtiyacın olan.',
      'home.filmCta': 'Vamp Stream’i keşfet',
      'home.copy': "Mac’inde Vamp Sync ile başla. Uygulama pencerelerine özel ağın üzerinden Vamp Control veya Vamp Stream ile eriş. Özel AI çalışmaların için Vamp Assistant’ı ekle.",
      'home.syncCta': "Vamp Sync’i al", 'home.clientsCta': "İstemcini seç",
      'home.note': 'Açık kaynak · özel LAN veya Tailscale · barındırılan aktarıcı yok.',
      'home.statAssistant': 'AI çalışma alanı + uzaktan erişim', 'home.statStream': 'odaklı görsel istemci',
      'home.statControl': "Mac + iOS istemcisi",
      'families.kicker': 'Ürün aileleri', 'families.title': 'Doğru başlangıç noktasını seç.',
      'families.lead': 'Her aile tek bir işe odaklanır ve yalnızca açıkça desteklediği Mac tarafıyla eşleşir.',
      'families.assistant': 'Mac’te sohbet, yerel veya kendi anahtarınla modeller, Kod çalışma alanları, uzman botlar ve onaylı otomasyon. Kendi iOS ve tarayıcı uzaktan erişimi dahildir.',
      'families.assistantCta': 'Assistant ailesini aç →',
      'families.stream': "Mac uygulamalarını iPhone veya iPad’de aç. Uygulama pencerelerini aktarmak için Vamp Sync ile eşleştir veya Vamp Assistant üzerinden bağlan.",
      'families.streamCta': 'Stream ailesini aç →',
      'families.control': "Vamp Control’u Vamp Sync’e bağlayarak bir Mac uygulama penceresi seç, aktar ve kontrol et. Mac, iPhone ve iPad için.",

      'families.controlMacCta': 'macOS için Control ↓', 'families.controlIosCta': 'Control iOS IPA ↓',

      'families.syncCta': "Vamp Sync’i al →",

      'footer.familyCopy': 'Özel AI ve odaklı Mac akışı.',

      'assistant.navMac': 'Mac', 'assistant.navRemote': 'iOS + tarayıcı', 'assistant.navFeatures': 'Yetenekler',
      'assistant.get': 'Assistant’ı al', 'assistant.eyebrow': 'Yerel AI yardımcısı · Apple Silicon',
      'assistant.title1': 'Yerelde düşün.', 'assistant.title2': 'Her yerde çalış.',
      'assistant.heroCopy': 'Vamp Assistant özel AI sohbetini, Kod çalışma alanlarını, uzman botları, tarayıcı ve simülatör araçlarını, onaylı Mac işlemlerini kendi iPhone, iPad ve tarayıcı uzaktan erişimiyle birleştirir.',
      'assistant.downloadMac': 'Mac için indir', 'assistant.mobileCta': 'Mobil erişimi gör',
      'assistant.note': 'Apple Silicon · macOS 15+ · yerel MLX/GGUF veya kendi sağlayıcın.',
      'assistant.statModels': 'MLX + GGUF modelleri', 'assistant.statProviders': 'uzak sağlayıcılar',
      'assistant.statBots': 'uzman bot', 'assistant.statRemotes': 'Mac · iOS · tarayıcı',
      'assistant.macKicker': 'Mac uygulaması', 'assistant.macTitle': 'Önce bir yardımcı. Gerektiğinde Kod.',
      'assistant.macLead': 'Sohbetle başla. İş dosya, kabuk komutu, test, tarayıcı durumu veya simülatör istediğinde bir proje aç.',
      'assistant.chatTitle': 'Yerel ve BYOK AI',
      'assistant.chatCopy': 'Apple Silicon’da MLX veya GGUF çalıştır ya da Keychain’de saklanan anahtarlarla OpenAI, Anthropic, Gemini, OpenRouter ve uyumlu sağlayıcıları bağla.',
      'assistant.codeTitle': 'Çalışma alanını bilen kodlama',
      'assistant.codeCopy': 'Açıkça seçilmiş proje içinde bağlam, güvenli dosya ve kabuk araçları, git geri dönüş noktaları, doğrulama, bellek, planlar ve sınırlı alt ajanlar kullan.',
      'assistant.toolsTitle': 'Tarayıcı ve Simülatör',
      'assistant.toolsCopy': 'Yerleşik tarayıcıyı incele ve kullan, iOS Simulator uygulamalarını oluştur ve sür, tanıları gözden geçir; değişiklik yapan her işlem görünür onaya bağlı kalsın.',
      'assistant.remoteKicker': 'Remote Sessions', 'assistant.remoteTitle': 'Masadan uzakta da aynı Assistant.',
      'assistant.remoteLead': 'Yerel iOS eşlikçisini veya güvenilir tarayıcıyı Mac uygulamasıyla eşleştir. Modeller, oturumlar, araçlar, izinler ve dosyalar için Mac yetkilidir.',
      'assistant.iosCopy': 'Sohbet veya Kod oturumlarını gör ve başlat, uzman botları çalıştır, yanıtları izle, soruları cevapla, işlemleri onayla; terminal, paylaşım araçları, tam ekran ve uygulama penceresi kontrolünü aç.',
      'assistant.iosDownload': 'iOS IPA’yı indir ↓', 'assistant.browserTitle': 'Tarayıcı uzaktan erişimi',
      'assistant.browserCopy': 'Oturumlar, canlı sohbet, istemler, onaylar, sorular, pano ve dosya aktarımı için eşlenmiş Remote Sessions sayfasını güvenilir bir tarayıcıda aç.',
      'assistant.galleryKicker': 'Assistant’ın içinde', 'assistant.galleryTitle': 'Yerel araçlar, canlı görünüm.',
      'assistant.galleryLead': 'Güncel koyu mod uygulaması, kendi iOS Simulator ve özel Tarayıcı panelleri açıkken—maket veya ilgisiz ekran yok.',
      'assistant.simTitle': 'iOS uygulamalarını oluştur ve incele', 'assistant.simCopy': 'Assistant’tan ayrılmadan aygıt başlat, derleme yükle, uygulamayı aç, ekran görüntüsü al ve görünen sonucu doğrula.',
      'assistant.browserToolTitle': 'Ajan kontrollü tarayıcı', 'assistant.browserToolCopy': 'Gerçek web sayfalarını aynı Assistant çalışma alanında aç, incele, gezin ve doğrula.',

      'assistant.securityTitle': 'Görünür sınırlarla güçlü.',
      'assistant.securityLead': 'İşlemi Mac yönetir. Uzak istemciler iş isteyebilir; çalışma alanı sınırı, Keychain saklama, onaylar ve iptal yerelde kalır.',
      'assistant.securityEyebrow': 'Sahibi tarafından kontrol edilir', 'assistant.securityCallout': 'Uzak ekran, uzak izin değildir.',
      'assistant.securityCalloutCopy': 'Hassas araçlar, pano, dosyalar, Mac kontrolü ve çalışma alanı değişiklikleri Mac uygulamasının açık politika ve izin denetimlerine bağlıdır.',
      'assistant.guard1Title': 'Özel eşleme', 'assistant.guard1Copy': 'Güvenilir LAN veya Tailscale kullan; kayıtlı cihazları istediğin zaman kaldır.',
      'assistant.guard2Title': 'Keychain sırları', 'assistant.guard2Copy': 'Sağlayıcı anahtarları, şifreleme anahtarları ve uzak token’lar platform deposunda kalır.',
      'assistant.guard3Title': 'Çalışma alanı sınırı', 'assistant.guard3Copy': 'Kod araçları yalnızca seçtiğin proje içinde çalışır.',
      'assistant.guard4Title': 'Onaylı işlemler', 'assistant.guard4Copy': 'Yazma, komut, tarayıcı ve bilgisayar kontrolü çalışmadan önce görünür.',
      'assistant.downloadTitle': 'Assistant iki tarafta.', 'assistant.downloadLead': 'Önce Mac uygulamasını kur, Remote Sessions’ı aç, ardından imzasız iOS eşlikçisini veya tarayıcıyı eşle.',
      'assistant.macCardTitle': 'Yerel Apple Silicon uygulaması.', 'assistant.macCardCopy': 'macOS 15 veya yenisi gerekir. Doğrudan derleme imzalıdır ancak notarize değildir; açmadan önce SHA-256’yı doğrula.',
      'assistant.iosCardTitle': 'Yerel uzak eşlikçi.', 'assistant.iosCardCopy': 'iOS veya iPadOS 18 gerekir. IPA imzasızdır; AltStore, SideStore, Sideloadly veya kendi profilinle yeniden imzalanmalıdır.',
      'assistant.downloadDmg': 'DMG’yi indir ↓', 'assistant.downloadIpa': 'IPA’yı indir ↓',
      'assistant.footer': 'Mac, iPhone, iPad ve tarayıcı için özel AI yardımcısı.',

      'stream.navHosts': 'Uyumlu host’lar', 'stream.navSetup': 'Kurulum', 'stream.navCompatibility': 'Uyumluluk',
      'stream.get': 'Stream’i al', 'stream.eyebrow': 'Odaklı görsel kontrol · iPhone + iPad',
      'stream.title1': 'Mac’in.', 'stream.title2': 'Yalnızca gereken.',
      'stream.heroCopy': "Vamp Stream, Mac’in için odaklı görsel istemcidir. Uygulama pencerelerini Vamp Sync ile aktar veya Vamp Assistant üzerinden tam ekrana eriş. Güvenilir LAN ya da özel Tailscale ağında eşleştir.",
      'stream.downloadIpa': 'Stream IPA’yı indir', 'stream.chooseHost': 'Bir host seç',
      'stream.note': 'İmzasız IPA · aygıtın için yeniden imzala · barındırılan aktarıcı yok.',
      'stream.statHosts': 'uyumlu Mac host’u', 'stream.statVideo': 'donanım videosu', 'stream.statNetwork': 'LAN veya Tailscale', 'stream.statNative': 'iPhone + iPad',
      'stream.hostKicker': 'Mac tarafını seç', 'stream.hostTitle': "Ana host’un Sync. Assistant da yanında.",
      'stream.hostLead': 'Sync, Vamp Stream ve Vamp Control için ana Mac host’udur. Assistant kendi Remote Sessions bağlantısını sunar.',

      'stream.miniHostCopy': "Vamp Control ve Vamp Stream için ana Mac host’u. Bir uygulama penceresi seç, özel ağ üzerinden aktar ve onaylı giriş ile kontrol et.",
      'stream.miniLink': 'Vamp Sync’i keşfet →',
      'stream.assistantHostCopy': 'Tam ekran veya uygulama penceresi H.264 akışı ve kontrol için Assistant’ın kimlik doğrulamalı özel Remote Sessions uç noktasına bağlan.',
      'stream.assistantLink': 'Assistant’ı keşfet →',
      'stream.setupKicker': 'Kurulum', 'stream.setupTitle': 'Yükle. Eşle. İzle.',
      'stream.setupLead': 'İlk bağlantı güven kurar; sonraki bağlantılar sen kaldırana kadar kayıtlı kimliği kullanır.',
      'stream.step1Title': 'İki tarafı da yükle', 'stream.step1Copy': "Vamp Stream’i iPhone veya iPad için yeniden imzala; Mac’ine Vamp Sync’i kur. Assistant da kendi uzaktan erişim bağlantısını sunar.",
      'stream.step2Title': 'Yalnız gereken izinleri ver', 'stream.step2Copy': 'Ekran Kaydı videoyu açar. Erişilebilirlik yalnız klavye veya işaretçi kontrolü için gerekir.',
      'stream.step3Title': 'Eşlemeyi doğrula', 'stream.step3Copy': 'Onaydan önce gösterilen cihaz kimliğini veya eşleme kodunu iki tarafta karşılaştır.',
      'stream.step4Title': 'Bir yüzey seç', 'stream.step4Copy': "Sync ile bir uygulama penceresi seç veya Assistant üzerinden tam ekranı aç.",
      'stream.compatKicker': 'Uyumluluk', 'stream.compatTitle': 'Bağlantı yolunu bil.',
      'stream.compatLead': 'İki yol da kimlik doğrulamalı ve özeldir; ancak ayrı protokoller ve ayrı güven depoları kullanır.',
      'stream.tableHost': 'Mac host’u', 'stream.tableTransport': 'Aktarım', 'stream.tableSurface': 'Görsel yüzey', 'stream.tableTrust': 'Güven',
 'stream.miniTrust': "Doğrulanmış Sync kimliği",
      'stream.assistantSurface': 'Tam ekran veya uygulama penceresi', 'stream.assistantTrust': 'Assistant eşleme + token',
      'stream.securityTitle': 'Ağ ve kimlikle özel.', 'stream.securityLead': 'Her host’u güvenilir LAN veya özel Tailscale ağında tut. Portlarını asla genel internete yönlendirme.',
      'stream.guard1Title': 'Açık onay', 'stream.guard1Copy': 'Bekleyen bağlantı Mac’te doğrulanana kadar güvenilir değildir.',
      'stream.guard2Title': 'Kimlik doğrulamalı video', 'stream.guard2Copy': 'Video ve giriş yalnızca seçilen host protokolü istemciyi doğruladıktan sonra taşınır.',
      'stream.guard3Title': 'İptal edilebilir cihazlar', 'stream.guard3Copy': 'Kaydedilen Stream cihazını onu onaylayan host’tan kaldır.',
      'stream.guard4Title': 'Genel aktarıcı yok', 'stream.guard4Copy': 'Vamp proje tarafından işletilen bir aktarıcı veya genel port yönlendirme gerektirmez.',
      'stream.downloadTitle': 'Stream ve tek bir host ile başla.', 'stream.downloadLead': 'iOS derlemesi AltStore tipi yeniden imzalama için imzasızdır. Yüklemeden önce sağlama toplamlarını doğrula.',
      'stream.streamCardTitle': 'Görsel istemci.', 'stream.streamCardCopy': 'iPhone veya iPad’e yükle, kendi profilinle yeniden imzala ve yalnızca kontrol ettiğin bir Mac ile eşle.',
      'stream.miniCardTitle': "Ana Mac host’un.", 'stream.miniCardCopy': "Vamp Sync hem Control hem Stream ile çalışır. Mac’ine bir kez kur ve her istemciyi ayrı ayrı onayla.",
      'stream.downloadMini': 'Vamp Sync DMG’yi indir', 'stream.footer': 'iPhone ve iPad için odaklı görsel kontrol.',

    }
  };
  Object.assign(translations.tr, {
  "ux.start": "Buradan başla",
  "ux.compare": "İstemcileri karşılaştır",
  "ux.optional": "Assistant",
  "ux.downloads": "İndir",
  "ux.hero": "Bir Mac uygulamasını başka bir Mac, iPhone veya iPad’den kullan. Erişmek istediğin Mac’e Vamp Sync kur, diğer cihazın için bir istemci seç.",
  "ux.setup": "İki uygulama. Tek bağlantı.",
  "ux.setupLead": "Sync erişilecek Mac’te çalışır. Control veya Stream ise ona erişmek için kullandığın cihazda.",
  "ux.step0": "Vamp Sync’i kur",
  "ux.step0Copy": "Erişmek istediğin Mac’e kur. Görüntü için Ekran Kaydı, klavye ve işaretçi kontrolü için Erişilebilirlik izni ver.",
  "ux.step0Cta": "Sync’i indir",
  "ux.step1": "Bir istemci seç",
  "ux.step1Copy": "Mac, iPhone veya iPad’de Control kullan. iPhone veya iPad’de tek uygulamaya odaklanmak için Stream’i seç. Birini kurman yeterli.",
  "ux.step1Cta": "Aşağıda karşılaştır",
  "ux.step2": "Eşleştir ve uygulamayı aç",
  "ux.step2Copy": "Aynı güvenilir yerel ağı veya özel Tailscale ağını kullan. Sync’in QR kodunu tara, cihazın tam parmak izini iki cihazda karşılaştır, Mac’te onayla ve bir uygulama penceresi seç.",
  "ux.step2Cta": "Sync kurulum ayrıntıları",
  "ux.clients": "Cihazına hangi istemci uygun?",
  "ux.clientsLead": "İkisi de Sync’e bağlanır. İstemcini seç, ardından kullanacağın cihaz için indir.",
  "ux.downloadAction": "İndir ↓",
  "ux.unsignedIPA": "İmzasız IPA · yüklemek için yeniden imzala",
  "ux.installNotes": "Kurulum yardımı",
  "ux.control": "Başka bir Mac’ten bağlanırken veya iPhone ve iPad’de Control arayüzünü tercih ediyorsan Control’ü seç.",
  "ux.controlFit": "Mac’ten Mac’e + mobil",
  "ux.controlGet": "Control’ü indir →",
  "ux.stream": "iPhone veya iPad’de tek bir Mac uygulamasına odaklanmak, dokunmatik ve klavye kontrolünü kullanmak için Stream’i seç.",
  "ux.streamFit": "Odaklı mobil deneyim",
  "ux.streamGet": "Stream’i indir →",
  "ux.streamPreview": "Stream’i incele",
  "ux.downloadTitle": "Doğru cihaza kur.",
  "ux.downloadTitleLead": "Önce Sync’i, sonra seçtiğin istemciyi indir. Her uygulama ve platform için yayımlanmış en güncel derlemeler aşağıda.",
  "ux.mini-host-dmgDesc": "Erişmek istediğin Mac’e kur. macOS 13 veya üzeri.",
  "ux.mini-host-dmgButton": "Mac için Sync ↓",
  "ux.control-macosDesc": "Diğer Mac’e kur. macOS 13 veya üzeri.",
  "ux.control-macosButton": "Mac için Control ↓",
  "ux.control-iosDesc": "Telefon veya tabletin için Control istemcisi. İmzasız IPA; yüklemeden önce yeniden imzala.",
  "ux.control-iosButton": "Control iOS IPA ↓",
  "ux.stream-iosDesc": "Odaklı mobil istemci. İmzasız IPA; yüklemeden önce yeniden imzala.",
  "ux.stream-iosButton": "Stream iOS IPA ↓",
  "ux.install": "Mac indirmeleri doğrudan dağıtılan derlemelerdir; ilk açılışta Sistem Ayarları’ndan “Yine de Aç” gerekebilir. iOS indirmeleri kendi Apple kimliğinle AltStore tipi yeniden imzalama gerektirir.",
  "ux.installGuide": "Mac kurulum rehberi ↗",
  "ux.iosGuide": "iOS kurulum rehberi ↗",
  "ux.ai": "Özel AI mı arıyorsun?",
  "ux.aiLead": "Assistant, AI çalışmaları için ayrı bir uygulamadır. Sync + Control veya Stream kurulumun zaten tamam.",
  "ux.separate": "İsteğe bağlı · bağımsız uygulama",
  "ux.assistant": "Mac’inde yerel modellerle veya kendi AI sağlayıcınla sohbet et, kod üzerinde çalış ve uzman araçları kullan. Kendi iOS ve tarayıcı istemcileriyle bu oturumlara uzaktan devam et. Assistant için Sync gerekmez.",
  "ux.assistantMore": "Assistant’ı keşfet →",
  "ux.syncNote": "Intel + Apple Silicon · macOS 13+ · menü çubuğunda çalışır.",
  "ux.streamHero": "Bir Mac uygulamasını iPhone veya iPad’inde kullan. Mac’e Vamp Sync kur, Stream’i eşleştir ve kullanmak istediğin uygulamayı seç.",
  "ux.alreadyAssistant": "Zaten Vamp Assistant mı kullanıyorsun?",
  "ux.assistantCompat": "Stream, uygulama penceresi veya tam ekran için Assistant’ın Remote Sessions özelliğiyle doğrudan eşleşebilir. Assistant’ta Remote Sessions’ı etkinleştir ve onun QR koduyla eşleştir. Bu isteğe bağlıdır; uygulama penceresi paylaşmak için Sync yeterli.",
  "ux.streamInstall": "iPhone veya iPad için Vamp Stream’i yeniden imzala, ardından Mac’ine Vamp Sync kur.",
  "ux.streamDownloads": "Stream ve Sync’i indir.",
  "ux.assistantStandalone": "Assistant bağımsız çalışır. Sync gerekmez.",
  "ux.assistantDownloads": "Mac’te başla."
});
  Object.assign(translations.tr, {"ux.connectionDetails": "Bağlantı ve gizlilik ayrıntıları", "ux.streamVerify": "Sync’te onaylamadan önce cihazın tam parmak izini iki cihazda karşılaştır.", "ux.streamSelect": "Kullanmak istediğin Mac uygulama penceresini seç."});
  Object.assign(translations.tr, {
  "ai.hero": "Tek bir yerel AI çalışma alanında yaz, araştır, yazılım geliştir ve Mac’inle çalış. Yerel model çalıştır veya kendi sağlayıcını kullan. Uzman botlara görev ver, çalışmalarını incele ve iPhone veya iPad’inden devam et.",
  "ai.explore": "Özellikleri keşfet",
  "ai.navFeatures": "Özellikler",
  "ai.navBots": "Uzman botlar",
  "ai.navMobile": "Mobil erişim",
  "ai.navDownloads": "İndir",
  "ai.write": "Düşünmek ve yazmak için",
  "ai.writeCopy": "Proje açmadan sohbet başlat. Bir metin yaz, bir fikri açıklığa kavuştur veya notlarını taslağa dönüştür. Oluşturulan metni yerel Kaydet penceresinden dışarı al.",
  "ai.research": "Kaynaklarla araştır",
  "ai.researchCopy": "İsteğe bağlı TinyFish anahtarınla güncel bilgileri ara, kaynak sayfalarını oku ve yerleşik tarayıcıda incele. Görsel destekleyen bir sağlayıcıyla resim veya ekran görüntüsü hakkında soru sor.",
  "ai.history": "Geçmişini yanında getir",
  "ai.historyCopy": "Claude, Codex ve Cursor sohbet geçmişini içe aktar. Roller, araç çağrıları ve zaman damgaları korunur. Sohbetlerini tek kitaplıkta ara, sabitle, yeniden adlandır ve dışarı aktar. Parola korumalı görev paketleriyle çalışmalarını çalışma alanları arasında aktar.",
  "ai.everyday": "Bir sorudan işe yarar sonuçlara.",
  "ai.everydayLead": "Başlangıç noktası bir sohbet. Görev gerektirdikçe web araştırması, tarayıcı işlemleri veya bir proje ekle.",
  "ai.local": "Mac’ine uygun modeli seç",
  "ai.localCopy": "Model Yöneticisi, Apple Silicon çipine ve belleğine göre model önerir. MLX modellerini indir veya içe aktar, yarım kalan indirmelere devam et ve çıkarımı Mac’inde çalıştır. GGUF modelleri kurulu bir llama.cpp çalışma ortamıyla desteklenir.",
  "ai.providers": "Tercih ettiğin sağlayıcıyı kullan",
  "ai.providersCopy": "Kendi anahtarlarınla OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek ve diğer sağlayıcılara bağlan. Özel uyumlu uç noktalar Ollama ve LM Studio gibi araçları destekler. Modelleri yazma alanından değiştir; kaydedilen anahtarlar Keychain’de tutulur.",
  "ai.modelBoundary": "Yerel çıkarım Mac’inde çalışır. Uzak sağlayıcı, web araması veya bağlı bir hizmet seçildiğinde ilgili istekler o hizmete gönderilir; kullanılabilirlik ve ücretler sağlayıcına bağlıdır.",
  "ai.context": "Proje bağlamıyla kod yaz",
  "ai.contextCopy": "Dosya aramak, kod düzenlemek, komut çalıştırmak ve tanıları incelemek için çalışma alanı aç. Proje dizini ve sembol özetleri ilgili kodu bulmaya yardımcı olur; isteğe bağlı bellek yararlı bilgileri ve oturum özetlerini sonraki çalışmalara taşır.",
  "ai.verify": "Planla, incele ve doğrula",
  "ai.verifyCopy": "İş başlamadan planı incele. Önerilen değişiklik ve komutları onay kartlarında gör, Git kontrol noktalarını sakla ve proje kontrollerini çalıştır. Doğrulama açıkken başarısız kontroller yeniden ele alınmak üzere ajana döner.",
  "ai.extensions": "Becerilerini ve araçlarını kullan",
  "ai.extensionsCopy": "MCP sunucularını bağla ve mevcut kodlama araçlarındaki bildirimsel becerileri keşfet. OpenCode sağlayıcılarını, ajanlarını, komutlarını ve izin kurallarını yerel çalışma alanına aktar. Yalnızca JavaScript ile çalışan sağlayıcı eklentileri uyumlu bir ağ geçidi gerektirebilir.",
  "ai.researcher": "Researcher",
  "ai.researcherCopy": "Kaynakları topla, seçenekleri karşılaştır ve bulguları bir uygulama özetine dönüştür.",
  "ai.builder": "Builder",
  "ai.builderCopy": "Bir değişikliği uygula; değişen dosyaları, çalıştırma sonuçlarını ve doğrulama kanıtlarını raporla.",
  "ai.reviewer": "Reviewer",
  "ai.reviewerCopy": "Tamamlanan işi doğruluk, gerilemeler ve eksik testler açısından incele; bulguları önceliklendir.",
  "ai.navigator": "Navigator",
  "ai.navigatorCopy": "Bir tarayıcı akışını incele, sayfalarda gezin ve görev için görünen davranışı kaydet.",
  "ai.botDetail": "Botların kendi özel tarayıcı profilleri vardır. Çalışmayı Bot Konsolu’ndan izle, devam mesajını sıraya ekle veya sürmekte olan işi yönlendir. İsteğe bağlı bot bilgisayarları ayrı çalışma alanları sunar; Linux mikro VM desteği için container çalışma ortamı gerekir.",
  "ai.models": "Senin modelin. Senin seçimin.",
  "ai.modelsLead": "Yerel modeller ve uzak sağlayıcılar aynı çalışma alanını paylaşır; her göreve uygun olanı seçebilirsin.",
  "ai.code": "Yazılım geliştirmek için bir çalışma alanı.",
  "ai.codeLead": "Code modu, sohbetten fazlasına ihtiyaç duyduğunda proje dosyalarını, komutları, bağlamı ve doğrulamayı ekler.",
  "ai.bots": "Dört uzman, farklı görevler.",
  "ai.botsLead": "İşi Researcher, Builder, Reviewer veya Navigator’a ver. İş akışı araştırmayı uygulamaya taşıyabilir ve tamamlanan kodu bağımsız incelemeye gönderebilir.",
  "ai.ship": "Derlemeden cihaza",
  "ai.shipCopy": "Ship Center, Apple projelerini doğrulayabilir ve arşivleyebilir; IPA dışarı aktarabilir, bağlı iPhone veya iPad’e kurabilir ya da Xcode üzerinden arşiv yükleyebilir. İmzalama ve dağıtım, Mac’inde yapılandırdığın geçerli kimlik bilgilerini ve araçları kullanır.",
  "ai.localApi": "Yerel modelini diğer araçlarla kullan",
  "ai.localApiCopy": "Aynı Mac’te OpenAI uyumlu bir istemciden yüklü modeli kullanmak için yerel API sunucusunu etkinleştir. Arayüzsüz üretim ve sunum için CLI da bulunur; sunucu yalnızca loopback üzerinde dinler.",
  "ai.mobileWork": "İşi telefonundan sürdür",
  "ai.mobileWorkCopy": "Chat veya Code oturumu başlat, model seç, son çalışma alanlarından birini aç veya Mac’te klasör oluştur. Canlı yanıtları ve bot çalışmalarını izle, soruları yanıtla, istekleri onayla, devam mesajlarını sıraya ekle veya işi yönlendir.",
  "ai.mobileControl": "Mac’in kendisine eriş",
  "ai.mobileControlCopy": "Tam ekranı veya tek bir uygulama penceresini kontrol et; izin verildiğinde terminal araçlarını kullan, dosya ve pano içeriği aktar. İsteğe bağlı uzaktan kilit açma yalnızca host üzerinde etkinleştirildiğinde ve kimliği doğrulanmış Tailscale bağlantısında kullanılabilir.",
  "ai.approvals": "Yazma işlemleri ve komutlar varsayılan olarak onay ister. Onay kartları işlemi gösterir; otomatik çalışabilecekleri yapılandırılan izin kuralları belirler.",
  "ai.toolsLead": "Assistant içinde gezin, incele, derle ve sonucu kontrol et. Bunlar uygulamanın Browser ve Simulator panellerinin gerçek görüntüleridir.",
  "ai.indexmac": "Günlük AI",
  "ai.indexmodels": "Modeller",
  "ai.indexcode": "Kod",
  "ai.indexbots": "Botlar",
  "ai.indexfeatures": "Araçlar ve dağıtım",
  "ai.indexremote": "Mobil",
  "ai.homeNav": "AI Assistant",
  "ai.homeTitle": "Sana ait bir AI çalışma alanı.",
  "ai.homeLead": "Vamp Assistant ile tanış: yerel AI, kodlama ajanları, uzman botlar ve mobilde de ulaşabileceğin çalışmaların.",
  "ai.independent": "Mac uygulaması · Sync’ten bağımsız",
  "ai.homeCopy": "Yaz ve araştır, kod geliştir ve incele ya da işi dört uzman bota ver. Kendi modellerini, sağlayıcılarını, becerilerini ve sohbet geçmişini kullan. Yerleşik tarayıcı ve iOS Simulator ile çalış; ardından oturumlarını telefonundan takip et ve işleri onayla. Sync gerekmez.",
  "ai.heroAI": "AI mı arıyorsun? Vamp Assistant ile tanış →"
});
  Object.assign(translations.tr, {"ai.account": "ChatGPT’yi bağla", "ai.accountCopy": "Assistant, yerel Codex app-server üzerinden hesapla oturum açmayı destekler. Kullanılabilir hesap modelleri, sohbet sürekliliği ve durdurma kontrolleriyle yerel ve API modellerinin yanında görünür. Çalışan bir yerel Codex kurulumu ve uygun hesap erişimi gerekir."});
  Object.assign(translations.tr, {
    "ai.hero": "Mac’inde yaz, araştır ve yazılım geliştir. Yerel model veya kendi sağlayıcınla çalış; iPhone veya iPad’den devam et.",
    "assistant.iosCompanion": "iOS eşlikçisini al",
    "assistant.statLocalLabel": "Yerel",
    "assistant.statModels": "Bu Mac’te",
    "assistant.statKeysLabel": "Senin anahtarların",
    "assistant.statProviders": "Keychain’de kalır",
    "assistant.statBots": "uzman bot",
    "assistant.statAwayLabel": "Uzakta",
    "assistant.statRemotes": "iPhone · iPad · tarayıcı",
    "assistant.bentoTitle": "Tek uygulama, her türlü iş.",
    "assistant.bentoLead": "Sohbet et, gezin, çalışan bir derlemeyi kontrol et ve aynı işe iPhone veya iPad’den devam et.",
    "assistant.bentoChatLab": "Sohbet",
    "assistant.bentoChatTitle": "Bir soruyla başla.",
    "assistant.bentoChatCopy": "Proje açmadan yaz, araştır ve kaydet.",
    "assistant.bentoBrowserLab": "Tarayıcı",
    "assistant.browserToolTitle": "Canlı sayfayı incele.",
    "assistant.browserToolCopy": "Gerçek siteleri aynı çalışma alanında aç, gezin ve doğrula.",
    "assistant.bentoSimLab": "Simülatör",
    "assistant.simTitle": "Derlemeyi çalışırken gör.",
    "assistant.simCopy": "Aygıt başlat, uygulama yükle ve görünen sonucu kontrol et.",
    "assistant.bentoIosLab": "iPhone · iPad",
    "assistant.bentoIosTitle": "Mac’ini yanına al.",
    "assistant.bentoIosCopy": "Yerel eşlikçiyi eşle. Kontrol Mac’te kalır.",
    "ai.jobsTitle": "Her görev. Tek çalışma alanı.",
    "ai.jobsLead": "Sohbetle başla, model seç, proje aç, işi bir bota ver veya telefonundan devam et.",
    "ai.jobChat": "Düşünmeyi bitir.",
    "ai.jobChatCopy": "Yaz, kaynaklarla araştır ve içe aktarılan sohbet geçmişini tek kitaplıkta tut.",
    "ai.jobModels": "Senin modelin. Senin seçimin.",
    "ai.jobModelsCopy": "MLX veya GGUF’u yerelde çalıştır, kendi anahtarını getir veya Codex üzerinden oturum aç.",
    "ai.jobCode": "Gerçek yazılım geliştir.",
    "ai.jobCodeCopy": "Çalışma alanı aç, planları incele, değişiklikleri doğrula, MCP veya OpenCode becerilerini bağla.",
    "ai.jobBots": "Dört uzman.",
    "ai.jobBotsCopy": "Researcher, Builder, Reviewer ve Navigator; her birinin özel tarayıcı profili vardır.",
    "ai.jobMobile": "Masadan uzakta çalış.",
    "ai.jobMobileCopy": "iPhone, iPad veya güvenilir bir tarayıcıyı eşle. Yetki Mac’te kalır.",
    "ai.history": "Geçmişini getir.",
    "ai.historyShort": "Claude, Codex ve Cursor sohbetlerini içe aktar. Tek kitaplıkta ara, sabitle ve dışarı aktar.",
    "ai.accountShort": "Yerel Codex kurulumu varsa hesap modelleri yerel ve API modellerinin yanında görünür.",
    "ai.ship": "Derlemeden cihaza.",
    "ai.shipShort": "Arşivle, IPA dışarı aktar veya yapılandırdığın imzalama araçlarıyla bağlı cihaza kur.",
    "ai.localApi": "Yerel modeli paylaş.",
    "ai.localApiShort": "Yüklü modeli loopback üzerinde OpenAI uyumlu istemcilere sun.",
    "ai.botDetail": "Botlar özel tarayıcı profilleri tutar. Bot Konsolu’ndan izle, sıraya al veya yönlendir."
  });
  Object.assign(translations.tr, {"previews.modelsLabel": "Modeller", "previews.modelsTitle": "Mac’ine uygun modeli bul.", "previews.modelsCopy": "Bellek tahminleri ve önerilerle yerel modellere göz at.", "previews.agentLabel": "Ajan", "previews.agentTitle": "Ajanının sınırlarını belirle.", "previews.agentCopy": "Özerklik, üretim ayarları ve yerel çıkarım seçeneklerini belirle.", "previews.generalLabel": "Genel", "previews.generalTitle": "Kendine göre ayarla.", "previews.generalCopy": "Görünümü, yazı tipini, yazma alanını ve klavye kısayollarını ayarla.", "previews.providersLabel": "Sağlayıcılar", "previews.providersTitle": "Kendi bağlantılarını getir.", "previews.providersCopy": "Sağlayıcı hesaplarını, API anahtarlarını ve uyumlu ağ geçitlerini yönet.", "previews.botsLabel": "Botlar", "previews.botsTitle": "Uzmanlara kendi alanlarını ver.", "previews.botsCopy": "Odaklı işler için özel bot bilgisayarları ve tarayıcı profilleri hazırla.", "previews.networkLabel": "Ağ", "previews.networkTitle": "Erişim senin kontrolünde.", "previews.networkCopy": "Yerel API sunucusunu ve eşleştirilmiş uzak oturumları yapılandır.", "previews.pluginsLabel": "Eklentiler", "previews.pluginsTitle": "Araçlarını yanında getir.", "previews.pluginsCopy": "Kodlama ortamındaki becerileri, komutları ve iş akışlarını keşfet."});
  Object.assign(translations.tr, {
    'arcade.tagline': 'Mac’in. Ekranın ötesinde.',
    'arcade.description': 'Mac’ini yayınla, özel ağındaki cihazlardan kontrol et veya kendi AI’ınla üret. Nasıl bağlanacağını sen seç.',
    'arcade.routing': 'Tek host.<br>Kontrolü sen seç.'
  });
  let currentLanguage = localStorage.getItem('vamp-lang') === 'tr' ? 'tr' : 'en';
  const originalText = new Map();
  document.querySelectorAll('[data-i18n]').forEach((element) => originalText.set(element, element.innerHTML));
  const renderLanguage = (language) => {
    currentLanguage = language;
    document.documentElement.lang = language;
    document.querySelectorAll('[data-i18n]').forEach((element) => {
      const key = element.dataset.i18n;
      if (language === 'tr' && translations.tr[key]) element.innerHTML = translations.tr[key];
      else element.innerHTML = originalText.get(element);
    });
    if (languageCode) languageCode.textContent = language === 'tr' ? 'EN' : 'TR';
    if (languageButton) languageButton.setAttribute('aria-label', language === 'tr' ? 'Switch to English' : "Türkçe'ye geç");
    localStorage.setItem('vamp-lang', language);
  };
  renderLanguage(currentLanguage);
  languageButton?.addEventListener('click', () => renderLanguage(currentLanguage === 'tr' ? 'en' : 'tr'));

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  document.querySelectorAll('video[data-autoplay]').forEach((video) => {
    if (reducedMotion.matches) {
      video.removeAttribute('autoplay');
      video.pause();
    } else {
      video.play().catch(() => {});
    }
  });

  const applyRelease = (release) => {
    if (!release || !release.assets) return;
    document.querySelectorAll('[data-release-link], [data-release-asset]').forEach((link) => {
      const asset = release.assets[link.dataset.releaseLink || link.dataset.releaseAsset];
      if (!asset) return;
      link.href = asset.url;
      link.removeAttribute('aria-disabled');
    });
    document.querySelectorAll('[data-release-sha256]').forEach((link) => {
      const asset = release.assets[link.dataset.releaseSha256];
      link.hidden = !asset?.sha256Url;
      if (asset?.sha256Url) link.href = asset.sha256Url;
      else link.removeAttribute('href');
    });
    document.querySelectorAll('[data-release-version]').forEach((element) => {
      const asset = release.assets[element.dataset.releaseVersion];
      if (asset?.label) element.textContent = asset.label;
    });
    const footerRelease = document.querySelector('[data-release-footer]');
    if (footerRelease && release.tag) footerRelease.textContent = release.tag.replace(/^vamp-terminal-/, '');
  };

  const marquee = document.querySelector('.arcade-marquee');
  const motionToggle = document.querySelector('.hero-motion-toggle');
  if (marquee && motionToggle) {
    let userPaused = false;
    let inView = true;
    const updateMotion = () => { marquee.dataset.motionPaused = String(userPaused || !inView || document.hidden); };
    motionToggle.addEventListener('click', () => {
      userPaused = !userPaused;
      motionToggle.setAttribute('aria-pressed', String(userPaused));
      motionToggle.setAttribute('aria-label', userPaused ? 'Resume hero animation' : 'Pause hero animation');
      motionToggle.textContent = userPaused ? 'Resume motion' : 'Pause motion';
      updateMotion();
    });
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; updateMotion(); }).observe(marquee);
    document.addEventListener('visibilitychange', updateMotion);
    updateMotion();
  }

  const previewImages = document.querySelectorAll('.assistant-page .visual-shot, .assistant-page .gallery-card img, .assistant-desktop-preview img');
  if (previewImages.length) {
    const dialog = document.createElement('dialog');
    dialog.className = 'preview-lightbox';
    dialog.setAttribute('aria-label', 'App preview');
    const close = document.createElement('button');
    close.className = 'preview-lightbox-close';
    close.type = 'button';
    close.textContent = '×';
    close.setAttribute('aria-label', 'Close preview');
    const large = document.createElement('img');
    dialog.append(close, large);
    document.body.append(dialog);
    let previousOverflow = '';
    let opener;
    previewImages.forEach((img) => {
      let trigger = img.closest('a');
      if (!trigger) {
        trigger = document.createElement('button');
        trigger.type = 'button';
        trigger.className = 'preview-enlarge';
        img.before(trigger);
        trigger.append(img);
      }
      trigger.setAttribute('aria-haspopup', 'dialog');
      trigger.setAttribute('aria-label', 'Enlarge: ' + img.alt);
      trigger.addEventListener('click', (event) => {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        event.preventDefault();
        opener = trigger;
        large.src = img.currentSrc || img.src;
        large.alt = img.alt;
        previousOverflow = document.body.style.overflow;
        document.body.style.overflow = 'hidden';
        dialog.showModal();
      });
    });
    close.addEventListener('click', () => dialog.close());
    dialog.addEventListener('click', (event) => {
      if (event.target === dialog) dialog.close();
    });
    dialog.addEventListener('close', () => {
      document.body.style.overflow = previousOverflow;
      opener?.focus({preventScroll: true});
    });
  }

  fetch('/release.json', {cache:'no-store'}).then((response) => response.ok ? response.json() : null).then(applyRelease).catch(() => {});
})();
