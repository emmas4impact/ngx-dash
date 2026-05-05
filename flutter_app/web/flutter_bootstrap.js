{{flutter_js}}
{{flutter_build_config}}

(() => {
  finalBuilds:
  for (const build of _flutter.buildConfig?.builds ?? []) {
    if (build == null || typeof build.mainJsPath !== 'string') {
      continue finalBuilds;
    }
    const separator = build.mainJsPath.includes('?') ? '&' : '?';
    build.mainJsPath = `${build.mainJsPath}${separator}v=${Date.now()}`;
  }
})();

_flutter.loader.load({
  serviceWorkerSettings: null,
});
