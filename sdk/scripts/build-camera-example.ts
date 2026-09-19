import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { deploymentDigest, sha256Bytes, validateManifest, type DashboardManifest } from "../src/package.ts";
const dir = new URL("../../examples/home-assistant-cameras/", import.meta.url);
copyFileSync(new URL("../dist/screenpunk.js", import.meta.url), new URL("screenpunk.js", dir));
const manifest: DashboardManifest = {
 schemaVersion:1, dashboardId:"77777777-7777-4777-8777-777777777777", revision:"77777777-7777-4777-9777-777777777778",
 name:"Cameras", entrypoint:"index.html", sdkVersion:"1",
 target:{profileId:"camera-tablet",width:1194,height:834,scale:2,orientation:"landscape"},
 connections:[{alias:"home",required:true,operations:[{name:"cameraPresent",kind:"http"},{name:"cameraClose",kind:"http"}],cameraEntities:["camera.example_one","camera.example_two","camera.example_three"]}],
 files:["index.html","styles.css","app.js","screenpunk.js"].map(path=>{const data=readFileSync(new URL(path,dir));return {path,bytes:data.length,sha256:sha256Bytes(data)};})
};
manifest.digest=deploymentDigest(manifest);validateManifest(manifest);
writeFileSync(new URL("manifest.json",dir),JSON.stringify(manifest,null,2)+"\n");
