import { defineConfig, minimal2023Preset } from '@vite-pwa/assets-generator/config'

// Genera los iconos de la PWA a partir de un solo archivo fuente.
//
// El manifiesto vivía con `icons: []`, y sin iconos de 192 y 512 px Android no ofrece instalar la
// app: la PWA no era instalable. Esto lo cierra, y lo cierra de forma que el día que llegue el logo
// real no haya que volver a tocar configuración: se sobrescribe `public/favicon.svg` y se corre
// `npm run iconos`.
//
// El preset `minimal2023` produce exactamente lo que piden hoy los navegadores y nada más:
//
//   favicon.ico                    los navegadores viejos y la pestaña
//   pwa-64x64.png                  favicon moderno
//   pwa-192x192.png                el mínimo que Android exige para ofrecer "Instalar"
//   pwa-512x512.png                splash y tienda
//   maskable-icon-512x512.png      Android recorta el icono a la forma del lanzador
//   apple-touch-icon-180x180.png   iOS, que ignora el manifiesto y solo mira este link
//
// La salida va a la carpeta del archivo fuente, por eso la fuente vive en `public/`.

// El fondo del manifiesto. Los dos iconos que se recortan o se componen —el maskable y el de
// Apple— tienen que rellenar TODO el lienzo con este color.
//
// Por qué: el preset achica la imagen y deja un margen de seguridad alrededor, porque el lanzador de
// Android recorta el icono a su forma (círculo, squircle, gota) y lo que quede fuera se pierde. Ese
// margen, por defecto, es TRANSPARENTE. Con una imagen de fondo oscuro el resultado es un cuadrado
// negro flotando dentro de un aro claro: exactamente el defecto que se ve si se genera sin esto.
// iOS es peor todavía, porque ni siquiera respeta la transparencia y compone sobre negro.
const fondo = '#0b0b0b'

export default defineConfig({
  headLinkOptions: { preset: '2023' },
  preset: {
    ...minimal2023Preset,
    // Sin margen: la fuente ya es una imagen a sangre. El preset por defecto la achica un 5% y deja
    // el resto transparente, lo que con un fondo oscuro se ve como un recuadro flotando en el aire.
    // El margen de seguridad solo lo necesita el maskable, que es el que se recorta.
    transparent: {
      ...minimal2023Preset.transparent,
      padding: 0,
    },
    maskable: {
      ...minimal2023Preset.maskable,
      resizeOptions: { background: fondo, fit: 'contain' },
    },
    apple: {
      ...minimal2023Preset.apple,
      resizeOptions: { background: fondo, fit: 'contain' },
    },
  },
  images: ['public/favicon.svg'],
})
