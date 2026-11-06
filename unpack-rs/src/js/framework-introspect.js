(function () {
    'use strict';

    // The capture policy is engine-owned (panel/policy.rs) and injected by the
    // panel before this file runs (page.js::injectAndReload). There is no local
    // copy to drift from it, and a missing policy fails closed: every key is
    // redacted and every limit collapses to zero, which is loud rather than
    // silently unredacted.
    var POLICY = window.__CAPTURE_POLICY__ || null;
    function limit(name) {
        return POLICY && POLICY.limits ? POLICY.limits[name] || 0 : 0;
    }
    var REDACT_RE = new RegExp(POLICY ? POLICY.redactKey : '.*', 'i');

    function lower(value) {
        return String(value || '').toLowerCase();
    }

    function shouldRedactKey(key) {
        return REDACT_RE.test(String(key || ''));
    }

    function limitString(value) {
        value = String(value == null ? '' : value);
        return value.length > limit('string') ? value.substring(0, limit('string')) + '…' : value;
    }

    function safeValue(value, depth, seen, keyName) {
        if (shouldRedactKey(keyName)) return '[redacted]';
        if (value == null || typeof value === 'number' || typeof value === 'boolean') return value;
        if (typeof value === 'string') return limitString(value);
        if (typeof value === 'function') return '[function]';
        if (typeof value === 'undefined') return '[undefined]';
        if (typeof Element !== 'undefined' && value instanceof Element) {
            return '<' + lower(value.tagName) + (value.id ? '#' + value.id : '') + '>';
        }
        if (!seen) seen = [];
        if (seen.indexOf(value) >= 0) return '[circular]';
        if (depth <= 0) {
            if (Array.isArray(value)) return '[array:' + value.length + ']';
            return '[object]';
        }
        seen.push(value);
        var out;
        if (Array.isArray(value)) {
            out = [];
            for (var i = 0; i < value.length && i < 8; i++)
                out.push(safeValue(value[i], depth - 1, seen, ''));
            if (value.length > 8) out.push('[+' + (value.length - 8) + ' more]');
            seen.pop();
            return out;
        }
        out = {};
        var keys;
        try {
            keys = Object.keys(value);
        } catch (_) {
            seen.pop();
            return '[uninspectable]';
        }
        for (var j = 0; j < keys.length && j < limit('keys'); j++) {
            var key = keys[j];
            out[key] = safeValue(value[key], depth - 1, seen, key);
        }
        if (keys.length > limit('keys')) out.__truncatedKeys = keys.length - limit('keys');
        seen.pop();
        return out;
    }

    function safeKeys(value) {
        try {
            return Object.keys(value || {}).slice(0, limit('keys'));
        } catch (_) {
            return [];
        }
    }

    function buildRootDescriptor(kind, source, element) {
        if (!element) return null;
        return {
            kind: kind,
            source: source,
            tag: lower(element.tagName || 'div'),
            id: element.id || '',
            classes: element.className
                ? String(element.className)
                      .split(/\s+/)
                      .filter(Boolean)
                      .slice(0, limit('classNames'))
                : [],
            childCount: element.children ? element.children.length : 0,
            textSample: limitString(element.textContent || ''),
        };
    }

    function collectFrameworkRoots() {
        var roots = [];
        var seen = {};
        function push(kind, selector) {
            var el = null;
            try {
                el = document.querySelector(selector);
            } catch (_) {}
            if (!el) return;
            var key = kind + '|' + selector;
            if (seen[key]) return;
            seen[key] = true;
            roots.push(buildRootDescriptor(kind, selector, el));
        }
        push('next', '#__next');
        push('nuxt', '#__nuxt');
        push('react', '[data-reactroot]');
        push('vue', '[data-v-app]');
        push('angular', '[ng-version]');
        push('astro', 'astro-island');
        push('svelte', '[data-sveltekit-preload-data]');
        push('generic', '#root');
        push('generic', '#app');
        return roots.filter(Boolean).slice(0, limit('items'));
    }

    function collectRouterState() {
        var state = {
            framework: 'generic',
            source: 'location',
            pathname: location.pathname || '',
            search: location.search || '',
            hash: location.hash || '',
            url: location.href || '',
            queryKeys: [],
        };
        try {
            state.queryKeys = Array.from(new URLSearchParams(location.search || '').keys()).slice(
                0,
                limit('keys'),
            );
        } catch (_) {}
        if (window.__NEXT_DATA__) {
            state.framework = 'Next.js';
            state.source = 'window.__NEXT_DATA__';
            state.route = window.__NEXT_DATA__.page || '';
            state.buildId = window.__NEXT_DATA__.buildId || '';
            state.propsKeys = safeKeys(window.__NEXT_DATA__.props || {});
            state.query = safeValue(window.__NEXT_DATA__.query || {}, 1, [], 'query');
        } else if (window.__NUXT__) {
            state.framework = 'Nuxt';
            state.source = 'window.__NUXT__';
            state.route = window.__NUXT__.routePath || window.__NUXT__.path || '';
            state.params = safeValue(window.__NUXT__.params || {}, 1, [], 'params');
        } else if (window.__remixContext) {
            state.framework = 'Remix';
            state.source = 'window.__remixContext';
            state.route = location.pathname || '';
            state.routeModules = safeKeys(window.__remixContext.routeModules || {});
        } else if (window.history && window.history.state) {
            state.framework = 'history';
            state.source = 'window.history.state';
            state.historyState = safeValue(window.history.state, 1, [], 'historyState');
        }
        return state;
    }

    function pushStore(target, id, kind, source, stateValue, meta) {
        target.push({
            id: id,
            kind: kind,
            source: source,
            keyCount: safeKeys(stateValue).length,
            keys: safeKeys(stateValue),
            preview: safeValue(stateValue, 2, [], id),
            meta: meta || {},
        });
    }

    function collectStoreSnapshots() {
        var stores = [];
        var seen = {};
        function push(id, kind, source, stateValue, meta) {
            if (!stateValue || seen[source]) return;
            seen[source] = true;
            pushStore(stores, id, kind, source, stateValue, meta);
        }
        var candidates = [
            ['__NEXT_REDUX_WRAPPER_STORE__', 'redux'],
            ['__REDUX_STORE__', 'redux'],
            ['store', 'store'],
            ['__STORE__', 'store'],
            ['zustandStore', 'zustand'],
            ['__ZUSTAND_STORE__', 'zustand'],
            ['queryClientStore', 'store'],
        ];
        for (var i = 0; i < candidates.length; i++) {
            var name = candidates[i][0];
            var value = window[name];
            if (!value) continue;
            if (typeof value.getState === 'function')
                push(name, candidates[i][1], 'window.' + name, value.getState(), {
                    hasDispatch: typeof value.dispatch === 'function',
                });
            else if (typeof value.state === 'object')
                push(name, candidates[i][1], 'window.' + name + '.state', value.state, {});
        }
        if (window.__NUXT__ && window.__NUXT__.state)
            push(
                '__NUXT__.state',
                'nuxt-state',
                'window.__NUXT__.state',
                window.__NUXT__.state,
                {},
            );
        if (window.__INITIAL_STATE__)
            push(
                '__INITIAL_STATE__',
                'initial-state',
                'window.__INITIAL_STATE__',
                window.__INITIAL_STATE__,
                {},
            );
        if (
            window.__NEXT_DATA__ &&
            window.__NEXT_DATA__.props &&
            window.__NEXT_DATA__.props.pageProps
        )
            push(
                '__NEXT_DATA__.props.pageProps',
                'next-page-props',
                'window.__NEXT_DATA__.props.pageProps',
                window.__NEXT_DATA__.props.pageProps,
                {},
            );
        return stores.slice(0, limit('items'));
    }

    function collectQueryCaches() {
        var queries = [];
        if (
            window.__APOLLO_CLIENT__ &&
            window.__APOLLO_CLIENT__.cache &&
            typeof window.__APOLLO_CLIENT__.cache.extract === 'function'
        ) {
            var apolloCache = window.__APOLLO_CLIENT__.cache.extract();
            queries.push({
                kind: 'apollo-cache',
                source: 'window.__APOLLO_CLIENT__.cache.extract()',
                keyCount: safeKeys(apolloCache).length,
                keys: safeKeys(apolloCache),
                preview: safeValue(apolloCache, 2, [], 'apolloCache'),
            });
        }
        if (window.__APOLLO_STATE__) {
            queries.push({
                kind: 'apollo-state',
                source: 'window.__APOLLO_STATE__',
                keyCount: safeKeys(window.__APOLLO_STATE__).length,
                keys: safeKeys(window.__APOLLO_STATE__),
                preview: safeValue(window.__APOLLO_STATE__, 2, [], 'apolloState'),
            });
        }
        var queryClient =
            window.__REACT_QUERY_CLIENT__ || window.queryClient || window.__QUERY_CLIENT__ || null;
        if (queryClient && typeof queryClient.getQueryCache === 'function') {
            var queryItems = [];
            try {
                queryItems = queryClient.getQueryCache().getAll() || [];
            } catch (_) {}
            queries.push({
                kind: 'tanstack-query',
                source:
                    queryClient === window.queryClient
                        ? 'window.queryClient'
                        : queryClient === window.__QUERY_CLIENT__
                          ? 'window.__QUERY_CLIENT__'
                          : 'window.__REACT_QUERY_CLIENT__',
                queryCount: queryItems.length,
                keys: queryItems.slice(0, limit('items')).map(function (item) {
                    return safeValue(
                        item && item.queryKey
                            ? item.queryKey
                            : item && item.queryHash
                              ? item.queryHash
                              : '',
                        1,
                        [],
                        'queryKey',
                    );
                }),
                preview: safeValue(
                    queryItems.slice(0, limit('queryItems')).map(function (item) {
                        return {
                            hash: item && item.queryHash ? item.queryHash : '',
                            key: item && item.queryKey ? item.queryKey : '',
                            status: item && item.state ? item.state.status : '',
                        };
                    }),
                    2,
                    [],
                    'queries',
                ),
            });
        }
        if (window.__SWR_DATA__) {
            queries.push({
                kind: 'swr-cache',
                source: 'window.__SWR_DATA__',
                keyCount: safeKeys(window.__SWR_DATA__).length,
                keys: safeKeys(window.__SWR_DATA__),
                preview: safeValue(window.__SWR_DATA__, 2, [], 'swr'),
            });
        }
        return queries.slice(0, limit('items'));
    }

    function collectHydrationPayloads() {
        var hydration = [];
        if (window.__NEXT_DATA__) {
            hydration.push({
                kind: 'next-data',
                source: 'window.__NEXT_DATA__',
                keys: safeKeys(window.__NEXT_DATA__),
                route: window.__NEXT_DATA__.page || '',
                preview: safeValue(
                    {
                        page: window.__NEXT_DATA__.page,
                        query: window.__NEXT_DATA__.query,
                        props: window.__NEXT_DATA__.props,
                    },
                    2,
                    [],
                    'nextData',
                ),
            });
        }
        if (window.__NUXT__) {
            hydration.push({
                kind: 'nuxt-payload',
                source: 'window.__NUXT__',
                keys: safeKeys(window.__NUXT__),
                route: window.__NUXT__.routePath || window.__NUXT__.path || '',
                preview: safeValue(window.__NUXT__, 2, [], 'nuxt'),
            });
        }
        if (window.__remixContext) {
            hydration.push({
                kind: 'remix-context',
                source: 'window.__remixContext',
                keys: safeKeys(window.__remixContext),
                route: location.pathname || '',
                preview: safeValue(window.__remixContext, 2, [], 'remix'),
            });
        }
        if (window.__INITIAL_STATE__) {
            hydration.push({
                kind: 'initial-state',
                source: 'window.__INITIAL_STATE__',
                keys: safeKeys(window.__INITIAL_STATE__),
                preview: safeValue(window.__INITIAL_STATE__, 2, [], 'initialState'),
            });
        }
        return hydration.slice(0, limit('items'));
    }

    function collectAuthState() {
        var auth = [];
        if (window.__NEXTAUTH) {
            auth.push({
                kind: 'nextauth',
                source: 'window.__NEXTAUTH',
                status: window.__NEXTAUTH.status || '',
                keys: safeKeys(window.__NEXTAUTH),
                preview: safeValue(window.__NEXTAUTH, 2, [], 'nextauth'),
            });
        }
        if (window.__clerk || window.Clerk) {
            var clerk = window.__clerk || window.Clerk;
            auth.push({
                kind: 'clerk',
                source: window.__clerk ? 'window.__clerk' : 'window.Clerk',
                status: clerk && clerk.status ? clerk.status : '',
                keys: safeKeys(clerk),
                preview: safeValue(clerk, 1, [], 'clerk'),
            });
        }
        if (
            window.__NEXT_DATA__ &&
            window.__NEXT_DATA__.props &&
            window.__NEXT_DATA__.props.pageProps &&
            window.__NEXT_DATA__.props.pageProps.session
        ) {
            auth.push({
                kind: 'session-payload',
                source: 'window.__NEXT_DATA__.props.pageProps.session',
                status: 'present',
                keys: safeKeys(window.__NEXT_DATA__.props.pageProps.session),
                preview: safeValue(window.__NEXT_DATA__.props.pageProps.session, 2, [], 'session'),
            });
        }
        return auth.slice(0, limit('items'));
    }

    function collectFrameworkState(options) {
        options = options || {};
        var stackProfile = options.stackProfile || window.__STACK_PROFILE__ || {};
        var captureStatus = options.captureStatus || window.__CAPTURE_STATUS__ || {};
        var state = {
            generatedAt: new Date().toISOString(),
            reason: options.reason || '',
            page: {
                title: document.title || '',
                url: location.href || '',
                origin: location.origin || '',
            },
            profile:
                captureStatus.profile ||
                (stackProfile.strategy && stackProfile.strategy.profile) ||
                'generic-app',
            strategy: captureStatus.strategy || stackProfile.strategy || null,
            technologies: Array.isArray(stackProfile.technologies)
                ? stackProfile.technologies.slice(0, limit('technologies'))
                : [],
            roots: collectFrameworkRoots(),
            router: collectRouterState(),
            stores: collectStoreSnapshots(),
            queries: collectQueryCaches(),
            hydration: collectHydrationPayloads(),
            auth: collectAuthState(),
        };
        state.summary = {
            rootCount: state.roots.length,
            storeCount: state.stores.length,
            queryCount: state.queries.length,
            hydrationCount: state.hydration.length,
            authCount: state.auth.length,
            routerFramework:
                state.router && state.router.framework ? state.router.framework : 'generic',
            detectedTechnologies: state.technologies
                .map(function (item) {
                    return item && item.name ? item.name : '';
                })
                .filter(Boolean),
        };
        return state;
    }

    function refreshFrameworkState(options) {
        window.__FRAMEWORK_STATE__ = collectFrameworkState(options || {});
        return window.__FRAMEWORK_STATE__;
    }

    window.__FRAMEWORK_INTROSPECTOR__ = {
        version: '1.0.0',
        collect: collectFrameworkState,
        refresh: refreshFrameworkState,
    };

    refreshFrameworkState({ reason: 'boot' });
    document.addEventListener('DOMContentLoaded', function () {
        refreshFrameworkState({ reason: 'domcontentloaded' });
    });
    window.addEventListener('load', function () {
        refreshFrameworkState({ reason: 'load' });
        setTimeout(function () {
            refreshFrameworkState({ reason: 'settled' });
        }, 1200);
    });
})();
