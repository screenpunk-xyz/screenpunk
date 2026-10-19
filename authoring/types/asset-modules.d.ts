// Fixed V1 compiler declarations for assets handled by the closed esbuild resolver.
declare module '*.css';
declare module '*.svg' {
  const url: string;
  export default url;
}
declare module '*.png' {
  const url: string;
  export default url;
}
declare module '*.jpg' {
  const url: string;
  export default url;
}
declare module '*.jpeg' {
  const url: string;
  export default url;
}
declare module '*.webp' {
  const url: string;
  export default url;
}
declare module '*.woff' {
  const url: string;
  export default url;
}
declare module '*.woff2' {
  const url: string;
  export default url;
}
