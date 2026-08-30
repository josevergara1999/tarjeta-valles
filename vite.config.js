import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: 'autoUpdate',
      manifest: {
        name: 'Tarjeta Valles',
        short_name: 'Tarjeta',
        description: 'Beneficios de la red de comercios del valle',
        lang: 'es-CL',
        start_url: '/',
        display: 'standalone',
        background_color: '#0b0b0b',
        theme_color: '#0b0b0b',
        // Los genera `npm run iconos` a partir de public/favicon.svg. Ver pwa-assets.config.js.
        // Sin las entradas de 192 y 512 Android no ofrece instalar la app, y la de `maskable` es la
        // que evita que el lanzador recorte el icono a lo bruto.
        icons: [
          { src: 'pwa-64x64.png', sizes: '64x64', type: 'image/png' },
          { src: 'pwa-192x192.png', sizes: '192x192', type: 'image/png' },
          { src: 'pwa-512x512.png', sizes: '512x512', type: 'image/png' },
          {
            src: 'maskable-icon-512x512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      includeAssets: ['favicon.ico', 'favicon.svg', 'apple-touch-icon-180x180.png'],
    }),
  ],
})
