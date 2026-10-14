/* Only production website visits are measured after a real GA4 ID is configured. */
(() => {
  if (location.hostname !== 'etongle.github.io' || !location.pathname.startsWith('/ModelDock/')) return;
  const source = new URL('analytics-config.json', document.currentScript.src);
  fetch(source, { credentials: 'omit', cache: 'no-cache' }).then(response => {
    if (!response.ok) throw Error('Analytics configuration unavailable');
    return response.json();
  }).then(config => {
    if (!config.enabled || config.provider !== 'ga4' || !/^G-[A-Z0-9]{6,32}$/.test(config.measurementId)
        || config.hostname !== location.hostname || config.pathPrefix !== '/ModelDock/') return;
    // This guard also prevents a second copy of the script from recording another page view.
    if (window.modeldockAnalyticsLoaded) return;
    window.modeldockAnalyticsLoaded = true;
    window.dataLayer = window.dataLayer || [];
    window.gtag = window.gtag || function () { window.dataLayer.push(arguments); };
    let referrer = '';
    try { referrer = document.referrer ? new URL(document.referrer).origin : ''; } catch {}
    window.gtag('js', new Date());
    window.gtag('config', config.measurementId, {
      allow_google_signals: false,
      allow_ad_personalization_signals: false,
      cookie_prefix: 'modeldock',
      cookie_path: '/ModelDock/',
      page_location: location.origin + location.pathname,
      page_referrer: referrer,
      send_page_view: true
    });
    const script = document.createElement('script');
    script.async = true;
    script.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(config.measurementId);
    document.head.appendChild(script);
  }).catch(() => {}); // Analytics configuration/network failures do not affect the website.
})();
