// Installed as scripts/build.mjs in a synthetic copied kit. The release script remains
// scripts/actual-build.mjs so its own kit-relative resolution is unchanged.
import { reportReadClosure } from './read-closure-prelude.mjs';
try {
  const { buildProject } = await import('./actual-build.mjs');
  await buildProject(process.argv[2], process.argv[3]);
  reportReadClosure();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
