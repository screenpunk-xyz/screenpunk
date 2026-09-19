const cameras = [
  ["Camera One", "camera.example_one"],
  ["Camera Two", "camera.example_two"],
  ["Camera Three", "camera.example_three"]
];
const mounts = cameras.map(([label, entityId], order) => {
  const feed = document.createElement("div");
  feed.className = "feed";
  document.querySelector("main").append(feed);
  return screenpunk.cameras.mount(feed,
    {kind: "homeAssistant", connection: "home", entityId},
    () => {}, {controls: "gallery", label, order});
});
addEventListener("pagehide", () => mounts.forEach(mount => mount.stop()));
screenpunk.runtime.ready();
