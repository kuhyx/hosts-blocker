// fb-spa-guard: the browser URL policy (URLBlocklist / WebsiteFilter) only
// sees document loads. facebook.com is a single-page app, so from any page
// the policy lets through (the 2FA step messenger.com sends you to) its
// router can move to /reel/..., /watch, the feed and so on with
// history.pushState, which no policy sees. This worker watches those moves
// and sends the tab back to Messenger.
//
// __ALLOWED_PATHS__ is replaced at build time from URLFILTER_ALLOWED_PATHS in
// lib/hosts_browser_urlfilter.sh, so this list and the policy cannot drift.
const ALLOWED_PATHS = __ALLOWED_PATHS__;
const SHIM_HOSTS = ["l.facebook.com", "lm.facebook.com"];
const HOME = "https://www.facebook.com/messages/";

function isBlocked(rawUrl) {
	let url;
	try {
		url = new URL(rawUrl);
	} catch {
		return false;
	}
	const host = url.hostname;
	if (host !== "facebook.com" && !host.endsWith(".facebook.com")) {
		return false;
	}
	if (SHIM_HOSTS.includes(host)) {
		return false;
	}
	return !ALLOWED_PATHS.some(
		(path) =>
			url.pathname === `/${path}` || url.pathname.startsWith(`/${path}/`),
	);
}

// Facebook may bounce HOME somewhere not allowed; after three redirects in ten
// seconds stop the tab instead of looping.
const recent = new Map();

function guard(details) {
	if (details.frameId !== 0 || !isBlocked(details.url)) {
		return;
	}
	const now = Date.now();
	const hits = (recent.get(details.tabId) ?? []).filter((t) => now - t < 10000);
	hits.push(now);
	recent.set(details.tabId, hits);
	chrome.tabs.update(details.tabId, { url: hits.length > 3 ? "about:blank" : HOME });
}

const filter = { url: [{ hostSuffix: "facebook.com" }] };
chrome.webNavigation.onHistoryStateUpdated.addListener(guard, filter);
chrome.webNavigation.onReferenceFragmentUpdated.addListener(guard, filter);
chrome.webNavigation.onCommitted.addListener(guard, filter);
