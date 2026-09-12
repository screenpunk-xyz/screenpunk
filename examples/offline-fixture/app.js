(function () {
  if (globalThis.screenpunk && typeof globalThis.screenpunk.runtime?.ready === "function") {
    globalThis.screenpunk.runtime.ready();
  }
})();
