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
      "arcade.tagline": "Mac’in elinin altında.",
      "footer.familyCopy": "Mac’ine özel ağ üzerinden eriş.",
      "footer.meta": "yerel öncelikli · eş onaylı · barındırılan aktarıcı yok",
      "nav.download": "İndir",
      "sync.accessCopy": "Klavye ve işaretçi kontrolü açık Erişilebilirlik izni gerektirir.",
      "sync.accessTitle": "Kontrol için gerekli.",
      "sync.clientCopy": "Vamp Control’ü diğer Mac’ine, iPhone’una veya iPad’ine yükle.",
      "sync.clientTitle": "Vamp Control ile bağlan.",
      "sync.compareEditions": "Sürümleri karşılaştır",
      "sync.download": "Vamp Sync’i indir",
      "sync.downloadDmg": "DMG’yi indir",
      "sync.downloadLead": "Ulaşmak istediğin Mac’e Vamp Sync’i kur, gerekli izinleri ver ve kimliğini doğruladıktan sonra istemcini onayla.",
      "sync.downloadTitle": "Vamp Sync’i indir.",
      "sync.eyebrow": "Vamp Control için Mac sunucusu",
      "sync.footer": "Vamp Control için Mac sunucusu.",
      "sync.get": "Vamp Sync’i al",
      "sync.getControl": "Vamp Control’u al",
      "sync.heroCopy": "Vamp Sync’i erişmek istediğin Mac’e yükle. Diğer cihazından Vamp Control ile güvenilir bir yerel ağ veya özel Tailscale ağı üzerinden bağlan.",
      "sync.inputCopy": "Klavye ve işaretçi komutlarını yalnız güven ve Erişilebilirlik onayından sonra ilet.",
      "sync.inputTitle": "İzin verildiğinde kontrol et",
      "sync.macCopy": "Kendi paketi, izinleri ve güvenilen cihaz deposu olan bir menü çubuğu uygulaması.",
      "sync.macTitle": "Mac’in bağlanmaya hazır.",
      "sync.navDownload": "İndir",
      "sync.navPermissions": "İzinler",
      "sync.pairCopy": "Sync’te Yerel Wi-Fi veya Tailscale’i seç, o ağın QR kodunu tara ve cihazı onaylamadan önce tam parmak izini karşılaştır. Tailscale özel sayısal adres kullanır; MagicDNS isteğe bağlıdır.",
      "sync.pairTitle": "Her yeni cihazı doğrula",
      "sync.permissionsKicker": "macOS izinleri",
      "sync.permissionsLead": "İzinleri doğrudan Vamp Sync’e ver. Hazır oluşu bildirir; macOS onayını asla atlamaz.",
      "sync.permissionsTitle": "İki izin, iki net iş.",
      "sync.sceneCaption": "Diğer cihazından bağlan.",
      "sync.sceneHeading": "Mac’in, bağlantıda.",
      "sync.sceneHost": "Erişmek istediğin Mac’te",
      "sync.scenePrivate": "Özel",
      "sync.screenCopy": "Ekran Kaydı, Sync’in seçilen uygulama penceresini eşleştirilmiş istemcinle paylaşmasını sağlar.",
      "sync.screenTitle": "Video için gerekli.",
      "sync.statLight": "Hafif",
      "sync.statMenu": "menü çubuğu arayüzü",
      "sync.statPermissions": "macOS izinleri",
      "sync.statTransport": "imzalı aktarım",
      "sync.statTrust": "güven sınırı",
      "sync.surfaceKicker": "Odaklı arayüz",
      "sync.surfaceLead": "Erişilebilirliği, izinleri, eşleme isteklerini, onaylı cihazları ve çalışma kontrollerini tek bir menü çubuğu arayüzünde gör.",
      "sync.surfaceTitle": "Sync menü çubuğunda çalışır.",
      "sync.title1": "Host’u",
      "sync.title2": "senkron tut.",
      "sync.videoCopy": "Vamp Control’de bir uygulama penceresi seç. Sync bu pencereyi Mac’inden paylaşır.",
      "sync.videoTitle": "Bir uygulama penceresi paylaş",
      "ux.control": "Bağlanmak için kullanacağın Mac’e, iPhone’a veya iPad’e yükle.",
      "ux.downloadAction": "İndir ↓",
      "ux.downloads": "İndir",
      "ux.hero": "Vamp Sync’i erişmek istediğin Mac’e yükle. Başka bir Mac, iPhone veya iPad’den Vamp Control ile bağlan.",
      "ux.install": "Doğrudan indirilen Mac uygulamalarını açmak için Sistem Ayarları’nda “Yine de Aç” seçeneği gerekebilir. iPhone ve iPad için Control, yüklemeden önce yeniden imzalanmalıdır.",
      "ux.installGuide": "Mac kurulum rehberi ↗",
      "ux.installNotes": "Kurulum yardımı",
      "ux.iosGuide": "iOS kurulum rehberi ↗",
      "ux.iosUnavailable": "Şu anda indirilemiyor",
      "ux.mini-host-dmgButton": "Mac için indir ↓",
      "ux.setup": "Cihazlarını eşleştir",
      "ux.start": "Buradan başla",
      "ux.step0Copy": "Erişmek istediğin Mac’e yükle. Sync menü çubuğunda çalışır.",
      "ux.step2Copy": "Vamp Sync’te Yerel Wi-Fi veya Tailscale’i seç. Vamp Control’ü aç ve Sync’in QR kodunu veya eşleştirme bağlantısını kullan. Mac’te onaylamadan önce iki cihazda da tam cihaz parmak izini karşılaştır.",
      "ux.step2Cta": "Sync kurulumu ve sürümleri ↗",
      "ux.syncNote": "Intel + Apple Silicon · macOS 13+ · menü çubuğunda çalışır.",
      "ux.unsignedIPA": "İmzasız IPA · yüklemek için yeniden imzala",
    },
  };
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
      link.hidden = false;
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
