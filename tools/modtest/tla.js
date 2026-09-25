import { later } from './tla-dep.js';
export const value = await Promise.resolve(later + '!');
let sum = 0;
for await (const x of [Promise.resolve(1), 2]) sum += x;
export { sum };
export default await new Promise(r => setTimeout(() => r('waited'), 10));
export const self = this;
