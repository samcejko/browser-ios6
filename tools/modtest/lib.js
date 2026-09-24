export let count = 0;
export function inc() { count++; }
export default class Greeter { constructor(n) { this.n = n; } hi() { return `hi ${this.n}`; } }
export const PI2 = Math.PI * 2;
export * from './star.js';
export * as starNS from './star.js';
export { helper as renamed } from './utils-local.js';