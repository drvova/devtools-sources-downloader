console.log('[DevTools Downloader] devtools.js loaded via webpack bundle');

chrome.devtools.panels.sources.createSidebarPane('Download', function (pane) {
    pane.setPage('../html/page.html');
});
