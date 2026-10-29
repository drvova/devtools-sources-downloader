// Registers the downloader as a first-class DevTools panel.
//
// The original surface was panels.sources.createSidebarPane, but Chrome
// stopped rendering extension sidebar panes in the Sources panel (the
// creation callback fires, the UI never appears). A main panel is the
// pattern React DevTools uses and renders as a top-level tab.
chrome.devtools.panels.create('Sources Downloader', '../images/icons/48.png', '../html/page.html');
