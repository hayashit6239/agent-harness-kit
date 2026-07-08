import { createApp } from 'vue';
// フォントは @fontsource で同梱する (ネットワーク非依存 — issue #9 のローカル道具方針を維持)
import '@fontsource/zen-kaku-gothic-new/400.css';
import '@fontsource/zen-kaku-gothic-new/500.css';
import '@fontsource/zen-kaku-gothic-new/700.css';
import '@fontsource/ibm-plex-mono/400.css';
import '@fontsource/ibm-plex-mono/600.css';
import App from './App.vue';
import './style.css';

createApp(App).mount('#app');
