export let later = 'early';
later = await new Promise(r => setTimeout(() => r('late'), 20));
