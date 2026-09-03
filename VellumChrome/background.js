const supportedProtocols = new Set(["http:", "https:"]);

chrome.action.onClicked.addListener((tab) => {
  if (typeof tab.id !== "number" || !tab.url) {
    return;
  }

  const webpage = new URL(tab.url);
  if (!supportedProtocols.has(webpage.protocol)) {
    return;
  }

  const route = new URL("vellum://open-url");
  route.searchParams.set("url", webpage.href);
  chrome.tabs.update(tab.id, { url: route.href });
});
